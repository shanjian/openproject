# Meeting improvements batch 2: calendar feed fixes, timezone selection, edit/close scope

Status: draft — awaiting owner review (revised after code review round 2)
Date: 2026-08-14
Requirements source: "OpenProject 会议需求增补 R8–R12" (2026-08-12)

**Revision note (round 1 review):** the initial draft named the right files but
left several proposed mechanics disconnected from actual entry points
(strong params, contracts, `reschedule_required?`) or in conflict with each
other (R10 vs. R12 for a not-yet-started closed occurrence). Every finding
was verified by reading the cited code; all were confirmed real. Round 1
closed each gap by restricting "this and future" close to already-started
occurrences and adding an `apply_scope`/`this_and_future` plumbing story.

**Revision note (round 2 review):** round 1's fix used the wrong field for
the eligibility check and cutoff-date derivation (`meeting.start_time`
instead of the canonical `scheduled_meeting.start_time`, and no
series-timezone conversion on the derived date), didn't specify
authorization/atomicity for the new `close` action, still contradicted
itself about whether an ineligible occurrence can be closed at all, left
the "standalone" ICS rendering underspecified (UID/RECURRENCE-ID/RRULE
contract, and it would have still called the future-occurrence-emitting
`add_virtual_occurences_for_interim_responses`), and repeated a stale "ICS
is untested" claim contradicted by four existing spec files on `epic`. All
six were verified against the code and are fixed below.

## Requirement disposition

| Req | Content | Disposition |
|-----|---------|-------------|
| R8  | Notify participants when a meeting is closed | **Already delivered** — `MeetingMailer.closed`, merged in PR #122. Verify on DEV; no new work. |
| R9  | Monthly "Nth weekday", weekday selectable | **Already delivered** — schedule-mode ordinal × weekday picker, merged in PR #121. Verify on DEV; no new work. |
| R10 | Calendar sync: delay, only current week updates, closed series keeps future occurrences | **Part 1** of this spec (defect fixes, ships first). |
| R11 | Selectable time zone at meeting creation | **Part 2** of this spec. |
| R12 | This / this-and-future / all scope on update and close | **Part 3** of this spec. |

One PR per part, all branched off `epic`, in order Part 1 → 2 → 3.

### Owner decisions (2026-08-14)

1. **R12 scope chooser lives on the series edit form and the occurrence close dialog only.** Editing a single occurrence stays "only this"; no Google-style series splitting.
2. **R12 "all" applies detail fields to every open occurrence including past ones; date/time changes stay forward-only.** Past minutes remain historically accurate.
3. **R12 close scopes are "only this" and "this and future" (= close this occurrence + end the series).** No "all" for close.
4. **R11 timezone selector appears on both recurring and one-time meeting forms.** Recurring reuses the existing stored column; one-time meetings get a new column. Default: creator's profile zone.

## Part 1 — R10: calendar subscription feed fixes

Thunderbird (and any other calendar client) syncs via the token feed
`GET /meetings/ical/:token` (`Meetings::ICalController` → `AllMeetings::ICalService`
→ `Meetings::IcalendarBuilder`). All three reported symptoms are server-side
defects or tuning in that feed. The email-attachment ICS path shares the
builder and benefits from the same fixes.

### 1a. Stale series events ("only the current week updates")

**Root cause.** The series master VEVENT emits
`SEQUENCE = recurring_meeting.template.lock_version`
(`IcalendarBuilder#add_series_event`). A schedule-only series edit updates the
`recurring_meetings` row, not the template `meetings` row, so `SEQUENCE` and
`LAST-MODIFIED` (also template-derived) never change. Calendar clients treat
an event with an unchanged UID+SEQUENCE as not modified and keep the old
recurrence — while the instantiated next occurrence (an override VEVENT keyed
on `meeting.lock_version`, which does bump) updates. Net effect: exactly the
reported "only the current week changes".

**Fix.** In every series-level VEVENT (master event and virtual interim
occurrences):

- `SEQUENCE = recurring_meeting.lock_version + template.lock_version`
  (the sum of two monotonically increasing counters is monotonic; either row
  changing bumps the sequence),
- `LAST-MODIFIED = [recurring_meeting.updated_at, template.updated_at].max`
  (already correct on virtual occurrences; the master event currently uses
  the template timestamp only — align it).

