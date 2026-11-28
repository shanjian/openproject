# Meeting recurrence: readable presets, weekday sets, monthly/yearly rules, live preview

**Date:** 2026-08-13
**Status:** Approved (scope confirmed by user: "full redesign" — R1 + R2 + R3 + R4 from
`OpenProject-会议功能改进需求说明.md`)

## Problem

The recurring-meeting form supports only three frequencies — `daily`, `working_days`,
`weekly` (`modules/meeting/app/models/recurring_meeting.rb:67-74`) — with a single
`interval`. Concretely missing, per the requirements doc:

- **R2**: one series meeting on several weekdays ("standup Mon/Wed/Fri"). The weekly rule
  always recurs on the start date's weekday only (`frequency_rule`,
  `recurring_meeting.rb:354-367` — `IceCube::Rule.weekly(interval)` with no `.day(...)`).
- **R3**: monthly and yearly recurrence ("first Friday each month", "annual review on
  Sep 4"). `frequency_rule` raises `NotImplementedError` for anything else.
- **R1**: the dropdown shows abstract units ("Every week") that the user must mentally
  combine with the start date. The doc wants concrete, start-date-derived options
  ("Weekly on Friday", "Monthly on the first Friday").
- **R4**: no occurrence preview — users can't confirm the rule does what they meant. Two
  documented traps: a "monthly on the last Friday" series starting on the *first* Friday
  begins three weeks after its start date, and "monthly on the 31st" silently skips short
  months.

The engine is not the limiter: `ice_cube` (~0.17, `Gemfile:181`) natively supports
weekday sets (`Rule.weekly.day(:monday, :wednesday)`), monthly by-monthday /
by-nth-weekday (including negatives for "last"), and yearly rules. Everything below is
app-layer: schema, rule construction, form, and preview.

## Design

### 1. Schema (one migration on `recurring_meetings`)

```ruby
add_column :recurring_meetings, :weekdays, :integer, array: true, default: [], null: false
add_column :recurring_meetings, :schedule_mode, :integer, default: 0, null: false
add_column :recurring_meetings, :month_day, :integer, null: true
add_column :recurring_meetings, :week_ordinal, :integer, null: true

# Backfill: existing weekly series recur on their start date's weekday; make it explicit.
execute <<~SQL
  UPDATE recurring_meetings
  SET weekdays = ARRAY[EXTRACT(ISODOW FROM start_time)::integer]
  WHERE frequency = 2
SQL
```

- `weekdays` — ISO weekday numbers (1 = Monday … 7 = Sunday), used when `weekly`. The
  backfill is semantics-preserving: `Rule.weekly(n).day(start_weekday)` generates the
  identical schedule to today's `Rule.weekly(n)` anchored on the start time.
- `schedule_mode` — enum `{ day_of_month: 0, nth_weekday: 1 }`, used by `monthly` and
  `yearly`.
- `month_day` — `1..31` or `-1` (last day), used in `day_of_month` mode; `nil` means
  "derive from start date" (`start_time.day`). Explicitly storable because the doc's R4
  trap table requires rules like "monthly on the 31st" with a start date that isn't
  the 31st.
- `week_ordinal` — `1..4` or `-1` (last), used in `nth_weekday` mode; `nil` derives from
  the start date's position in its month. Explicitly storable because "monthly on the
  **last** Friday" must be selectable even when the start date is the *first* Friday
  (R4 trap #1). The weekday itself always derives from the start date — every doc example
  keeps them aligned, and decoupling it is custom-dialog scope nobody asked for.

`frequency` enum gains `monthly: 3, yearly: 4` (`working_days` untouched — see §3 on the
"Every weekday" preset).

### 2. Rule construction (`RecurringMeeting#frequency_rule`)

```ruby
when "weekly"
  rule = IceCube::Rule.weekly(interval)
  rule = rule.day(*iso_weekday_symbols) if weekdays.any?
  rule
when "monthly"
  if schedule_mode_nth_weekday?
    IceCube::Rule.monthly(interval).day_of_week(start_weekday_sym => [effective_week_ordinal])
  else
    IceCube::Rule.monthly(interval).day_of_month(effective_month_day)
  end
when "yearly"
  if schedule_mode_nth_weekday?
    IceCube::Rule.yearly(interval).month_of_year(start_time.month)
                 .day_of_week(start_weekday_sym => [effective_week_ordinal])
  else
    IceCube::Rule.yearly(interval).month_of_year(start_time.month)
                 .day_of_month(effective_month_day)
  end
```

with `effective_month_day` = `month_day || start_time.day`, `effective_week_ordinal` =
`week_ordinal || ordinal_of_start_in_month`, and `iso_weekday_symbols` mapping 1..7 →
`:monday`..`:sunday`. Short-month skipping ("monthly on the 31st" has no September
occurrence) is native RRULE/ice_cube semantics — no code needed, only the preview hint
(§4). Both `schedule` and `ical_schedule` build from `frequency_rule`, so the `.ics`
attachments pick the new rules up automatically (`ice_cube`'s `to_ical` serializes them
as standard RRULEs).

`reschedule_required?` (`recurring_meeting.rb:235-239`) adds
`weekdays schedule_mode month_day week_ordinal` to its watched-attribute list, so
`RecurringMeetings::UpdateService` reschedules future occurrences when they change.

Validations (`RecurringMeetings::BaseContract` + model):

- `weekdays`: required non-empty when `weekly` (the backfill makes this safe for existing
  rows), each in `1..7`, unique. Ignored (and normalized to `[]`) for other frequencies.
- `month_day`: `nil`, `-1`, or `1..31`; only when `monthly`/`yearly` in `day_of_month`
  mode.
- `week_ordinal`: `nil`, `-1`, or `1..4`; only in `nth_weekday` mode.

### 3. R1 — preset dropdown computed from the start date

The `RecurringMeeting::Frequency` form (`modules/meeting/app/forms/recurring_meeting/frequency.rb`)
becomes a **preset** select whose labels are computed from the current start date
(start 2026-09-04, a Friday, shown):

| Preset option | Maps to |
|---|---|
| Daily | `frequency: daily, interval: 1` |
| Weekly on Friday | `weekly, weekdays: [5], interval: 1` |
| Monthly on the first Friday | `monthly, nth_weekday, week_ordinal: 1, interval: 1` |
| Annually on September 4 | `yearly, day_of_month, interval: 1` |
| Every working day | existing `working_days` (unchanged) |
| Custom… | reveals the detail fields below |

Presets write their mapped values into hidden fields; choosing **Custom…** reveals the
detail group: frequency-unit select (day/week/month/year) + the existing `interval`
field (moved here per R1) + weekday toggle buttons (weekly) + mode radios with concrete
labels ("on day 4" / "on the first Friday", monthly/yearly). Reveal/hide uses the
`show-when-value-selected` Stimulus pattern the form already uses for `frequency` and
`end_after`. When the start date changes, the preset labels re-render server-side through
the same turbo endpoint as the preview (§4). On edit, a model method
`RecurringMeeting#matching_preset` reverse-maps stored fields to a preset (or Custom) so
the select shows the right selection.

Two deliberate deviations from the doc's option list:

- **No "Does not repeat" option.** One-time vs. recurring is an OpenProject meeting
  *type* chosen before this form exists; a non-repeating `RecurringMeeting` would
  restructure meeting creation for no gain.
- **"Every weekday (Monday to Friday)" maps to the existing `working_days` frequency**
  rather than a fixed Mon–Fri weekly rule. It honors the instance's configured working
  days and non-working-day exclusions — strictly closer to what a user means by
  "every workday" than a hardcoded Mon–Fri, and it keeps the existing option's behavior.

### 4. R4 — live preview with the next 5 occurrences

`RecurringMeetings::ScheduleController` (`humanize_schedule`,
`schedule_controller.rb`) already re-renders a one-line schedule summary on every form
input via turbo-stream, driven by `updateFrequencyText` in
`frontend/src/stimulus/controllers/dynamic/recurring-meetings/form.controller.ts`. R4
extends exactly this path:

- `schedule_params` grows to permit `weekdays: []`, `schedule_mode`, `month_day`,
  `week_ordinal`, `end_after`, `end_date`, `iterations`, and the preset field; the
  stimulus controller adds them to the query string it already builds.
- The response becomes a partial replacing the `recurring-meeting-frequency-schedule`
  block with:
  - the summary line: `human_frequency_schedule` + total count + end date when the
    series ends (`full_schedule_in_words` already composes most of this);
  - the next 5 occurrences: `scheduled_occurrences(limit: 5, from_time: start_time - 1)`,
    each as localized date + weekday;
  - **trap hint 1**: when the first occurrence differs from the start date —
    "The first meeting of this series takes place on {datetime}";
  - **trap hint 2**: when `day_of_month` mode with effective day ≥ 29 —
    "Months shorter than {day} days are skipped".
- The turbo-stream response also updates the preset select's option labels (§3) in the
  same round trip, since both depend on the start date.

The action stays `no_authorization_required!` like today — it formats transient input
and touches no records.

Model text methods (`human_frequency`, `base_schedule`) gain branches for weekday lists
("every 2 weeks on Monday, Wednesday, Friday"), monthly ("every month on the first
Friday" / "on day 31"), and yearly, with new keys under
`recurring_meeting.in_words.*` / `recurring_meeting.frequency.*` in the module's
`en.yml` (source locale only; others via Crowdin per project convention).

## Tests

The requirements doc's measured RRULE table becomes model spec cases verbatim (all with
`DTSTART 2026-09-04T17:00`, first 6 occurrences):

| Rule under test | Expected |
|---|---|
| weekly, weekdays Mon/Wed/Fri, interval 2 | 09-04, 09-14, 09-16, 09-18, 09-28, 09-30 |
| monthly, nth_weekday, ordinal 1 | 09-04, 10-02, 11-06, 12-04, 2027-01-01, 2027-02-05 |
| monthly, nth_weekday, ordinal -1 | 09-25, 10-30, 11-27, 12-25, 2027-01-29, 2027-02-26 |
| monthly, day_of_month 31 | 10-31, 12-31, 2027-01-31, 03-31, 05-31, 07-31 |
| monthly, day_of_month -1 | 09-30, 10-31, 11-30, 12-31, 2027-01-31, 2027-02-28 |
| yearly, day_of_month | 2026..2031 each 09-04 |

Plus: contract specs for the §2 validations; a migration spec asserting the weekly
backfill preserves the next occurrences of an existing series; controller spec for the
extended preview params and both trap hints (the two doc scenarios: last-Friday start
mismatch → hint 1 with 09-25; day 31 → hint 2); feature spec driving the form through
preset selection, custom weekday toggling, and asserting the preview list; and a spec
that `matching_preset` round-trips every preset.

## Out of scope

- Decoupling the nth-weekday's *weekday* from the start date (custom dialog could allow
  "monthly on the last Tuesday" with a Friday start) — no requirement asks for it.
- `EXDATE`-style single-occurrence exclusions — the existing `ScheduledMeeting`
  cancellation already covers this.
- Changing `working_days` semantics or the `NonWorkingDay` exclusion logic.
- COUNT/UNTIL handling — `end_after`/`iterations`/`end_date` already implement these and
  compose with the new rules through the untouched `count_rule`.
