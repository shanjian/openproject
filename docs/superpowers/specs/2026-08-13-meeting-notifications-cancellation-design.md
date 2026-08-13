# Meeting change/cancellation notifications and one-off meeting cancellation state

**Date:** 2026-08-13
**Status:** Approved

## Problem

Reported symptom: participants sometimes show up for meetings that were already
rescheduled or cancelled. The requirements doc that prompted this
(`OpenProject-会议功能改进需求说明.md`, R5/R6) assumes meeting change/cancellation
notifications don't exist at all. They do — `MeetingMailer` already has `updated`,
`cancelled`, and `cancelled_series` (`modules/meeting/app/mailers/meeting_mailer.rb:48-92`),
dispatched automatically off `Meeting#send_updated_mail`
(`modules/meeting/app/models/meeting.rb:131-133, 322-329`), with `.ics` REQUEST/CANCEL
attachments and inbound RSVP parsing already wired.

Three real gaps produce the reported symptom instead:

1. **Cancellation can be silently muted.** `MeetingNotificationService#call`
   (`modules/meeting/app/services/meeting_notification_service.rb:9-16`) gates *every*
   mail type — invited, updated, and cancelled alike — behind one `meeting.notify?` flag.
   There is no batching for edits, so an organizer rearranging a recurring series gets one
   email per recipient per edit; the natural response is to flip the existing
   "toggle notifications" switch off
   (`modules/meeting/app/components/meetings/side_panel/toggle_notifications_dialog_component.rb`).
   That same switch then silently swallows the cancellation email too — nothing in the
   codebase treats cancellation as exempt from muting.
2. **No per-user opt-out.** The requirements doc assumes participants can individually
   turn off meeting-change emails, the way they can for work-package events via
   `NotificationSetting`. No such per-user setting exists for meetings — muting is
   currently all-or-nothing at the organizer/series level.
3. **One-off meeting cancellation is a hard delete.** `Meeting#state` has a `cancelled`
   enum value (`meeting.rb:135-141`), and recurring-series *occurrences* already do proper
   soft-cancel + restore via `ScheduledMeeting#cancelled`
   (surfaced in `modules/meeting/app/components/recurring_meetings/row_component.rb`). But a
   plain one-off meeting has no UI path to that state at all — the status-switcher only
   offers open/in_progress/closed
   (`modules/meeting/app/components/meetings/side_panel/status_button_component.rb:49`).
   Cancelling one today goes through `Meetings::DeleteService`, which sends the courtesy
   `cancelled` mail and then deletes the record — nothing is left to show a "Cancelled"
   badge or to restore.

This spec fixes all three. It does not touch R7 (organizer-facing RSVP dashboard) — not
requested, and it shares no infrastructure with the above.

## Key mechanism being reused

The codebase already debounces jobs via a GoodJob concurrency key elsewhere in this module
(e.g. `RecurringMeetings::InitNextOccurrenceJob`, `modules/meeting/app/workers/recurring_meetings/init_next_occurrence_job.rb`).
The batching design below is the same idiom applied to `MeetingMailer#updated`, rather than
new infrastructure.

## Design

### 1. Notification gating: cancellation exempt, per-user preference for updates

`notification_settings` is a wide table — one boolean column per setting type
(`db/migrate/tables/notification_settings.rb:38-65`, e.g. `news_added default: false`),
not a key-value row per setting. This spec adds one column the same way:

```ruby
t.boolean :meeting_updated, default: true # rubocop:disable Rails/ThreeStateBooleanColumn
```

Defaulting `true` matches `assignee`/`responsible`/`shared`/`watched`/`mentioned` (things a
user is opted into unless they say otherwise), not the `news_added`/`document_added`-style
email_settings that default `false` — a meeting being rescheduled is closer to "assigned to
you" than to "a wiki page changed." No project-specific override: the existing settings
page already special-cases the `email_settings` bucket as global-only in practice (its
per-project row construction hardcodes those fields, see §4), so `meeting_updated` follows
that same bucket's actual behavior rather than the per-project `assignee`/`shared` pattern.