`RecurringMeeting` must have `lock_version` for this. It does not today —
add an integer `lock_version` column (default 0, null: false) to
`recurring_meetings`; Rails then maintains it automatically.

### 1b. Ended series keeps projecting future occurrences

**Root cause.** `AllMeetings::ICalService#recurring_meetings` includes ended
series (`EndService` sets `end_after: specific_date, end_date: yesterday`).
For such a series `add_series_event` still emits a master VEVENT whose
`DTSTART` is `current_schedule_start` — which can lie in the future — with an
`RRULE ... UNTIL` in the past. Per RFC 5545 the DTSTART instance is always
part of the recurrence set, and clients render it (some render more).
The ended-series *email* carries a corrected ICS, but subscription-feed
clients never apply email updates, so future phantom occurrences persist.

**Fix.** In `AllMeetings::ICalService`, partition series by
`has_ended?`:

- **Ended series**: skip `add_series_event` entirely; call a new
  `IcalendarBuilder#add_ended_series_history(recurring_meeting:)` instead.
  **Builder API contract** (closing the "what exactly gets emitted" gap):
  - Query `recurring_meeting.scheduled_meetings.instantiated.not_cancelled.past`
    (the `.past` scope — `where(start_time: ...Time.current)` — already
    exists on `ScheduledMeeting`; cancelled occurrences are omitted, nothing
    happened for those).
  - Each occurrence renders as a fully standalone VEVENT: **`uid:
    scheduled_meeting.meeting.uid`** (every occurrence `Meeting` row already
    gets its own unique UID via `Meeting::MeetingUid`, distinct from
    `recurring_meeting.uid`) — **not** the series UID. No `RECURRENCE-ID`,
    no `RRULE`. `status: "CONFIRMED"`. `dtstart`/`dtend` from `meeting.start_time`/
    `meeting.end_time`; `sequence`/`last_modified` from `meeting.lock_version`/
    `meeting.updated_at` (same as `add_single_meeting_event`).
  - This method must **not** call `add_virtual_occurences_for_interim_responses`
    — that renders speculative future placeholder events for pending RSVP
    responses, which has no place in a terminated series' history view.
  - Rationale for the UID switch: without a master VEVENT, an override-style
    entry (series UID + RECURRENCE-ID, no matching master) is undefined
    behavior per RFC 5545 — clients that never received the master have
    nothing to attach the override to. A plain standalone VEVENT with its
    own UID is unambiguous. Accepted, one-time visual side effect: on the
    refresh where a series transitions to ended, calendar clients drop the
    old series-UID entries (master + overrides) and show new standalone
    entries in their place for the same past dates — no data loss, just a
    UID change, and it only happens once per series.
  - No VEVENT with a future DTSTART may be emitted for an ended series.
- **Active series**: unchanged behavior.

Also guard inside `add_series_event` itself (used by the mailer path too):
if the schedule yields no upcoming occurrence, fall back to
`add_ended_series_history` instead of emitting a future-dated master event.

### 1c. Delay

**Root cause.** The feed is pull-based; the builder advertises
`REFRESH-INTERVAL = PT6H` (`build_icalendar`), and Thunderbird's own default
poll interval applies on top. Changes therefore take hours to appear.

**Fix.**

- Advertise `REFRESH-INTERVAL;VALUE=DURATION:PT15M` and its non-standard
  twin `X-PUBLISHED-TTL:PT15M` (older clients read only the latter).
- Documentation note (user-facing wiki / reply to requester): with an ICS
  subscription the client controls polling — instant push is protocol-
  impossible. Thunderbird users should set the calendar's refresh interval
  to the desired freshness; the in-app meeting page and email notifications
  remain the real-time channels.

### 1d. Occurrence-level change detection (bulk field sync must bump SEQUENCE)

**Root cause (pre-existing, exposed by this batch).** A single instantiated
occurrence's VEVENT derives `SEQUENCE`/`LAST-MODIFIED` from
`meeting.lock_version`/`meeting.updated_at`
(`icalendar_builder.rb:142-144`). `RecurringMeetings::UpdateService
#update_future_occurrence_titles` already bulk-syncs the series title to
future occurrences via `scheduled.meeting.update_column(:title, new_title)`
— `update_column` skips callbacks *and* does not touch `updated_at` or bump
`lock_version`, so a title propagated this way is invisible to subscribed
calendar clients even though the in-app page shows the new title
immediately. Part 3 (R12 "all"/"future" scope) adds location/duration to
this same bulk-sync path, which would inherit the identical defect.

