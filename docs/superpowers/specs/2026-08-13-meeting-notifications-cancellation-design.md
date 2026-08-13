# Meeting change/cancellation notifications and one-off meeting cancellation state

**Date:** 2026-08-13
**Status:** Approved
**Revisions:** 2026-08-13 (review round 1 — series batching, cancelled-meeting visibility,
preference round-trip, global-only enforcement, delete-path gating, authorization/actor
contracts) · 2026-08-13 (review round 2 — EndService gates, draft/template exclusion from
Cancel, contract guard on generic state writes, `cancelled_series` removed from the
meeting-bound service, string-key snapshot + deleted-actor fallback) · 2026-08-13 (review
round 3 — recurring occurrences excluded from Cancel, participant-removal cancellation
ungated, ended-series vs. queued-update-job race, draft-series delete guard, cancelled
branches for the side-panel state components)

## Problem

Reported symptom: participants sometimes show up for meetings that were already
rescheduled or cancelled. The requirements doc that prompted this
(`OpenProject-会议功能改进需求说明.md`, R5/R6) assumes meeting change/cancellation
notifications don't exist at all. They do — `MeetingMailer` already has `updated`,
`cancelled`, and `cancelled_series` (`modules/meeting/app/mailers/meeting_mailer.rb:48-92`),
dispatched automatically off `Meeting#send_updated_mail`
(`modules/meeting/app/models/meeting.rb:131-133, 322-329`) and
`RecurringMeetings::UpdateService#send_updated_mail`
(`modules/meeting/app/services/recurring_meetings/update_service.rb:172-192`), with `.ics`
REQUEST/CANCEL attachments and inbound RSVP parsing already wired.

Three real gaps produce the reported symptom instead:

1. **Cancellation can be silently muted.** Every cancellation mail in the codebase is
   gated on the organizer-level `notify?` flag: `MeetingNotificationService#call`
   (`modules/meeting/app/services/meeting_notification_service.rb:9-16`) gates all mail
   types behind `meeting.notify?`, and the destructive services check it inline before
   their direct `MeetingMailer` calls (`modules/meeting/app/services/meetings/delete_service.rb:36`,
   `modules/meeting/app/services/recurring_meetings/delete_service.rb:40`,
   `modules/meeting/app/services/recurring_meetings/end_service.rb:51,53`). There is no
   batching for edits, so an organizer rearranging a series gets one email per recipient
   per edit — both the one-off path and the series path
   (`RecurringMeetings::UpdateService#send_updated_mail`, which loops participants with
   `deliver_now`) fire immediately on every save. The natural response is to flip the
   "toggle notifications" switch off
   (`modules/meeting/app/components/meetings/side_panel/toggle_notifications_dialog_component.rb`).
   That same switch then silently swallows the cancellation email too.
2. **No per-user opt-out.** The requirements doc assumes participants can individually
   turn off meeting-change emails, the way they can for work-package events via
   `NotificationSetting`. No such per-user setting exists for meetings — muting is
   currently all-or-nothing at the organizer/series level.
3. **One-off meeting cancellation is a hard delete.** `Meeting#state` has a `cancelled`
   enum value (`meeting.rb:135-141`), but nothing in app code ever sets it (verified: the
   only state writes are `open!`/`closed!`/`in_progress!` in
   `MeetingsController#change_state` and `meeting_presentation_controller.rb:47`).
   Recurring-series *occurrences* soft-cancel via `ScheduledMeeting#cancelled` (deleting
   the occurrence `Meeting` and tombstoning the schedule row —
   `Meetings::DeleteService#cancel_scheduled_meeting`). A plain one-off meeting has no
   cancel path at all except hard delete, which sends the courtesy mail (if not muted) and
   destroys the record — nothing left to badge or restore. The `cancelled` state is in
   fact actively defended against: `MeetingsController#show` 404s it
   (`meetings_controller.rb:75`) and the list query excludes it
   (`modules/meeting/app/models/queries/meetings/meeting_query.rb:47`).

This spec fixes all three. It does not touch R7 (organizer-facing RSVP dashboard) — not
requested, and it shares no infrastructure with the above.

## Key mechanisms being reused

- **Debounce:** GoodJob concurrency keys, as `RecurringMeetings::InitNextOccurrenceJob`
  already uses (`modules/meeting/app/workers/recurring_meetings/init_next_occurrence_job.rb`).
