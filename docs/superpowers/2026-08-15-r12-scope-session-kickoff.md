# Session kickoff — R12: update/close scope for recurring meetings

Paste this whole file as your opening message in a fresh Claude Code session
working in this repo (`/home/dev/srcs/openproject`).

## Where things stand

This is Part 3 of a 3-part spec for OpenProject's meeting-calendar batch-2
requirements. **Part 1 (R10 — calendar subscription feed fixes) is done and
merged into `epic`** (PR #127, 2026-08-15). **This session's job is Part 3
only (R12 — this/this-and-future/all scope on series edits and occurrence
close).** Part 2 (R11 — timezone selection) is a separate, independent
effort happening in a different session in parallel — do not touch its area
of the codebase (see "Staying out of Part 2's way" below).

The design is **already finalized and owner-approved** — it went through
four external review rounds (each catching real, verified defects in the
mechanics, not nitpicks) before Part 1 even started. You do not need to
brainstorm this from scratch. Skip straight to `superpowers:writing-plans`.

## Authoritative source

Read the spec: `docs/superpowers/specs/2026-08-14-meeting-batch2-calendar-timezone-scope-design.md`

Your scope is **Part 3 only** (from `## Part 3 — R12: update / close scope
for recurring meetings` to the end of the file — roughly lines 392 onward,
including `### Tests (Part 3)`, `## Known limitations`, and `## Out of
scope`). Do not implement Part 1 (already done) or Part 2 (someone else's
session).

The spec's Part 3 section already contains the full, detailed design —
including the exact `apply_scope` plumbing, the corrected close-eligibility
logic, the timezone-safe cutoff-date derivation, the `EndSeriesContract`
fix, and the non-transactional (deliberately, after correction) close-action
design. This kickoff note exists to orient you and carry forward lessons
from Part 1's review process that materially affect how Part 3 must be
built; it does not duplicate the spec.

**Read the whole Part 3 section before starting, including the four
"revision note" paragraphs near the top of the document** (rounds 1-4 of
review). They record *why* the design looks the way it does — several
earlier, more "obvious" approaches were tried and found wrong (a shared
transaction around close+EndService that would have let real emails escape
a rollback; gating eligibility on the wrong field; a naive `+1` that turned
out to matter for a different reason than first assumed). Re-deriving those
from scratch and re-introducing an already-rejected approach is the single
biggest risk for this session.

## What R12 actually is, in one paragraph

Today, editing a single occurrence is implicitly "only this," editing the
whole series is implicitly "this and future," and closing is always
per-occurrence with no series-ending option in the same action. R12 makes
this an explicit choice: an `apply_scope` radio (`future` / `all`) on the
series-edit form, and a scope choice (`only_this` / `this_and_future`) on
occurrence close — where `this_and_future` closes the occurrence *and* ends
the series from that point, reusing `RecurringMeetings::EndService` with a
new `end_date:` parameter instead of its hardcoded "yesterday."

## Critical context from Part 1 you need before touching this

Part 1's implementation and its final whole-branch review surfaced several
facts about this exact area of the codebase that Part 3's design already
accounts for — but you need to understand *why*, because you'll be working
right next to them:

- **`scheduled_meeting.start_time` and `meeting.start_time` can diverge.**
  Nothing keeps them in sync when a single occurrence's time is edited
  directly. The spec's close-eligibility logic deliberately keys off
  `scheduled_meeting.start_time` (the field `EndService`'s own queries
  actually filter on), not `meeting.start_time` — round 2 of review caught
  this exact mistake in an earlier draft. Do not "simplify" this back to
  `meeting.start_time`.
- **`RecurringMeeting#current_schedule_end` was buggy until Part 1's final
  review fixed it** (it was anchored to the series' original `start_time`
  instead of the rolling `current_schedule_start` cursor, producing a VEVENT
  with DTEND before DTSTART for any series past its first occurrence). This
  is already fixed on `epic` — you don't need to fix it again — but if you
  see `current_schedule_start`/`current_schedule_end` while working in
  `icalendar_builder.rb` or `recurring_meeting.rb`, know that the current
  code is correct and don't be alarmed by it.
- **`add_series_tombstone` didn't include attendees until a post-merge PR
  fix** (also already on `epic`). If your close flow ends up exercising the
  ended-series tombstone path (it will, via `EndService` → the series
  becoming ended), attendees are already handled correctly — no action
  needed, just don't remove the `add_attendees` call if you're touching that
  method.
- **A known, deliberately parked gap from Part 1**: the same
  `METHOD:CANCEL`-payload-contains-brand-new-`CONFIRMED`-VEVENTs mismatch
  that Part 1 fixed for the *ended*-series cancel path also exists on the
  *active*-series cancel path (`add_series_event`'s `cancelled: true` branch
  still renders instantiated occurrences as `CONFIRMED` inside a
  `METHOD:CANCEL` calendar). This wasn't in R12's scope and wasn't fixed.
  R12's `this_and_future` close ends the series via `EndService`, which
  sends its own `cancelled`/`ended_series` mails through existing,
  already-correct paths — you likely won't touch this, but if your work
  happens to intersect it, it's a pre-existing, known, out-of-scope issue,
  not something this session introduced.
- **Read `EndService`'s actual current mail-delivery mechanism before
  building on it.** The spec's revision history explicitly retracted an
  earlier "wrap close + EndService in one transaction" design after
  discovering `EndService` sends mail via `MeetingMailer.cancelled(...).deliver_now`
  / `.ended_series(...).deliver_now` directly — not through the
  `deliver_later`-based path used elsewhere — so no transaction can protect
  against a rollback after mail has already gone out. The spec's final
  design (two sequential, independently-committing steps, not one shared
  transaction) exists specifically because of this. Don't reintroduce a
  shared transaction as a "cleanup."

## Lessons carried forward from implementing Part 1 (process, not design)

- **Test fixtures with hardcoded or lightly-computed dates rot.** Part 1's
  review process found *three separate* instances of test fixtures whose
  dates had silently drifted into being "in the past" relative to whenever
  the suite happens to run. R12 will be creating/manipulating recurring
  meeting and scheduled-meeting fixtures constantly (active series,
  eligible-for-close occurrences, ineligible ones) — be deliberate about
  which dates are meant to be relative-to-now vs. genuinely fixed, and don't
  let "it passes today" be the only check.
- **The review loop caught real, non-obvious bugs every single round** —
  this exact spec section went through four rounds of external review, each
  finding something concrete and real (never a stylistic nitpick). Take
  review findings seriously, verify them against the actual current code
  rather than trusting either the reviewer or your own prior blindly, and
  don't be afraid to independently re-derive a finding yourself (e.g. write
  a small throwaway repro script) when the stakes are high, as several
  rounds of this exact spec's review did.
