# Session kickoff — R11: timezone selection at meeting creation

Paste this whole file as your opening message in a fresh Claude Code session
working in this repo (`/home/dev/srcs/openproject`).

## Where things stand

This is Part 2 of a 3-part spec for OpenProject's meeting-calendar batch-2
requirements. **Part 1 (R10 — calendar subscription feed fixes) is done and
merged into `epic`** (PR #127, 2026-08-15). **This session's job is Part 2
only (R11 — timezone selection).** Part 3 (R12 — update/close scope) is a
separate, independent effort happening in a different session in parallel —
do not touch its area of the codebase (see "Staying out of Part 3's way"
below).

The design is **already finalized and owner-approved** — it went through
several review rounds before Part 1 even started. You do not need to
brainstorm this from scratch. Skip straight to `superpowers:writing-plans`.

## Authoritative source

Read the spec: `docs/superpowers/specs/2026-08-14-meeting-batch2-calendar-timezone-scope-design.md`

Your scope is **Part 2 only** (lines 282-391 in that file: `## Part 2 — R11:
timezone selection at creation` through `### Tests (Part 2)`). Do not
implement Part 1 (already done) or Part 3 (someone else's session).

The spec's Part 2 section already contains the full, detailed design —
including exact code snippets for the model validation, the controller
strong-param fixes, the `reschedule_required?` fix, and the form changes.
This kickoff note exists to orient you and carry forward lessons from
implementing Part 1 that aren't written down anywhere else; it does not
duplicate the spec.

## What R11 actually is

Right now, timezone is not user-selectable at meeting creation:
- **Recurring meetings** already have a `recurring_meetings.time_zone`
  column and it drives the whole schedule, but it's silently set to the
  creator's profile zone and only ever surfaces as a *hidden* field (plus a
  warning banner when a different-zone user edits an existing series).
- **One-time meetings** have no zone column at all —
  `Meeting#time_zone` is hardcoded to `User.current.time_zone`, which is
  UTC for any user without a profile zone set. That's the reported "fixed
  UTC" symptom.

R11 adds a real timezone select to `Meeting::TimeGroup` (the shared
date/time form partial used by both meeting kinds), backed by a new
`meetings.time_zone` column for one-time meetings, and wires up several
places that currently silently drop the value even where the column already
exists.

## Key gaps the spec's Part 2 documents (do not re-derive these — they're
already spec'd, just be aware going in)

- `MeetingsController#meeting_params` and
  `RecurringMeetingsController#recurring_meeting_params` don't permit
  `:time_zone` at all today — the form field would be silently dropped
  without this fix.
- `Meetings::BaseContract` has no `time_zone` attribute; `RecurringMeetings::BaseContract`
  already does (line ~51 of `modules/meeting/app/contracts/recurring_meetings/base_contract.rb`).
- `RecurringMeeting#reschedule_required?` (in `modules/meeting/app/models/recurring_meeting.rb`)
  omits `time_zone` from its tracked-attribute list — without adding it, editing
  an *existing* series' zone silently does nothing (no reschedule, no
  notification mail), even after the column becomes editable.
- Both models' `time_zone` reader is overridden to return an
  `ActiveSupport::TimeZone` object, not the raw string — a plain
  `validates :time_zone, inclusion: { in: ... }` won't work; the spec
  specifies a custom `validate` against the raw column instead.
- ICS output should use the meeting's own zone as TZID, not the
  viewing/generating user's zone — `add_single_meeting_event` in
  `modules/meeting/app/services/meetings/icalendar_builder.rb` got a
  `timezone:` keyword during Part 1 specifically so Part 2 (and Part 1's own
  ended-series history) could pass an explicit zone instead of the builder's
  default. Reuse that existing keyword; don't add a second mechanism.

## Lessons carried forward from implementing Part 1 (process, not design)