- **Per-user recipient filtering:** `NotificationSetting.where(reason => true)` scoped to
  candidate users, as `Notifications::CreateFromModelService#settings_for_allowed_users`
  does (`app/services/notifications/create_from_model_service.rb:242-251`).
- **Global-only enforcement:** `UserPreferences::ParamsContract#global_email_alerts`
  (`app/contracts/user_preferences/params_contract.rb:55-59`) already rejects any
  project-scoped payload that enables a setting classified in
  `NotificationSetting.email_settings` — classification alone buys the validation.

## Design

### 1. Notification gating: cancellation exempt, per-user preference for updates

`notification_settings` is a wide table — one boolean column per setting type
(`db/migrate/tables/notification_settings.rb:38-65`). This spec adds one column:

```ruby
t.boolean :meeting_updated, default: true # rubocop:disable Rails/ThreeStateBooleanColumn
```

Defaulting `true` (unlike the opt-in `news_added`-style alerts) because R5's intent is
that participants get change notifications unless they individually opt out.

**Classification and round-trip.** `MEETING_UPDATED = :meeting_updated` is added to
`NotificationSetting.email_settings` (`app/models/notification_setting.rb:79-90`). That
single classification does three things:

- Membership in `all_settings` makes `NotificationSettingRepresenter` expose the API
  property automatically (`lib/api/v3/user_preferences/notification_setting_representer.rb:37`).
- `ParamsContract#global_email_alerts` automatically rejects project-scoped payloads that
  set it `true` — the spec's "global only" rule is enforced by existing validation, not by
  UI omission.
- No new contract code is needed.

One thing classification does **not** cover: `UserPreferences::UpdateService#upsert_notifications`
has a hardcoded upsert column list (`app/services/user_preferences/update_service.rb:94-114`).
`meeting_updated` must be added there, or an explicit value would silently fail to persist
on conflict.

**Consumption is global-only by query, not via `applicable(project)`.** The standard
recipient idiom coalesces a project-specific row over the global one
(`app/models/notification_settings/scopes/applicable.rb:40-52`). For this setting that
would be wrong: project rows hardcode email-settings fields to `false` (see §4), so any
user holding a per-project work-package override would silently stop receiving meeting
update mail in that project — masking a default-on setting via an unrelated preference
row. Since the setting has no per-project semantics at all, the service queries global
rows only:

```ruby
def opted_in_user_ids
  @opted_in_user_ids ||= NotificationSetting
    .where(project_id: nil, meeting_updated: true, user_id: meeting.participants.select(:user_id))
    .pluck(:user_id)
end
```

**Service changes.** `MeetingNotificationService` splits "is this mail type gated at all"
from "is this specific recipient opted out," and accepts an explicit actor (needed by the
delayed jobs in §2 — mail templates render `@actor`, e.g.
`modules/meeting/app/views/meeting_mailer/updated.html.erb:34`, and `User.current` inside
a background job is not the editing user):

```ruby
def call(action, actor: User.current, force: false, **)
  if force || bypasses_mute?(action) || meeting.notify?
    recipients_with_errors = send_notifications!(action, actor, **)
    ServiceResult.new(success: recipients_with_errors.empty?, errors: recipients_with_errors)
  else
    ServiceResult.failure(errors: meeting.participants.includes(:user))
  end
end

private

def bypasses_mute?(action)
  action == :cancelled
end

def send_notifications!(action, actor, **)
  recipients_with_errors = []
  meeting.participants.includes(:user).find_each do |recipient|
    next if action == :updated && !opted_in_user_ids.include?(recipient.user_id)

    MeetingMailer.send(action, meeting, recipient.user, actor, **).deliver_later
  rescue StandardError => e
    Rails.logger.error { "Failed to deliver #{action} notification to #{recipient.mail}: #{e.message}" }
    recipients_with_errors << recipient
  end
  recipients_with_errors
end
```

- Cancellation always sends, to every participant, regardless of the org-level `notify?`
  flag or any individual's personal preference. Only `:cancelled` appears in
  `bypasses_mute?`: `cancelled_series` is **not** a valid action for this service —
  `MeetingMailer.cancelled_series` takes a `RecurringMeeting`, while this service is bound
  to a single `Meeting` and loops its participants. Nothing calls the service with
  `:cancelled_series` today; series-level cancellation mail lives in the series services,
  where the same invariant is enforced directly (§3).