`MeetingNotificationService` splits "is this mail type gated at all" from "is this specific
recipient opted out," reusing the exact resolution idiom `watcher_recipients` already
uses (`app/models/users/scopes/watcher_recipients.rb:39-46`:
`NotificationSetting.applicable(project).where(watched: true, user_id: ...)`):

```ruby
def call(action, **)
  if bypasses_mute?(action) || meeting.notify?
    recipients_with_errors = send_notifications!(action, **)
    ServiceResult.new(success: recipients_with_errors.empty?, errors: recipients_with_errors)
  else
    ServiceResult.failure(errors: meeting.participants.includes(:user))
  end
end

private

def bypasses_mute?(action)
  %i[cancelled cancelled_series].include?(action)
end

def send_notifications!(action, **)
  recipients_with_errors = []
  meeting.participants.includes(:user).find_each do |recipient|
    next if action == :updated && !opted_in_user_ids.include?(recipient.user_id)

    MeetingMailer.send(action, meeting, recipient.user, User.current, **).deliver_later
  rescue StandardError => e
    Rails.logger.error { "Failed to deliver #{action} notification to #{recipient.mail}: #{e.message}" }
    recipients_with_errors << recipient
  end
  recipients_with_errors
end

# Bulk-resolved once per call, not per recipient — mirrors watcher_recipients rather than
# querying NotificationSetting inside the find_each loop.
def opted_in_user_ids
  @opted_in_user_ids ||= NotificationSetting
    .applicable(meeting.project)
    .where(meeting_updated: true, user_id: meeting.participants.select(:user_id))
    .pluck(:user_id)
end
```

- Cancellation (`cancelled`, `cancelled_series`) always sends, to every participant,
  regardless of the org-level `notify?` flag or any individual's personal preference. This
  is the direct fix for the reported symptom.
- `updated` mail is filtered per-recipient by `meeting_updated`, in addition to the existing
  org-level gate.
- `invited`, `participant_added`, and `participant_removed` are unchanged: still gated
  solely by the org-level `notify?` toggle, as today. They're neither "update" nor
  "cancellation," and nothing in the requirements doc's event table asks for them to
  respect the new per-user preference.
- `Meeting#send_emails?` (`meeting.rb:294-299`) gets an explicit `return false if closed?`.
  Today a closed meeting's non-editability is only enforced at the controller/UI layer;
  this closes the gap at the model level so no other write path can trigger an update mail
  on a closed meeting.

### 2. Batching the `updated` mail (5-minute window)

`Meeting#send_updated_mail` (`meeting.rb:322-329`) stops calling
`MeetingNotificationService` synchronously and instead enqueues:

```ruby
Meetings::SendUpdatedNotificationJob
  .set(wait: 5.minutes)
  .perform_later(self, old_values: updated_mail_changes)
```

guarded by a GoodJob concurrency key scoped to the meeting id, `total_limit: 1` (same
pattern as `InitNextOccurrenceJob`). Behavior:

- First edit in a burst enqueues the job and captures the pre-edit values as job arguments.
- Further edits within the window attempt to enqueue "the same" job and are silently
  dropped by the concurrency guard — so the *original* job, holding the *original*
  pre-edit baseline, is still the one that runs.
- The window is anchored to the first edit in a burst, not "5 minutes of quiet" — matches
  the doc's own test scenarios (3 edits in 3 minutes → 1 email) and avoids a job that never
  fires if edits keep trickling in slightly slower than the window.
- When the job runs, it reloads the meeting fresh, diffs `old_values` (captured at
  enqueue time) against current attributes, and calls
  `MeetingNotificationService.new(meeting).call(:updated, changes: ...)` — which applies
  the per-recipient preference filter from §1.
- The job guards `return if meeting.cancelled? || meeting.closed?` before sending — if the
  meeting was cancelled or closed after the edit but before the job runs, there's no point
  mailing "time changed" for a meeting that's no longer happening. The immediate,
  unbatched cancellation mail (§1) already told recipients what they need to know.

Rejected: a dedicated `MeetingPendingNotification` snapshot table. It would additionally
support detecting "reverted to the original value within the window, skip the email" —
correct, but not something any test scenario in the requirements doc asks for, and it's new
persistent state for a case that doesn't need it. Revisit only if that edge case turns out
to matter in practice.