**Fix.** Replace the bare `update_column` calls in the occurrence-sync sweep
(both the existing title sync and the new location/duration sync — one
sweep, doing both) with `update_columns`, explicitly bumping the two
ICS-relevant fields in the same call:

```ruby
scheduled.meeting.update_columns(
  changed_attrs.merge(updated_at: Time.current, lock_version: scheduled.meeting.lock_version + 1)
)
```

`update_columns` (plural) still skips validations/callbacks — so this
remains a single batched change, not N per-occurrence
`after_update :send_updated_mail`/`send_closed_mail` firings — while making
the change detectable to calendar clients on next feed refresh.

### Tests (Part 1)

**Correction:** ICS content is not untested — `spec/services/meetings/icalendar_builder_spec.rb`
(671 lines), `spec/services/meetings/ical_service_spec.rb`,
`spec/services/recurring_meetings/ical_service_spec.rb` (175 lines), and
`spec/services/all_meetings/ical_service_spec.rb` (268 lines) already exist
on `epic` — the earlier draft's "no covering specs" was wrong (the
blast-radius lookup that produced it apparently missed these spec paths).
`icalendar_builder_spec.rb` already pins the current behavior with
`expect(parsed_calendar.refresh_interval.value_ical).to eq("PT6H")` — this
is a **breaking change** for §1c, not a new assertion; update it to `PT15M`
plus a new assertion for `X-PUBLISHED-TTL` in the same spec, rather than
adding a parallel one.

Additions/updates to the existing suites:

- `icalendar_builder_spec.rb`: update the `PT6H` expectation to `PT15M` +
  `X-PUBLISHED-TTL`; add SEQUENCE-bumps-after-schedule-only-update, LAST-MODIFIED
  reflects the newer of series/template, and the new
  `add_ended_series_history` contract (own UID per occurrence, no
  RECURRENCE-ID/RRULE, past-only, interim responses excluded).
- `all_meetings/ical_service_spec.rb`: ended series renders no VEVENT with a
  future DTSTART but keeps past occurrences; active series unchanged;
  cancelled one-off meetings absent or CANCELLED (regression).
- New regression spec: after a series title/location/duration edit, an
  already-instantiated future occurrence's VEVENT SEQUENCE increases and no
  per-occurrence mail is sent (covers the pre-existing title-sync gap too).

## Part 2 — R11: timezone selection at creation

### Current state

- `recurring_meetings.time_zone` exists and drives the schedule, but is never
  user-selectable: it is silently set from the creator's profile zone and only
  surfaces as a hidden field + warning banner when a different-zone user edits.
- One-time meetings store no zone; `Meeting#time_zone` is hard-coded to
  `User.current.time_zone`. A user without a profile zone gets UTC — the
  reported "fixed UTC" behavior.

### Changes

**Model.**