- `updated` mail is filtered per-recipient by `meeting_updated`, in addition to the
  existing org-level gate.
- `invited`, `participant_added`, and `participant_removed` are unchanged: still gated
  solely by the org-level `notify?` toggle. They're neither "update" nor "cancellation,"
  and nothing in the requirements doc's event table asks otherwise. The `force:` keyword
  exists for exactly one caller — restore (§3), whose re-invitation must reach muted
  meetings' participants the same way the cancellation that preceded it did.
- `Meeting#send_emails?` (`meeting.rb:294-299`) gets an explicit `return false if closed?`,
  closing the model-level gap rather than relying on the edit UI blocking closed meetings.

### 2. Batching the `updated` mail (5-minute window) — both paths

Two independent synchronous send sites become delayed jobs. Both jobs carry the acting
user as a plain `actor_id` integer, captured at first-edit enqueue time, and resolve it at
run time with `User.find_by(id: actor_id) || DeletedUser.first` — *not* as a
GlobalID-serialized `User` argument, because both jobs declare
`discard_on ActiveJob::DeserializationError` for their meeting/series argument, and a
GlobalID actor would extend that discard to "actor account was deleted," dropping valid
notifications. The resolved user feeds the `actor:` keyword from §1.

The GoodJob guard uses `enqueue_limit: 1` (not `total_limit: 1`): it dedupes *queued*
jobs, but a job already executing (delivering mail) doesn't block a fresh edit from
enqueueing the next window — with `total_limit`, an edit landing mid-delivery would be
silently lost.

**One-off/occurrence path.** `Meeting#send_updated_mail` (`meeting.rb:322-329`) becomes:

```ruby
Meetings::SendUpdatedNotificationJob
  .set(wait: 5.minutes)
  .perform_later(self, actor_id: User.current.id, old_values: updated_mail_changes)
```

concurrency-keyed on the meeting id. First edit in a burst enqueues and captures the
pre-edit values; further edits within the window are dropped by the guard, so the job
holding the *original* baseline fires once, 5 minutes after the first edit. It reloads
the meeting, diffs `old_values` against current attributes (skipping the send entirely if
nothing still differs is *not* attempted — see rejected alternative below), guards
`return if meeting.cancelled? || meeting.closed?`, and calls
`MeetingNotificationService.new(meeting).call(:updated, actor:, changes: ...)`.

**Series path.** `RecurringMeetings::UpdateService#send_updated_mail`
(`update_service.rb:172-192`) currently loops participants inline with `deliver_now`,
rendering the old schedule per-participant locale from a dup'd unsaved model
(`@old_schedule_model`). That dup can't ride through GlobalID, so the service instead
enqueues:

```ruby
RecurringMeetings::SendUpdatedNotificationJob
  .set(wait: 5.minutes)
  .perform_later(recurring_meeting,
                 actor_id: User.current.id,
                 old_schedule_attributes: @old_schedule_model.attributes.slice(*SCHEDULE_ATTRS),
                 old_location: @old_location)
```

concurrency-keyed on the series id, where `SCHEDULE_ATTRS` is a constant of **string**
column names (`%w[frequency interval start_time start_date end_after end_date iterations
time_zone title]`) — `ActiveRecord#attributes` returns string keys, so a symbol list would
`slice` to an empty snapshot and the "old schedule" in the mail would silently render from
nothing. The job rebuilds a transient
`RecurringMeeting.new(old_schedule_attributes)` to render `full_schedule_in_words` in each
participant's locale (the method needs only schedule attributes; its `template&.duration`
access is already nil-safe), then loops `series.template.participants.invited` exactly as
today, calling `MeetingSeriesMailer.updated` with the stored actor. The org-level
`notify?` gate moves inside the job (checked at send time, not enqueue time). Series
update mail is still "update" mail, so the job also skips recipients whose global
`meeting_updated` is false — the same global-rows-only query as §1's `opted_in_user_ids`,
applied inline (this path doesn't go through `MeetingNotificationService`, which is bound
to a single `Meeting`). The job opens with `return if series.has_ended?` — the second
layer of the ended-series race guard (§3, which also has the destructive services delete
pending jobs by concurrency key).

