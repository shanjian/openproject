# Meeting RSVP: in-app responses, organizer digest, summary counts (R7)

**Date:** 2026-08-13
**Status:** Draft — awaiting review

## Problem

The requirements doc (`OpenProject-会议功能改进需求说明.md`, R7) asks for an
organizer-facing view of who accepted or declined a meeting. The backend is much closer
than the doc assumes — what is genuinely missing is the write path from inside the app,
the organizer's awareness of responses, and an aggregate view:

1. **Participants can only respond by email.** `MeetingParticipant#participation_status`
   (needs-action / accepted / declined / tentative / unknown, plus a `comment` column)
   exists, and inbound `.ics` REPLY mail is fully parsed
   (`IncomingEmails::Handlers::MeetingResponse` →
   `AllMeetings::HandleICalResponseService`, including series-wide replies,
   per-occurrence replies, and interim responses for not-yet-instantiated occurrences).
   But no controller or service lets a logged-in user set their own status; users whose
   mail client doesn't send `.ics` replies (or who read mail in OpenProject) cannot
   respond at all.
2. **Organizers never learn about responses.** Statuses silently change; the author
   only sees them if they happen to open the meeting page.
3. **No aggregate.** The side panel and the participants dialog already show colored
   per-participant statuses (`SidePanel::ParticipantsComponent`,
   `Participants::BoxRowComponent`), sorted by `status_sorting_value` — but there is no
   count line, so the organizer tallies by eye.

Explicitly settled product decisions (owner, 2026-08-13): include in-app respond
buttons, batched organizer notification (email to the meeting author), and summary
counts. CSV export is **out**. Respond UI lives on the meeting page only. Responding on
a recurring occurrence offers both "this occurrence" and "this and all future
occurrences".

## Key mechanisms being reused

- **Series-wide response semantics:** `HandleICalResponseService#handle_ical_event`
  already defines them (update the template participant + instantiated future
  occurrences; template statuses propagate to newly instantiated occurrences because
  `MeetingParticipant#copy_attributes` keeps `participation_status`, and
  `InitOccurrenceService` moves interim responses). The in-app series scope mirrors
  this.