- Migration: `meetings.time_zone` (string, nullable). NULL = legacy row.
- `Meeting#time_zone`: for series meetings (template or occurrence) delegate
  to `recurring_meeting.time_zone` — occurrences never carry a private zone;
  otherwise the stored column, falling back to `User.current.time_zone`
  (today's behavior) when NULL.
- Model validation (**new** — neither model validates the zone string today):
  add a `validate` (not a `validates ... inclusion:`) on both `Meeting` and
  `RecurringMeeting` that checks `ActiveSupport::TimeZone[self[:time_zone]]`
  resolves when present. Plain `validates :time_zone, inclusion: { in: ... }`
  does not work here: both models' `time_zone` reader is overridden to
  return an `ActiveSupport::TimeZone` object (or delegate), not the raw
  string, so `inclusion` would validate the wrong shape of value.

**Controller/contract plumbing (verified missing — confirmed by reading the
current strong-param lists):**

- `MeetingsController#meeting_params` (`meetings_controller.rb:576`) does not
  permit `:time_zone` — add it, or the form field is silently dropped.
- `RecurringMeetingsController#recurring_meeting_params`
  (`recurring_meetings_controller.rb:363`) does not permit `:time_zone`
  either (only schedule/preset fields are listed). Add it there too.
- `Meetings::BaseContract` has no `time_zone` attribute at all — add
  `attribute :time_zone`. `RecurringMeetings::BaseContract` already declares
  `attribute :time_zone` (line 51) — no change needed there.
- **`RecurringMeeting#reschedule_required?`
  (`recurring_meeting.rb:288-293`) omits `time_zone` from its tracked-keys
  list.** Confirmed by reading the method: the list is `frequency
  start_date start_time start_time_hour iterations interval end_after
  end_date location weekdays schedule_mode month_day week_ordinal weekday` —
  `time_zone` is absent. Without adding it, a zone-only edit sets
  `should_reschedule?` to false, so `reschedule_future_occurrences` and
  `send_updated_mail` never run — the persisted zone would be silently inert
  for existing series (new series are unaffected; only editing an existing
  series' zone is broken). Add `time_zone` to the list. Note for the
  implementer: because `start_time` is stored as an absolute UTC instant, a
  zone-only change does not itself move any occurrence's UTC timestamp —
  `reschedule_all_occurrences` recomputing from the unchanged `schedule` is
  expected to be a no-op on the stored times. Triggering it anyway is still
  correct: it's what fires the batched "schedule updated" mail (`time_zone`
  is already in `SendUpdatedNotificationJob::SCHEDULE_ATTRS`, so the mail
  content was ready — only the trigger was missing) and it re-derives
  cached display fields.
- One-time meetings: `Meeting`'s own update-mail gate
  (`after_update :send_updated_mail, if: -> { saved_change_to_start_time? ||
  saved_change_to_duration? || saved_change_to_location? ||
  saved_change_to_title? }`, `meeting.rb:131-133`) also excludes
  `time_zone`. Same reasoning as above: a zone-only edit doesn't move
  `start_time`, so no mail fires today even after adding the column. This is
  lower-severity than the recurring case (a one-off meeting has no future
  occurrences depending on the zone) — decision: leave one-time zone-only
  edits silent (matches how other non-triggering fields, e.g. `notify`,
  behave) rather than widening the mail gate. Called out here so it isn't
  mistaken for an oversight during implementation.

**Form.** In `Meeting::TimeGroup`, add a timezone select (friendly zone
names via the existing `friendly_timezone_name` helper) for both meeting
kinds:

- Default on create: creator's profile zone; when unset, UTC is *shown
  explicitly in the select* rather than applied silently. The existing
  "set your timezone" flash nudge stays.
- The entered `start_date`/`start_time_hour` are interpreted in the selected
  zone — `Meeting::VirtualStartTime#parsed_start_time` already keys off
  `time_zone`, so parsing follows the column with no further change.
- On edit the select replaces the current hidden-field arrangement; the
  different-zone warning banner stays, now accompanied by an editable select.
- Changing a series' zone must be treated as a schedule change — see the
  `reschedule_required?` fix under "Controller/contract plumbing" below;
  this does **not** already work today and needs the code change described
  there, not just a spec.

**Display.** Viewers keep seeing times localized to their own zone
everywhere (lists, meeting page, mails) — the zone changes *interpretation
at input*, not display. ICS output uses the meeting's own zone as TZID:
`add_single_meeting_event` currently renders in the *builder's* zone (the
generating user's) — switch it to `meeting.time_zone` so DST shifts track
the meeting's home zone, mirroring what series events already do.

### Tests (Part 2)

- Model spec: zone-resolution precedence (series delegate → column → current
  user), parsing of date/hour in a non-UTC zone across a DST boundary,
  invalid raw zone string rejected by the new `validate` (not `inclusion`)
  check.
- Request spec: submitting `time_zone` through `meeting_params` /
  `recurring_meeting_params` persists it (regression for the missing
  strong-param entries).
- Service spec: editing only an existing series' `time_zone` (no other
  field) sets `should_reschedule?` true, enqueues the batched update mail,
  and leaves every occurrence's `start_time` unchanged (regression for the
  `reschedule_required?` gap).
- Request spec: create with explicit zone persists it; legacy NULL rows
  unchanged on unrelated update.