Rejected: a dedicated pending-notification snapshot table. It would additionally support
"reverted to the original value within the window → skip the email," which no test
scenario in the requirements doc asks for. Revisit only if that proves to matter.

### 3. Cancellation & restore for one-off meetings

**State transitions — owned by dedicated services, closed to generic writes.**

`Meetings::BaseContract` exposes `state` as a writable attribute
(`modules/meeting/app/contracts/meetings/base_contract.rb:41`), so without a guard any
generic `Meetings::UpdateService` call could write `state: cancelled` directly — no
`state_before_cancellation` stamp, no mail, invariant silently broken. Therefore:

- `Meetings::BaseContract` gains a validation rejecting any `state` change **to or from**
  `cancelled`. The `change_state` controller whitelist already excludes `cancelled`; this
  closes the API/service layer the same way. The two services below perform their writes
  outside that validation (their own contract, or direct attribute writes within the
  service — decided at implementation, both idiomatic here).
- `Meetings::CancelService` — guards a new predicate
  `Meeting#cancellable?` = `editable? && !draft? && !template? && !recurring?`. Drafts are
  excluded because invitations are deliberately not sent until `exit_draft_mode`
  (`meetings_controller.rb:378-393` is what triggers `deliver_invitation_mails`):
  "cancelling" a never-published meeting would mail a cancellation for an event nobody was
  invited to, and restoring it would force-send invitations to a still-draft meeting.
  Drafts keep hard delete as their only exit, as today; templates aren't real events.
  Recurring occurrences (`recurring?`) are excluded because they already have a
  cancellation flow — the `ScheduledMeeting#cancelled` tombstone with its own
  restore — and letting them take this path would set `Meeting#state = cancelled`
  instead, splitting one occurrence's cancellation across two unreconciled
  representations. Occurrence cancellation stays exactly where it is. The
  `!closed?` inside `editable?` covers the doc's "closed meetings can't be cancelled"
  rule. On success: sets `state: cancelled`, stamps `state_before_cancellation` (new
  integer nullable column on `meetings`; §1 adds a separate column to
  `notification_settings`), fires the immediate unbatched `cancelled` mail through
  `MeetingNotificationService`. Agenda items, minutes, and attachments untouched.
- `Meetings::RestoreService` — guards `cancelled?`. Restores `state_before_cancellation`,
  clears the column, sends the standard `invited` mail via
  `MeetingNotificationService#call(:invited, force: true)` — the one `force:` caller (§1)
  — so participants' calendars re-add the event the earlier `METHOD:CANCEL` removed, even
  on muted meetings. Because Cancel excludes drafts, a restored meeting is by construction
  published — the forced re-invitation can never leak invitations to a draft. With the
  `editable?` change below, Cancel and Restore can never both be offered; a `closed` or
  `draft` meeting shows neither.
- `Meeting#editable?` (`meeting.rb:222-224`) becomes
  `!closed? && !cancelled? && user.allowed_in_project?(:edit_meetings, project)` — making
  cancelled meetings read-only everywhere agenda editing already keys off `editable?`.

**Authorization.** OpenProject authorizes controller actions through the engine's
permission→action map, not through model predicates — `editable?` alone is UI sugar. The
new actions are registered in `modules/meeting/lib/open_project/meeting/engine.rb` under
`edit_meetings`, alongside the existing `change_state`:

```ruby
meetings: %i[... change_state cancel_dialog cancel restore ...]
```

`edit_meetings` (not `delete_meetings`) because cancel-with-restore is a reversible state
change like open/close, and it deliberately remains available to organizers who can't
hard-delete. Hard delete stays under `delete_meetings`, unchanged.

**Existing destructive paths keep existing semantics, minus the mute loophole.** Hard
delete (header menu entry, `header_component.rb:82-83`) remains available as the
destructive option, distinct from Cancel — the doc's "cancel keeps data" rule describes
Cancel, not a replacement of delete. Every path that removes meetings from participants'
calendars loses its `notify?` gate on the courtesy mail:

- `Meetings::DeleteService` (`delete_service.rb:36`) — `cancelled` mail now sent
  `unless model.draft? || model.template?` instead of `if model.notify?`. The draft/
  template guard exists for the same reason Cancel excludes them (§ above): a
  never-published meeting has sent no invitations, so ungating its delete mail would
  newly mail cancellations for events nobody knew about.