- **Debounce:** GoodJob concurrency keys with `enqueue_limit: 1` and a delayed
  `perform_later`, exactly like `Meetings::SendUpdatedNotificationJob` (PR #122). The
  digest job waits **10 minutes** (requirements doc) instead of 5.
- **Per-user email opt-out:** the `meeting_updated` recipe from PR #122 — one boolean
  column on `notification_settings`, classification in
  `NotificationSetting.email_settings`, the upsert column list, and one Angular
  email-alerts row. Repeated verbatim for a new `meeting_responses` setting.
- **Participant-scoped write guard:** lean `BaseCallable` services with explicit
  guards, like `Meetings::CancelService`/`RestoreService`.

## Design

### 1. In-app respond

**Route & authorization.** `POST /projects/:project_id/meetings/:id/respond` plus
`GET .../respond_dialog` (the occurrence scope dialog), both registered in the engine
under **`view_meetings`** (`meetings: %i[respond respond_dialog]`) — responding is a
participant
action, not an organizer action; users who can see the meeting and are invited to it
may respond. The service enforces the participant check; the permission map only
gates project visibility.

Params: `status` (`accepted` | `tentative` | `declined`), `scope`
(`occurrence` | `series`, only honored for occurrences of a recurring meeting).

**Service.** `MeetingParticipants::RespondService.new(meeting, current_user:)`
(BaseCallable, following CancelService's shape):

- Guards, each returning `ServiceResult.failure`:
  - `(meeting.open? || meeting.in_progress?) && !meeting.template?` — no responding
    to drafts, closed, or cancelled meetings, and never to templates directly (the
    template's rows are only written through the series scope below).
  - the current user has an **invited** `MeetingParticipant` row on the meeting.
  - `status` is one of the three respondable values (never `needs_action`/`unknown`).
- On success:
  - sets `participation_status` and stamps `participation_responded_at = Time.current`
    (new column, see Migrations) on the participant. The `comment` column is left
    untouched — in-app comments are out of scope (see below).
  - **scope=series** (only when `meeting.recurring?`): additionally updates the
    template's participant row and the participant rows of all **future, instantiated,
    not-cancelled** occurrences — all of them, not only `needs_action` ones: unlike a
    generic email REPLY, this is an explicit "apply to all future" choice. Past
    occurrences are never touched. (The email path's needs-action-only semantics stay
    as they are.)
  - enqueues the organizer digest (§2).
- No contract class: the writable surface is one enum on the caller's own participant
  row; guards are simpler and match the CancelService precedent.

**Controller.** `MeetingsController#respond` (member route), responding with turbo
streams: update the side panel participants section
(`SidePanel::ParticipantsComponent` is already `OpTurbo::Streamable`) and the
participants dialog trigger if present; error flash on failure.

**UI.** A "Your response" block at the top of the side panel participants section,
rendered when the respond guards would pass for `User.current`:

- Three buttons (Primer `ButtonGroup`, small): Accept / Tentative / Decline, the
  current status visually selected (e.g. `aria-pressed` + filled scheme), so the block
  doubles as "what did I answer".
- **One-off meeting:** each button is a direct `form_with` POST (turbo), no dialog.
- **Recurring occurrence:** each button opens a small async dialog (the established
  `async-dialog` controller + `respond_dialog` GET member route) with two radios —
  "This occurrence" (default) / "This and all future occurrences" — and a confirm
  button carrying the chosen status. One dialog component,
  `Meetings::RespondDialogComponent`, parameterized by status.
- The block never renders on templates, drafts, closed, or cancelled meetings, nor for
  non-participants; it renders on past-dated but still-open meetings (same rule as the
  service guard — attendance tracking is a separate concern).

### 2. Organizer response digest (batched email)

**Trigger points.** Both write paths stamp `participation_responded_at` and enqueue the
digest job:

- `MeetingParticipants::RespondService` (§1),
- `HandleICalResponseService#update_participation_status` (email replies).

Interim responses (`RecurringMeetingInterimResponse`, for occurrences that don't exist
yet) do **not** trigger a digest; they surface later when the occurrence is
instantiated and are a rare path. Noted as a known gap.

**Batching target.** The concurrency key is the *top-level* object:
`meeting.recurring_meeting || meeting`. This is what keeps a single series-wide email
reply — which touches the template plus N occurrences in one sweep — from producing N
separate digests: all enqueues collapse into one job keyed on the series.

**Job.** `Meetings::SendParticipationDigestJob`, mirroring
`SendUpdatedNotificationJob`:

```ruby
SendParticipationDigestJob
  .set(wait: 10.minutes)
  .perform_later(target, since: stamp)
```

where `stamp` is the same `Time.current` the write path just stored into
`participation_responded_at` — passing a *fresh* `Time.current` at enqueue would be
microseconds later and silently exclude the very response that opened the window from
the `>= since` query.

- GoodJob `enqueue_limit: 1`, key `"Meetings::SendParticipationDigestJob-<class>-<id>"`
  (class-qualified because Meeting and RecurringMeeting ids can collide),
  `discard_on ActiveJob::DeserializationError` (target deleted → nothing to report).
- The first response in a burst opens the window and fixes `since`; later enqueues
  within 10 minutes are dropped by the guard, so one mail covers the window.
- `perform(target, since:)`:
  - resolves the recipient: `target.author`. Skip (no mail) if the author is gone,
    locked, or is the only respondent in the window (self-responses are excluded from
    the digest; a digest consisting solely of the author's own answer is dropped).
  - collects responses: participant rows of the meeting — or, for a series, of the
    template plus all its occurrence meetings — where
    `participation_responded_at >= since`, status in accepted/tentative/declined,
    and `user != author`.
  - returns without mail if the collection is empty.
  - honors the author's **global** `meeting_responses` notification setting
    (same global-rows-only query as `meeting_updated`, and for the same reason:
    project rows hardcode email settings to false).
  - the digest is **independent of the org-level `notify?` mute toggle** — that toggle
    governs participant-facing calendar mail; this mail is the organizer's own
    dashboard-in-mail, which they switch off via their personal setting instead.
  - renders `MeetingMailer.participation_digest(target, author, responses)` and
    `deliver_now`s it (single recipient, no per-recipient loop).

**Mailer.** `MeetingMailer.participation_digest` — informational, no `.ics`. Subject:
`[Project] Responses for 'Title'`. Body lists one line per response —
participant name, status (colored like the side panel), the occurrence date when the
target is a series and the row belongs to a specific occurrence, or "all future
occurrences" for template-row updates — plus the participant's `comment` when present
(email replies carry comments; in-app responses don't set them). Footer button links to
the meeting (or series) page.

**Race with destruction.** Deleting the meeting/series discards the queued job via
`discard_on DeserializationError`. No explicit `delete_jobs` call is needed — unlike
the update mail, a late digest after a cancellation is not misleading (it reports
things that really happened), and the cancellation path already destroys or tombstones
the rows the digest would read.

### 3. Summary counts

`SidePanel::ParticipantsComponent` (and the participants dialog header,
`Participants::ListComponent`) gain one aggregate line above the list:

> 3 accepted · 1 tentative · 1 declined · 2 pending

- Computed as `meeting.participants.invited.group(:participation_status).count`,
  with `needs-action` and `unknown` folded into "pending". Zero-count segments are
  omitted; the line is omitted entirely when there are no invited participants.
- Rendered as plain `Primer::Beta::Text` segments in the existing status colors
  (success / attention / danger / subtle), matching the per-row rendering.
- On the template (series) page the same line shows over the template's participants —
  useful together with series-wide responses.
- No new queries per row: one grouped count per render, memoized.

### 4. Settings & frontend plumbing (the `meeting_updated` recipe, repeated)

- Migration: `add_column :notification_settings, :meeting_responses, :boolean,
  default: true` (opt-out, like `meeting_updated`).
- `NotificationSetting`: `MEETING_RESPONSES = :meeting_responses`, appended to
  `email_settings` — API representer property, project-scope rejection, and
  reminder-settings placement all follow from the classification.
- `UserPreferences::UpdateService` upsert column list: append `meeting_responses`.
- Angular: `meetingResponses` in `INotificationSetting` + `buildNotificationSetting`
  (default true), `EmailAlertType` union + `emailAlerts` array + label
  ("Participant responses to my meetings"), form control (default true) in
  `ReminderSettingsPageComponent`, `meetingResponses: false` in
  `NotificationsSettingsPageComponent#saveChanges` project rows.
- Locales: `js.reminders.settings.alerts.meeting_responses`, mailer subject/body keys,
  respond-button and dialog labels, "pending" summary label.

## Migrations

1. `add_column :meeting_participants, :participation_responded_at, :datetime,
   null: true` — powers the digest window query; deliberately **not** backfilled
   (existing statuses have no known response time; the digest only cares about
   post-deploy responses).
2. `add_column :notification_settings, :meeting_responses, :boolean, default: true`
   (`# rubocop:disable Rails/ThreeStateBooleanColumn`, as before).

## Tests

- **RespondService specs:** sets status + stamp on own row; series scope updates
  template and future instantiated occurrences but never past or cancelled ones;
  occurrence scope touches only that occurrence; rejects non-participants,
  non-invited participants, drafts/closed/cancelled/templates, and invalid statuses;
  enqueues the digest job keyed on the series for occurrences and on the meeting for
  one-offs.
- **HandleICalResponseService additions:** stamps `participation_responded_at` and
  enqueues the digest once per series for a series-wide reply (guards the
  concurrency-key choice).
- **Digest job specs:** collects only in-window responses; excludes the author's own
  response and skips the mail when nothing remains; honors the author's global
  `meeting_responses` opt-out (and ignores a project-scoped row, as with
  `meeting_updated`); series digests label occurrence rows with dates and template
  rows as all-future; deleted target discards; deleted author skips.
- **Request specs:** `POST respond` happy path (status changes, turbo stream, 200),
  scope param honored on occurrences and ignored on one-offs, 403/failure for
  non-participants and for users without `view_meetings`, failure on cancelled/closed.
- **Component specs:** "Your response" block visible to an invited participant on an
  open meeting, hidden for non-participants and on closed/cancelled/template meetings;
  current status highlighted; summary counts line renders correct segments and folds
  needs-action + unknown into pending.
- **Params contract / preferences specs:** `meeting_responses` project-scope rejection
  and explicit-false persistence (upsert list guard), mirroring the `meeting_updated`
  pair.
- **Mailer preview** for the digest (one-off and series variants).

## Out of scope

- CSV export of the participant list — explicitly dropped by the owner.
- Filtering the participants dialog by response status — the summary line plus
  status-sorted rows cover the need; revisit if asked.
- In-app response **comments** — the column and email-borne comments remain, and the
  digest displays them; adding a comment field to the respond dialog is a follow-up.
- Digests for interim responses (occurrences not yet instantiated).
- Delegation (`delegated` PARTSTAT) — still unsupported, as today.
- In-app (notification center) delivery of the digest — email only, per owner decision.
- R5/R6 territory (mute semantics, update batching) — untouched.