- ICS spec: one-off event TZID equals the stored meeting zone.

## Part 3 — R12: update / close scope for recurring meetings

### Baseline (today)

- Editing an occurrence = "only this" (unchanged by this spec).
- Editing the series ≈ "this and future": schedule changes resweep future
  occurrences; but of the detail fields only the **title** is synced to
  already-instantiated future occurrences (`update_future_occurrence_titles`)
  — location/duration lag until the next instantiation. That inconsistency
  gets fixed as part of this work.
- Closing is per-occurrence (`change_state`); ending a series is a separate
  action (`EndService`, always "from today").

### 3a. Series edit scope

The series edit form gets a radio group `apply_scope`:

- **`future` (default)** — "This and all future occurrences": today's
  behavior, plus the detail-sync fix: title, location, and duration now all
  propagate to open future instantiated occurrences (closed or cancelled
  occurrences are never touched). Known and accepted limitation, matching
  the existing title sync: individual per-occurrence edits are overwritten.
- **`all`** — "All occurrences": additionally applies the same detail fields
  to *past open* occurrences. Date/time/recurrence changes remain
  forward-only regardless of scope (owner decision 2).

**Plumbing (verified missing — confirmed by reading the current strong-param
list):** `recurring_meeting_params` (`recurring_meetings_controller.rb:363`)
does not permit `apply_scope`; add it there. It is a service-call keyword,
not a model/contract attribute (same pattern as `RespondService#scope`), so
no contract change is needed for it — but the controller must extract it out
of `@converted_params` before passing the rest to the model, and the service
must default and validate it server-side (`%w[future all]`, default
`"future"`) rather than trust an arbitrary posted string, since an unhandled
value must not silently fall through to "sync nothing" or "sync everything".

Sweep mechanics: `RecurringMeetings::UpdateService`'s occurrence-sync sweep
(the generalized replacement for `update_future_occurrence_titles`, now
covering title/location/duration under both scopes, plus past occurrences
under `all`) updates rows via `update_columns` bumping `updated_at` and
`lock_version` as specified in Part 1 §1d — not bare `update_column` — so
the change is both mail-silent and ICS-visible. No per-occurrence journals,
no per-occurrence mails; the single batched series-update mail continues to
cover notification.

### 3b. Occurrence close scope

**Eligibility restriction (resolves the R10/R12 conflict below) — corrected
to the canonical boundary.** The "this and future" close option is only
offered for an occurrence whose **`scheduled_meeting.start_time`** is at or
before `Time.zone.now` — not `meeting.start_time`. The earlier draft gated
on `meeting.start_time`, but `EndService`'s sweeps filter
`ScheduledMeeting.upcoming`/`.past` by the *scheduled_meeting* row's
`start_time`, and the two can diverge: nothing syncs
`scheduled_meeting.start_time` when a single occurrence's date/time is
edited directly (confirmed — no callback on `Meeting` touches its linked
`scheduled_meeting`; the builder itself treats them as distinct fields,
using `scheduled_meeting.start_time` for `RECURRENCE-ID` and
`meeting.start_time` for `DTSTART`, `icalendar_builder.rb:146-147`). An
occurrence whose meeting-level time was edited to look past-due while its
scheduled slot is still upcoming (or vice versa) would otherwise pass a
`meeting.start_time`-based eligibility check while still being `.upcoming`
from `EndService`'s point of view — exactly the divergence that made the
`keep:` parameter necessary in the first place. Gating on
`scheduled_meeting.start_time` is what actually guarantees the occurrence is
excluded from `.upcoming`, and is available on `close` without extra work —
every recurring occurrence's `Meeting#recurring_meeting_id` implies
`meeting.scheduled_meeting`.

This also resolves R10 vs. R12: since the closed occurrence's
`scheduled_meeting.start_time` is always `<= now` when this option is
offered, it always falls into the "past instantiated occurrence" bucket
that `add_ended_series_history` (R10 §1b) renders for ended series — no
future-dated survivor for the feed to reconcile.