- `RecurringMeetings::DeleteService` (`delete_service.rb:40`) — `cancelled_series` mail
  sent `unless model.template.draft?` instead of `if model.notify?`. A draft series has
  never sent invitations (`InitNextOccurrenceJob` is skipped while
  `template.draft?`, `update_service.rb:200-201`), so the same never-published rule as
  the one-off draft guard applies.
- `RecurringMeetings::EndService` (`end_service.rb:51,53`) — **both** of its gates go,
  not just the per-occurrence one: `send_cancellation_for_future_instantiated_occurrences`
  cancels the already-instantiated future occurrences, but it's `send_ended_mail` that
  carries the re-issued series `.ics` truncating the recurrence rule — without it, muted
  participants' calendars keep projecting *non-instantiated* future occurrences forever,
  which is precisely the reported symptom.
- `MeetingParticipants::DeleteService` (`delete_service.rb:35-46,82-84`) — removing a
  participant sends *that participant* a personal `cancelled`/`cancelled_series` `.ics`
  (their calendar-removal), currently gated behind `should_send_notification?` →
  `send_emails?` → `notify?`. The gate splits: the removed participant's cancellation
  mail keeps only the `Journal::NotificationConfiguration.active?` check (the system-wide
  bulk-operation suppressor, not the mute toggle) plus the never-published guard
  (`meeting.draft? || meeting.onetime_template?` — the latter also protects the
  `meeting.recurring_meeting` access in `send_cancellation_notification`, which would be
  `nil` for a onetime template and is only reachable today because `send_emails?` filters
  those out first). The `participant_removed` mail to the *remaining* participants stays
  gated by `send_emails?` as today — informational, consistent with §1.

**Race with the queued update jobs.** `EndService` and `RecurringMeetings::DeleteService`
run while a §2 series-update job may still be queued; without a guard, an edit followed
minutes later by "end series" would deliver a stale "schedule changed" mail *after* the
ended-series mail. Two-layer fix, both reusing existing idioms: the destructive services
delete pending `RecurringMeetings::SendUpdatedNotificationJob` rows by concurrency key —
the exact pattern `reschedule_init_job` already uses
(`update_service.rb:194-198`) — and the job itself additionally guards
`return if series.has_ended?` (`recurring_meeting.rb:125-127`) as a belt against jobs
already past the queue. The one-off job's existing `cancelled?/closed?` guard is the same
idea; `Meetings::CancelService` likewise clears that meeting's pending update job.

These inline sends stay where they are (they run mid-destroy against data that won't
exist afterwards, so routing them through the meeting-bound service buys nothing); the
invariant "removing an event from calendars always notifies (once published)" is enforced
at all five sites — the four above plus `MeetingNotificationService#bypasses_mute?` — and
asserted by tests.

**Visibility.** Two existing behaviors actively hide the `cancelled` state and must both
change (safe: nothing sets `state: cancelled` today, so no existing records change
behavior):

- `MeetingsController#show` (`meetings_controller.rb:75`) stops 404ing cancelled meetings
  and renders the normal show page read-only, with the Cancelled label and Restore button.
- `Queries::Meetings::MeetingQuery#default_scope` (`meeting_query.rb:44-50`) drops
  `.not_cancelled`, so cancelled meetings appear in lists with the badge — the point of
  R6 is that people *see* the cancellation. Recurring occurrences are unaffected: their
  cancellation deletes the `Meeting` row outright, so nothing new leaks into the list.

### 4. Frontend

- Cancelled badge + strikethrough title on the meeting list rows and show page, mirroring
  what `RecurringMeetings::RowComponent` renders for cancelled occurrences
  (`row_component.rb:77-85`). Restore button alongside, same visibility rule.
- The side-panel state components need explicit `cancelled` branches — both currently
  enumerate only draft/open/in_progress/closed, so a cancelled meeting would render an
  empty state section: `Meetings::SidePanel::StateComponent`
  (`state_component.html.erb:6-109`) gains a `when "cancelled"` branch (grey label,
  description text, footer Restore button), and the interactive status switcher
  (`Meetings::SidePanel::StatusButtonComponent`, `status_button_component.rb:68-77`) is
  not rendered for cancelled meetings at all — Restore is the only exit from `cancelled`,
  so offering open/in_progress/closed transitions there would fight the contract guard
  from §3.