- **Workflow that worked well for Part 1**, reuse it: `superpowers:writing-plans`
  to turn the spec section into a task-by-task implementation plan, saved to
  `docs/superpowers/plans/`, then `superpowers:subagent-driven-development` to
  execute it (fresh implementer subagent per task, a task-scoped reviewer
  after each, a fix-and-re-review loop for findings, and one broad
  whole-branch review at the end before opening the PR). The SDD skill's own
  scripts (`sdd-workspace`, `task-brief`, `review-package`) handle ledger/diff
  plumbing — use them rather than reinventing.
- **This is the largest, most interaction-heavy part of the three.** Part
  3's spec itself is the longest section and touches a new controller
  action, a new dialog component, engine.rb permissions, a contract change,
  and a service parameter change, all coupled together. Consider whether the
  plan should split it into more, smaller tasks than Part 1 needed — the
  writing-plans skill's "Scope Check" section has guidance on this.

## Staying out of Part 2's way (parallel session note)

Another session is implementing Part 2 (R11) at the same time, off the same
`epic` base. File overlap is minimal:

- R12 (this session) touches: `modules/meeting/app/services/recurring_meetings/update_service.rb`
  (`apply_scope` plumbing), `modules/meeting/app/services/recurring_meetings/end_service.rb`
  (`end_date:` keyword), `modules/meeting/app/contracts/recurring_meetings/end_series_contract.rb`,
  a new `Meetings::CloseDialogComponent` + `close`/`close_dialog` route +
  controller action, `modules/meeting/lib/open_project/meeting/engine.rb`
  (permission registration), and their specs.
- R11 (the other session) touches `modules/meeting/app/forms/meeting/time_group.rb`,
  contract/controller strong-param plumbing for `time_zone`, and a narrow
  slice of `recurring_meeting.rb` (a validation method and
  `reschedule_required?` only) — none of which this session should need to
  touch.
- If you find yourself needing to add a `time_zone` field to a form, a
  contract, or controller strong params, stop and reconsider — that's very
  likely Part 2's territory, not this session's. Your close/scope work does
  legitimately touch `recurring_meeting.rb` and `update_service.rb` in
  places R11 does not (the `apply_scope` sweep, `EndService`'s `end_date:`)
  — that's expected and fine.
- Branch off the current tip of `epic` (already includes Part 1's merge).
  Since both sessions are working concurrently, rebase onto `epic` again
  right before opening your PR in case Part 2 has already landed.

## What to do right now

1. Read the spec's Part 3 section in full, including the revision-note
   paragraphs near the top of the document (they explain several
   already-rejected approaches you should not reintroduce) — this note is
   only orientation, not a substitute.
2. Invoke `superpowers:writing-plans` on Part 3, producing an implementation
   plan under `docs/superpowers/plans/`.
3. Present the plan's execution-choice question (subagent-driven vs. inline)
   as that skill directs, and proceed.
4. Branch name suggestion: `feature/meeting-batch2-part3-scope-chooser`.
5. When done: full whole-branch review, then `superpowers:finishing-a-development-branch`
   (push + PR against `epic`, same as Part 1).

Update the `meeting-improvements` memory (if you have access to it) with
what actually shipped once this merges, the same way Part 1's summary was
recorded — future sessions rely on it.