**"Only this" is unrestricted, matching today's behavior exactly — no
eligibility gate.** The eligibility window governs the `this_and_future`
*option's availability*, not whether the occurrence can be closed at all.
The earlier draft said in one place that a not-yet-started occurrence
"cannot be closed at all today" and, two paragraphs later, that such an
occurrence gets "a single-option dialog" that closes it directly — those
two statements contradict each other. Resolution: `change_state` has no
start-time guard today (confirmed — `meetings_controller.rb:313-329`
accepts `closed` unconditionally), and this batch does not add one. Any
occurrence, regardless of timing, can always be closed via "only this".
Only the *second* option (`this_and_future`) is conditional on the
eligibility check above; when ineligible, the dialog simply omits that
option rather than blocking closing outright.

**Dialog and route — explicitly NOT the RSVP dialog.** The initial draft's
"pattern: `RespondDialogComponent` + `respond_dialog` route" phrasing was
ambiguous and, read literally, would misuse
`MeetingParticipants::RespondService` (records a participation response, not
a state change) — confirmed by reading `RespondDialogComponent`
(only accepts `RESPONDABLE_STATUSES`, defaulting unrecognized input to
`"accepted"`) and `MeetingsController#respond`. This needs its own,
unambiguous surface:

- New route: `post :close, on: :member` alongside the existing `change_state`
  member route (`config/routes.rb`), and a `close_dialog` counterpart for
  the confirmation UI, mirroring `cancel_dialog`/`cancel`.