### 3. Cancellation & restore for one-off meetings

- New "Cancel" action, distinct from the existing open/in_progress/closed switcher, offered
  exactly when `editable?` is true (so already excludes `closed` today). Sets
  `state: cancelled`, stamps a new `state_before_cancellation` column on `meetings`
  (integer, nullable — the only schema change to the `meetings` table in this spec; §1 adds
  a separate column to `notification_settings`) with the current state, fires the immediate
  unbatched `cancelled` mail. Agenda items, minutes, and attachments are untouched.
- New "Restore" action, gated by the same `edit_meetings` permission as everything else on
  a meeting: sets `state` back to `state_before_cancellation`, clears the column. Offered
  exactly when `cancelled?` is true. Once the `editable?` change below ships, "Cancel" and
  "Restore" can never both be offered at once (`editable?` requires `!cancelled?`, "Cancel"
  requires `editable?`, "Restore" requires `cancelled?`). A `closed` meeting correctly shows
  neither — closed is a terminal state, not one this spec adds an exit from.
- `Meeting#editable?` (`meeting.rb:222-224`) becomes:

  ```ruby
  def editable?(user = User.current)
    !closed? && !cancelled? && user.allowed_in_project?(:edit_meetings, project)
  end
  ```

  Today it only checks `!closed?`, so a `cancelled` one-off meeting (once this spec adds a
  UI path to that state) would otherwise still be editable — this closes that gap, and
  incidentally makes cancelled-meeting agenda/minutes genuinely read-only for free, since
  agenda editing already keys off `editable?`.
- Recurring-series occurrence cancel/restore (`ScheduledMeeting#cancelled`) is unchanged —
  it already works correctly. This section only affects plain one-off meetings.

### 4. Frontend

- Cancelled badge + strikethrough title on the plain meeting list and show page, mirroring
  what `RecurringMeetings::RowComponent` already renders for cancelled occurrences
  (`row_component.rb:77-85`) — extended to `Meetings::RowComponent` and the show page.
- Restore button alongside the badge, same visibility rule.
- New checkbox row in the personal notification settings page for "notify me about meeting
  changes" (`meetingUpdated`). The settings page is a hand-built form, not a generic
  enumerator over `NotificationSetting.all_settings` — concretely this touches:
  `INotificationSetting`/`buildNotificationSetting` (`frontend/src/app/features/user-preferences/state/notification-setting.model.ts`)
  for the field and its default, a new form control + template row + translation strings in
  `NotificationSettingsTableComponent`, and the `globalPrefs` construction in
  `NotificationsSettingsPageComponent#saveChanges()` (`notifications-settings-page.component.ts:225-279`).
  Global only, alongside `newsAdded`/`documentAdded`/etc. — not part of `projectPrefs`, whose
  construction already hardcodes those email-settings fields to `false` regardless of form
  state, i.e. the existing UI doesn't actually support per-project overrides for this
  bucket today. This is a real (if small) frontend addition, not automatic from the backend
  column alone.

### 5. Tests

- Mailer/service specs: cancellation bypasses both the org-level toggle and a participant's
  personal opt-out; `updated` respects both.
- Job spec for the debounce behavior (GoodJob test helpers, already used elsewhere in this
  module) — multiple edits in-window produce one send; the send reflects final state; the
  job no-ops if the meeting became cancelled/closed before it runs.
- Feature spec for one-off meeting cancel → restore round trip, and for the `editable?`
  guard rejecting edits to a cancelled meeting.
- Frontend spec for the new settings row.

## Out of scope

- R7 (organizer-facing RSVP acceptance dashboard) — not requested, no shared
  infrastructure with the above.
- Recurring-series occurrence cancel/restore — already implemented correctly, untouched by
  this spec.
- Any change to `.ics` generation/parsing — already correct, unaffected by gating changes.
- Making the 5-minute batching window admin-configurable. Hardcoded, matching the
  requirements doc's spec value; revisit only if it turns out to need tuning per instance.