- The personal opt-out checkbox goes in the **email alerts** section of the reminder
  settings page — that's where the `email_settings` bucket actually renders
  (`frontend/src/app/features/user-preferences/reminder-settings/email-alerts/email-alerts-settings.component.ts`,
  which enumerates `emailAlerts`; the notifications-settings table is work-package-reason
  UI and doesn't host these). Concretely: add `meetingUpdated` to `INotificationSetting`
  and `buildNotificationSetting` (default `true`) in
  `frontend/src/app/features/user-preferences/state/notification-setting.model.ts`; add it
  to the `EmailAlertType` union, `emailAlerts` array, and labels in
  `EmailAlertsSettingsComponent`; add the form control to the `emailAlerts` group and its
  build/save wiring in `ReminderSettingsPageComponent`
  (`reminder-settings-page.component.ts:63-72` and its `buildForm`/`saveChanges`); and add
  `meetingUpdated: false` to the hardcoded project-row construction in
  `NotificationsSettingsPageComponent#saveChanges` `projectPrefs`
  (`notifications-settings-page.component.ts:247-270`) like the other email-settings
  fields — the value is never read for meetings (§1 queries global rows only), but the
  field must round-trip consistently. `globalPrefs` needs no change: it spreads the
  existing global row, which carries `meetingUpdated` through.
- New translation strings for the checkbox label and the badge, in both `en.yml` and the
  frontend locale files, following the existing `js.reminders.settings.alerts.*` pattern.

### 5. Tests

- Service specs: cancellation bypasses both the org-level toggle and personal opt-out;
  `updated` respects both; recipient filter queries global rows only (a project-scoped
  row with `meeting_updated: false` does not suppress mail).
- Destructive path specs: both delete services send cancellation mail even when `notify?`
  is false; `EndService` with `notify?` false still sends both the per-occurrence
  cancellations and the `ended_series` mail; deleting a draft one-off sends no
  cancellation mail; deleting a draft *series* sends no `cancelled_series` mail; removing
  a participant from a muted meeting still sends that participant the cancellation `.ics`
  (while the remaining-participants mail stays suppressed); ending a series with a queued
  update job pending delivers no stale update mail afterwards.
- Contract spec: a generic `Meetings::UpdateService` write of `state: cancelled` (and a
  write moving state *off* `cancelled`) is rejected by `BaseContract` — the non-UI bypass
  path.
- Job specs (both jobs, GoodJob test helpers): multiple edits in-window produce one send
  reflecting final state; enqueue during an executing job starts a new window; deleted
  meeting/series discards cleanly; a deleted *actor* does not discard — mail sends with
  the `DeletedUser` fallback; one-off job no-ops when meeting became cancelled/closed;
  mail renders the enqueue-time actor, not the job runner; series snapshot round-trips a
  frequency and an end-date change (guards the string-key `SCHEDULE_ATTRS` slice — a
  symbol list would silently produce an empty old-schedule).
- Params contract spec: project-scoped payload with `meeting_updated: true` rejected via
  the existing `email_alerts_global` validation; `UserPreferences::UpdateService` persists
  an explicit `meeting_updated: false` (guards the upsert column list).
- Feature specs: cancel → restore round trip (state, badge, read-only agenda, side-panel
  cancelled branch with Restore and no status switcher, and the forced re-invitation mail
  reaching participants of a muted meeting); Cancel not offered on draft, template, or
  recurring-occurrence meetings (occurrences keep the ScheduledMeeting flow); cancelled
  meetings visible in list and show page; permission mapping (user with `edit_meetings`
  can cancel/restore, user without cannot; `delete_meetings` not required).
- Frontend spec for the new email-alerts row.

## Out of scope

- R7 (organizer-facing RSVP acceptance dashboard) — not requested, no shared
  infrastructure with the above.
- Recurring-series occurrence cancel/restore — already implemented, untouched.
- Any change to `.ics` generation/parsing — the existing `cancelled:` flag and
  REQUEST/CANCEL handling are reused as-is.
- Making the 5-minute batching window admin-configurable. Hardcoded, matching the
  requirements doc; revisit only if it needs per-instance tuning.
- Skipping the batched mail when all changes were reverted within the window (needs a
  snapshot table; explicitly rejected above).