- New `Meetings::CloseDialogComponent` (modeled on
  `Meetings::CancelDialogComponent`, not `RespondDialogComponent`):
  for a one-off meeting or an ineligible occurrence, renders a
  single-option confirm (today's behavior, direct close). For an eligible
  occurrence, renders the `only_this` / `this_and_future` radio choice.
- **Both new actions must be registered in `engine.rb`'s `edit_meetings`
  permission** (`meetings: %i[... change_state ...]` list,
  `engine.rb:66-73`) alongside `change_state`/`cancel`/`cancel_dialog` —
  the initial draft never specified this, and an unregistered action is
  unreachable/unauthorized by the standard OpenProject controller flow.
  This is the actual "preflight authorization" mechanism here: it runs
  before the action body executes, not a bespoke check inside `close`.
- New `MeetingsController#close` action, validating `params[:scope]`
  server-side against `%w[only_this this_and_future]` (default
  `"only_this"` — the narrower, non-destructive option — on anything
  unrecognized, mirroring the `apply_scope` handling in §3a):
  - `only_this` → today's `change_state(state: "closed")` path, unchanged.
  - `this_and_future` — **wrapped in a single `ActiveRecord::Base.transaction`**
    so the close and the series-ending are all-or-nothing:
    1. re-verify eligibility server-side (never trust the dialog's option
       list — a request can be replayed/forged after the eligibility
       window has closed, e.g. if the occurrence's scheduled time is in
       the future by the time the POST arrives); return a validation error
       for `this_and_future` on an ineligible occurrence instead of
       silently downgrading to `only_this`.
    2. `change_state(state: "closed")` for this occurrence.
    3. `RecurringMeetings::EndService.new(recurring_meeting, current_user:)
       .call(end_date: scheduled_meeting.start_time.in_time_zone(recurring_meeting.time_zone).to_date)`
       — see the timezone note below.
    4. If either step fails validation, the transaction rolls back and
       neither mutation is persisted. `send_closed_mail`
       (`meeting.rb:136`) and `EndService`'s mails are all enqueued via
       `deliver_later` (`MeetingNotificationService#call`, confirmed —
       never `deliver_now`), and GoodJob inserts queued-job rows through
       the same DB connection, so a transaction rollback also rolls back
       any mail enqueued inside it — no mail can escape a failed
       `this_and_future` close.

**Timezone-safe cutoff date (fixes a second bug in the same line).** The
initial draft passed `meeting.start_time.to_date` as `end_date`. `to_date`
on an `ActiveRecord`-loaded datetime converts using the *application's*
current `Time.zone`, not the series' own — near midnight in the series'
zone this can land on the wrong calendar day (ending one occurrence too
early or too late). Fix: convert through the series' own zone first —
`scheduled_meeting.start_time.in_time_zone(recurring_meeting.time_zone).to_date`.

`EndService` changes (narrower than the original draft — no `keep:`, per
the eligibility-restriction resolution above):

- New keyword `end_date:` (default `Time.zone.yesterday`, preserving every
  current caller including the unscoped "End meeting series" action).
- `RecurringMeetings::EndSeriesContract#meeting_ended`
  (`end_series_contract.rb:44-48`) currently hardcodes
  `errors.add(:end_date, :invalid) unless model.end_date ==
  Time.zone.yesterday` — confirmed this rejects any other value outright,
  including the occurrence date the close flow needs to pass. Relax to
  `errors.add(:end_date, :invalid) if model.end_date.nil? ||
  model.end_date.future?` — "ending" may target any date up to and
  including today, not only yesterday; still rejects an arbitrary future
  end_date reaching this contract (this contract is only ever selected by
  `EndService`, never by the plain series-edit path, so this stays a guard
  on `EndService`'s own callers, not a general contract loosening).

Permissions: `change_state`, `end_series`, and the new `close`/`close_dialog`
all sit under the **same** `edit_meetings` permission (confirmed —
`engine.rb`'s `edit_meetings` block already lists both `change_state` and
`end_series`/`end_series_dialog` together). There is no separate "allowed to
end the series" tier to check for `this_and_future` beyond ordinary
`edit_meetings` — the earlier draft implied one; correction noted so the
implementer doesn't build a permission distinction that isn't there.

State guard note: `change_state`, `close`, and the dialog flow all go
through the model-level cancelled-state guard from PR #124; closing a
cancelled occurrence stays impossible.

### Tests (Part 3)

- Service specs: `UpdateService` with `apply_scope: "all"` sweeps past open
  occurrences' details but never their `start_time`, skips closed/cancelled
  rows, sends no per-occurrence mails, and bumps `lock_version`/`updated_at`
  on synced rows; `future` scope now syncs location/duration (regression for
  the title-only gap); an unrecognized `apply_scope` value is rejected
  rather than silently defaulted.
- `EndService` spec: `end_date:` accepts any non-future date (regression for
  the hardcoded-yesterday contract); ordinary "End meeting series" callers
  (default `end_date:`) are unaffected.
- Regression spec: an occurrence whose `meeting.start_time` was edited to
  diverge from `scheduled_meeting.start_time` is gated by the latter, not
  the former (covers the eligibility-source fix); the derived `end_date`
  matches the series' own zone across a DST/midnight boundary, not the
  server's default zone (covers the timezone-conversion fix).
- Request/controller specs: `close` with `this_and_future` on an eligible
  occurrence closes it and ends the series from its date, with exactly one
  closed-mail (to this occurrence) and one ended-series mail (to the rest)
  — no cancellation mail for the closed occurrence itself; `only_this`
  leaves the series untouched and remains available regardless of the
  occurrence's timing (regression for the "cannot be closed" contradiction);
  the `this_and_future` option is absent from the dialog for an ineligible
  occurrence, and a forged `this_and_future` request against one is
  rejected server-side rather than silently downgraded; a failure inside
  `EndService` (e.g. contract validation) rolls back the occurrence's
  close too — assert the occurrence's state is unchanged and no mail was
  enqueued.
- ICS regression: after a `this_and_future` close, the feed for that
  (now-ended) series renders the closed occurrence via
  `add_ended_series_history` under its own `meeting.uid` (no
  `RECURRENCE-ID`, no `RRULE`), and no future VEVENT for the series.

## Out of scope

- Series splitting ("this and future" edits from a single occurrence
  creating a second series) — owner decision 1.
- Closing multiple past open occurrences in bulk ("all" for close) — owner
  decision 3.
- Ending the series as part of closing a not-yet-started occurrence
  (`this_and_future` on an ineligible occurrence) — "only this" close
  remains available for any occurrence regardless of timing, unchanged from
  today's behavior; see the eligibility restriction in §3b.
- CalDAV or any push-based calendar protocol; the feed remains pull-based
  ICS.
- Per-occurrence private timezones.
- Translations beyond source `en.yml` (Crowdin handles the rest); the
  requester communicates in Chinese but the product language files follow
  the normal pipeline.

## Notes for the reply to the requester

- R8/R9: already on DEV (or arriving with the next deploy); please re-verify.
- R10 "delay": after this fix the server advertises a 15-minute refresh, but
  Thunderbird's own calendar refresh setting governs actual polling; true
  instant sync is not possible with ICS subscriptions.