- **Test fixtures with hardcoded or lightly-computed dates rot.** Part 1's
  review process found *three separate* instances of test fixtures whose
  dates had silently drifted into being "in the past" relative to whenever
  the suite happens to run (one was a straight-up `Time#advance(week: 52)`
  typo — singular `week:` isn't a real key and silently no-ops). If you add
  a fixture with any date arithmetic, sanity-check it against "what happens
  if this runs a year from now," not just "does it pass today."
- **Read the actual current file before trusting the spec's line numbers.**
  The spec's line-number references were accurate when written, but the
  codebase moves. Always re-read the actual file before editing.
- **The review loop caught real, non-obvious bugs every single round** —
  four rounds of external review on this same spec document, and a further
  final-whole-branch review during Part 1's implementation caught a
  pre-existing, unrelated model bug (`current_schedule_end` anchored to the
  wrong field, producing an invalid VEVENT) that had nothing to do with the
  task at hand. Take review findings seriously and verify them against the
  actual code rather than accepting or dismissing them on the reviewer's
  say-so alone — and don't be afraid to independently re-derive a finding
  yourself when the stakes are high.
- **Workflow that worked well for Part 1**, reuse it: `superpowers:writing-plans`
  to turn the spec section into a task-by-task implementation plan, saved to
  `docs/superpowers/plans/`, then `superpowers:subagent-driven-development` to
  execute it (fresh implementer subagent per task, a task-scoped reviewer
  after each, a fix-and-re-review loop for findings, and one broad
  whole-branch review at the end before opening the PR). The SDD skill's own
  scripts (`sdd-workspace`, `task-brief`, `review-package`) handle ledger/diff
  plumbing — use them rather than reinventing.
- **Model selection**: cheap/fast models handled most of Part 1's individual
  tasks fine (they were well-specified). Reserve a more capable model for
  anything touching model-level validation semantics or cross-cutting
  concerns, and definitely for the final whole-branch review.

## Staying out of Part 2/3's way (parallel session note)

Another session is implementing Part 3 (R12) at the same time, off the same
`epic` base. File overlap between the two parts is minimal:

- R11 (this session) touches: `modules/meeting/app/forms/meeting/time_group.rb`,
  `modules/meeting/app/models/meeting.rb`, `modules/meeting/app/models/recurring_meeting.rb`
  (validation + `reschedule_required?` only — do not touch anything else in
  this file), `modules/meeting/app/contracts/meetings/base_contract.rb`,
  `modules/meeting/app/controllers/meetings_controller.rb` and
  `recurring_meetings_controller.rb` (strong params only),
  `modules/meeting/app/services/meetings/icalendar_builder.rb`
  (`add_single_meeting_event`'s call site only — the method itself already
  has the `timezone:` keyword from Part 1), a new migration, and their specs.
- R12 (the other session) touches `RecurringMeetings::UpdateService`,
  `RecurringMeetings::EndService`/`EndSeriesContract`, a new close-dialog
  component/route, and `engine.rb` permissions — none of which this session
  should need to touch.
- If you do find yourself needing to touch `recurring_meeting.rb` beyond the
  two spots named above, or anything under `recurring_meetings/update_service.rb`
  or `end_service.rb`, stop and reconsider — that's very likely Part 3's
  territory, not this session's.
- Branch off the current tip of `epic` (already includes Part 1's merge).
  Since both sessions are working concurrently, rebase onto `epic` again
  right before opening your PR in case Part 3 has already landed.

## What to do right now

1. Read the spec's Part 2 section in full (lines 282-391 of the design doc
   above) — it's the actual design; this note is only orientation.
2. Invoke `superpowers:writing-plans` on Part 2, producing an implementation
   plan under `docs/superpowers/plans/`.
3. Present the plan's execution-choice question (subagent-driven vs. inline)
   as that skill directs, and proceed.
4. Branch name suggestion: `feature/meeting-batch2-part2-timezone-selection`.
5. When done: full whole-branch review, then `superpowers:finishing-a-development-branch`
   (push + PR against `epic`, same as Part 1).

Update the `meeting-improvements` memory (if you have access to it) with
what actually shipped once this merges, the same way Part 1's summary was
recorded — future sessions rely on it.
