# Meeting improvements batch 2: calendar feed fixes, timezone selection, edit/close scope

Status: draft — awaiting owner review
Date: 2026-08-14
Requirements source: "OpenProject 会议需求增补 R8–R12" (2026-08-12)

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

- **Ended series**: skip `add_series_event` entirely; emit only their past
  instantiated occurrences as standalone (non-recurring) VEVENTs so history
  stays visible. No VEVENT with a future DTSTART may be emitted for an ended
  series.
- **Active series**: unchanged behavior.

Also guard inside `add_series_event` itself (used by the mailer path too):
if the schedule yields no upcoming occurrence, fall back to the same
occurrences-only rendering instead of emitting a future-dated master event.

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

### Tests (Part 1)

ICS content is currently untested (blast radius shows no covering specs).
Add:

- Unit specs on `Meetings::IcalendarBuilder` / `RecurringMeetings::ICalService`
  asserting: SEQUENCE bumps after a schedule-only series update; LAST-MODIFIED
  reflects the newer of series/template; EXDATE for cancelled occurrences
  (regression); refresh properties present.
- Request spec on the token feed: active series renders master VEVENT +
  override; ended series renders no VEVENT with DTSTART in the future but
  keeps past occurrences; cancelled one-off meetings absent or CANCELLED.

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
- Contract: validate the value against `ActiveSupport::TimeZone` names
  (same rule as the existing recurring column).

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
- Changing a series' zone is a schedule change: it already rides through
  `reschedule_required?`, the reschedule sweep and the batched series-update
  mail (`time_zone` is in `SCHEDULE_ATTRS`). Verify with a spec, no new code
  expected.

**Display.** Viewers keep seeing times localized to their own zone
everywhere (lists, meeting page, mails) — the zone changes *interpretation
at input*, not display. ICS output uses the meeting's own zone as TZID:
`add_single_meeting_event` currently renders in the *builder's* zone (the
generating user's) — switch it to `meeting.time_zone` so DST shifts track
the meeting's home zone, mirroring what series events already do.

### Tests (Part 2)

- Model spec: zone-resolution precedence (series delegate → column → current
  user), parsing of date/hour in a non-UTC zone across a DST boundary.
- Contract spec: invalid zone rejected.
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

Mechanics: `RecurringMeetings::UpdateService` accepts `apply_scope`
(a service param, not a model attribute — same pattern as
`RespondService#scope`). The sweep updates occurrence columns via
`update_column` like the existing title sync — no per-occurrence journals,
no per-occurrence mails; the single batched series-update mail continues to
cover notification.

### 3b. Occurrence close scope

Closing an occurrence that belongs to a series opens a scope dialog
(pattern: `Meetings::RespondDialogComponent` + `respond_dialog` route):

- **"Only this occurrence"** — today's `change_state` to closed. Existing
  closed-mail machinery applies.
- **"This and all future occurrences"** — closes this occurrence, then ends
  the series *from this occurrence*: future scheduled/instantiated
  occurrences are removed, cancellation mails go to invitees of instantiated
  ones, and the ended-series mail carries the truncated series ICS — all
  existing `EndService` behavior.

One-time meetings and the series-level "End meeting series" action are
unchanged.

`EndService` changes:

- New keyword `end_date:` (default `Time.zone.yesterday`, preserving current
  callers) — the close flow passes the occurrence's start date so the closed
  occurrence remains the last one.
- The removal sweep must exclude the occurrence being closed even when it has
  not started yet (its `scheduled_meeting` may still count as "upcoming"):
  new keyword `keep:` taking that scheduled meeting, mirroring the `also:`
  pattern from the RSVP sweep.

Permissions: the second option renders only for users allowed to end the
series (same check as `RecurringMeetingsController#end_series`); plain
closers see a single-option dialog degrade to the direct action.

State guard note: `change_state` and the dialog flow both go through the
model-level cancelled-state guard from PR #124; closing a cancelled
occurrence stays impossible.

### Tests (Part 3)

- Service specs: `UpdateService` with `apply_scope: "all"` sweeps past open
  occurrences' details but never their `start_time`, skips closed/cancelled
  rows, and sends no per-occurrence mails; `future` scope now syncs
  location/duration (regression for the title-only gap).
- `EndService` spec: `end_date:`/`keep:` params — closed occurrence
  survives, strictly-later occurrences removed, mails as today.
- Request specs: close dialog renders scoped options per permission;
  scoped close closes + ends; "only this" leaves the series untouched.

## Out of scope

- Series splitting ("this and future" edits from a single occurrence
  creating a second series) — owner decision 1.
- Closing past occurrences in bulk ("all" for close) — owner decision 3.
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
