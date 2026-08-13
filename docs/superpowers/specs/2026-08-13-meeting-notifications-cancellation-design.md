# Meeting change/cancellation notifications and one-off meeting cancellation state

**Date:** 2026-08-13
**Status:** Approved (revised 2026-08-13 after review — series batching, cancelled-meeting
visibility, preference round-trip, global-only enforcement, delete-path gating, and
authorization/actor contracts)

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
   types behind `meeting.notify?`, and both delete services check it inline before their
   direct `MeetingMailer` calls (`modules/meeting/app/services/meetings/delete_service.rb:36`,
   `modules/meeting/app/services/recurring_meetings/delete_service.rb:40`). There is no
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
  %i[cancelled cancelled_series].include?(action)
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

- Cancellation (`cancelled`, `cancelled_series`) always sends, to every participant,
  regardless of the org-level `notify?` flag or any individual's personal preference.
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
user explicitly (GlobalID-serialized), captured at first-edit enqueue time, and pass it
via the `actor:` keyword from §1. Both declare `discard_on ActiveJob::DeserializationError`
so a record deleted before the job runs is a clean no-op.

The GoodJob guard uses `enqueue_limit: 1` (not `total_limit: 1`): it dedupes *queued*
jobs, but a job already executing (delivering mail) doesn't block a fresh edit from
enqueueing the next window — with `total_limit`, an edit landing mid-delivery would be
silently lost.

**One-off/occurrence path.** `Meeting#send_updated_mail` (`meeting.rb:322-329`) becomes:

```ruby
Meetings::SendUpdatedNotificationJob
  .set(wait: 5.minutes)
  .perform_later(self, actor: User.current, old_values: updated_mail_changes)
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
                 actor: User.current,
                 old_schedule_attributes: @old_schedule_model.attributes.slice(*SCHEDULE_ATTRS),
                 old_location: @old_location)
```

concurrency-keyed on the series id, where `SCHEDULE_ATTRS` is a constant listing the
schedule-relevant columns (`frequency interval start_time start_date end_after end_date
iterations time_zone title`). The job rebuilds a transient
`RecurringMeeting.new(old_schedule_attributes)` to render `full_schedule_in_words` in each
participant's locale (the method needs only schedule attributes; its `template&.duration`
access is already nil-safe), then loops `series.template.participants.invited` exactly as
today, calling `MeetingSeriesMailer.updated` with the stored actor. The org-level
`notify?` gate moves inside the job (checked at send time, not enqueue time). Series
update mail is still "update" mail, so the job also skips recipients whose global
`meeting_updated` is false — the same global-rows-only query as §1's `opted_in_user_ids`,
applied inline (this path doesn't go through `MeetingNotificationService`, which is bound
to a single `Meeting`).

Rejected: a dedicated pending-notification snapshot table. It would additionally support
"reverted to the original value within the window → skip the email," which no test
scenario in the requirements doc asks for. Revisit only if that proves to matter.

### 3. Cancellation & restore for one-off meetings

**State transitions.**

- New "Cancel" action, offered when `editable?` is true (so never on `closed` — the doc's
  rule that closed meetings can't be cancelled needs no extra guard). Sets
  `state: cancelled`, stamps a new `state_before_cancellation` column on `meetings`
  (integer, nullable — the only schema change to `meetings`; §1 adds a separate column to
  `notification_settings`), fires the immediate unbatched `cancelled` mail through
  `MeetingNotificationService` (which per §1 bypasses all muting). Agenda items, minutes,
  and attachments untouched.
- New "Restore" action: sets `state` back to `state_before_cancellation`, clears the
  column, and sends the standard `invited` mail via
  `MeetingNotificationService#call(:invited, force: true)` — the one `force:` caller (§1) —
  so participants' calendars re-add the event the earlier `METHOD:CANCEL` removed, even on
  muted meetings. Offered exactly when `cancelled?`. With the `editable?` change
  below, Cancel and Restore can never both be offered; a `closed` meeting shows neither.
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

**Existing delete paths keep existing semantics, minus the mute loophole.** Hard delete
(header menu entry, `header_component.rb:82-83`) remains available as the destructive
option, distinct from Cancel — the doc's "cancel keeps data" rule describes Cancel, not a
replacement of delete. But both delete services lose their `if model.notify?` gate
(`meetings/delete_service.rb:36`, `recurring_meetings/delete_service.rb:40`): destroying
a meeting or a whole series now *always* sends the cancellation/`cancelled_series` mail.
Without this, the original symptom survives the whole spec — a muted meeting hard-deleted
today still vanishes silently. These two inline sends stay where they are (they run
mid-destroy against data that won't exist afterwards, so routing them through the service
buys nothing); the invariant "cancellation mail is never muted" is enforced at all three
sites and asserted by tests.

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
- Delete service specs (both): cancellation mail sent even when `notify?` is false.
- Job specs (both jobs, GoodJob test helpers): multiple edits in-window produce one send
  reflecting final state; enqueue during an executing job starts a new window; deleted
  record discards cleanly; one-off job no-ops when meeting became cancelled/closed;
  mail renders the enqueue-time actor, not the job runner.
- Params contract spec: project-scoped payload with `meeting_updated: true` rejected via
  the existing `email_alerts_global` validation; `UserPreferences::UpdateService` persists
  an explicit `meeting_updated: false` (guards the upsert column list).
- Feature specs: cancel → restore round trip (state, badge, read-only agenda, and the
  forced re-invitation mail reaching participants of a muted meeting); cancelled meetings
  visible in list and show page; permission mapping (user with `edit_meetings` can
  cancel/restore, user without cannot; `delete_meetings` not required).
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
