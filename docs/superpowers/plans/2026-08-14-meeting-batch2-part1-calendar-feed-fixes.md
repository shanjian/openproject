# Meeting Batch-2 Part 1: Calendar Subscription Feed Fixes (R10) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three calendar-subscription-feed defects reported against `/meetings/ical/:token` (Thunderbird sync): stale `SEQUENCE` on schedule-only series edits, ended series still projecting future occurrences, and a too-slow refresh interval — plus a related occurrence-level ICS change-detection bug this same class of fix exposes.

**Architecture:** All four fixes live in `modules/meeting/app/services/meetings/icalendar_builder.rb` (the shared ICS renderer used by both the subscription feed and the email-attachment path) and one caller in `modules/meeting/app/services/recurring_meetings/update_service.rb`. No new classes; this batch adds one migration, one new private-ish builder method, one small signature extension, and two formula/interval fixes to existing methods.

**Tech Stack:** Ruby 3.4.7 / Rails 8.0.3, RSpec, the `icalendar` gem (`Icalendar::Calendar`/`Icalendar::Values::DateTime`), PostgreSQL.

**Spec:** `docs/superpowers/specs/2026-08-14-meeting-batch2-calendar-timezone-scope-design.md` (Part 1, §1a–§1d). This plan implements only Part 1 — R8/R9 need no work (already shipped), Parts 2 (R11 timezone) and 3 (R12 scope) get their own plans after this one merges, per the spec's own "one PR per part" sequencing.

## Global Constraints

- One PR for this plan (Part 1 only); branch off `epic`, target `epic`.
- Every new/changed method gets a test in the *existing* spec file that already covers it — do not create parallel spec files for behavior the existing suite already exercises (`icalendar_builder_spec.rb`, `all_meetings/ical_service_spec.rb`).
- `RecurringMeeting` needs a `lock_version` column added (does not have one today) — a plain Rails migration; optimistic locking activates automatically once the column exists, no model-level declaration needed (mirrors how `Meeting#lock_version` already works with no special config).
- Reuse `SEQUENCE = recurring_meeting.lock_version + template.lock_version` and `LAST-MODIFIED = [recurring_meeting.updated_at, template.updated_at].max` everywhere the spec calls for "the same formula" — do not invent a second counter or comparison anywhere in this batch.
- Run `bundle exec rubocop <changed files>` and `bundle exec rspec <changed specs>` before each commit; this repo's `db/structure.sql` is gitignored, so no separate schema commit is needed after running the migration locally.
- Follow existing code style in the touched files exactly (frozen_string_literal header, copyright banner on new files, `# rubocop:disable Metrics/AbcSize` on methods that already carry it if the fix adds complexity to them).

---

### Task 1: Add `lock_version` to `recurring_meetings`

**Files:**
- Create: `modules/meeting/db/migrate/20260814100000_add_lock_version_to_recurring_meetings.rb`
- Test: `modules/meeting/spec/models/recurring_meeting_spec.rb` (append; create the file with this one example if it doesn't exist yet — check first)

**Interfaces:**
- Produces: `RecurringMeeting#lock_version` (integer, default 0, standard Rails optimistic-locking column) — consumed by Task 2 and Task 5's tombstone.

- [ ] **Step 1: Check whether the spec file exists**

Run: `test -f modules/meeting/spec/models/recurring_meeting_spec.rb && echo EXISTS || echo MISSING`

If `EXISTS`, you'll append the example from Step 2 into its top-level `RSpec.describe RecurringMeeting do ... end` block instead of creating a new file. If `MISSING`, create it fresh using the file content in Step 2.

- [ ] **Step 2: Write the failing test**

If the file is missing, create `modules/meeting/spec/models/recurring_meeting_spec.rb`:

```ruby
# frozen_string_literal: true

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

require "spec_helper"

RSpec.describe RecurringMeeting do
  describe "#lock_version" do
    it "increments on every save (optimistic locking)" do
      recurring_meeting = create(:recurring_meeting)

      expect { recurring_meeting.update!(interval: recurring_meeting.interval + 1) }
        .to change(recurring_meeting, :lock_version).by(1)
    end
  end
end
```

If the file already exists, add the `describe "#lock_version"` block above into its existing `RSpec.describe RecurringMeeting do ... end`.

- [ ] **Step 3: Run test to verify it fails**

Run: `bundle exec rspec modules/meeting/spec/models/recurring_meeting_spec.rb -e "#lock_version"`
Expected: FAIL — `NoMethodError: undefined method 'lock_version'` or a missing-column error, since the column doesn't exist yet.

- [ ] **Step 4: Write the migration**

Create `modules/meeting/db/migrate/20260814100000_add_lock_version_to_recurring_meetings.rb`:

```ruby
# frozen_string_literal: true

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

class AddLockVersionToRecurringMeetings < ActiveRecord::Migration[8.0]
  # Needed so the series master VEVENT's SEQUENCE can reflect schedule-only
  # edits (see icalendar_builder.rb) — RecurringMeeting had no optimistic-lock
  # column before this.
  def change
    add_column :recurring_meetings, :lock_version, :integer, default: 0, null: false
  end
end
```

Run: `bundle exec rails db:migrate`

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec modules/meeting/spec/models/recurring_meeting_spec.rb -e "#lock_version"`
Expected: PASS

- [ ] **Step 6: Also migrate the test database and run rubocop**

Run: `RAILS_ENV=test bundle exec rails db:migrate`
Run: `bundle exec rubocop modules/meeting/db/migrate/20260814100000_add_lock_version_to_recurring_meetings.rb modules/meeting/spec/models/recurring_meeting_spec.rb`
Expected: no offenses.

- [ ] **Step 7: Commit**

```bash
git add modules/meeting/db/migrate/20260814100000_add_lock_version_to_recurring_meetings.rb modules/meeting/spec/models/recurring_meeting_spec.rb
git commit -m "Add lock_version to recurring_meetings for ICS SEQUENCE tracking"
```

---

### Task 2: Fix `SEQUENCE`/`LAST-MODIFIED` for series-level VEVENTs

**Files:**
- Modify: `modules/meeting/app/services/meetings/icalendar_builder.rb:81-125` (`add_series_event`), `:307-341` (`add_virtual_occurences_for_interim_responses`)
- Test: `modules/meeting/spec/services/meetings/icalendar_builder_spec.rb` (append to the existing `context "with recurring meeting series"` block)

**Interfaces:**
- Consumes: `RecurringMeeting#lock_version` (Task 1).
- Produces: no new public methods — `add_series_event`'s and `add_virtual_occurences_for_interim_responses`'s emitted `SEQUENCE`/`LAST-MODIFIED` values change; Task 5's tombstone reuses this exact formula.

- [ ] **Step 1: Write the failing test**

Add to `modules/meeting/spec/services/meetings/icalendar_builder_spec.rb`, inside the existing `context "with recurring meeting series"` block (after the `"when using the cache"` context, before `"when current user needs to take action"`):

```ruby
    context "when a schedule-only field changes (REGRESSION: series SEQUENCE never bumped)" do
      subject(:builder) { described_class.new(timezone:) }

      it "increases SEQUENCE on the master event after a recurring_meeting-only change" do
        builder.add_series_event(recurring_meeting:)
        master_before = Icalendar::Calendar.parse(builder.to_ical).first
                                            .events.find { |e| e.rrule.present? }
        sequence_before = master_before.sequence

        recurring_meeting.update!(interval: recurring_meeting.interval + 1)
        recurring_meeting.reload

        builder2 = described_class.new(timezone:)
        builder2.add_series_event(recurring_meeting:)
        master_after = Icalendar::Calendar.parse(builder2.to_ical).first
                                           .events.find { |e| e.rrule.present? }

        expect(master_after.sequence).to be > sequence_before
      end

      it "sets LAST-MODIFIED to the newer of the series' and template's updated_at" do
        recurring_meeting.update!(interval: recurring_meeting.interval + 1)
        recurring_meeting.reload

        builder.add_series_event(recurring_meeting:)
        master = Icalendar::Calendar.parse(builder.to_ical).first
                                     .events.find { |e| e.rrule.present? }

        expected = [recurring_meeting.updated_at, recurring_meeting.template.updated_at].max
        expect(master.last_modified.to_time).to be_within(1.second).of(expected)
      end
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec modules/meeting/spec/services/meetings/icalendar_builder_spec.rb -e "REGRESSION: series SEQUENCE never bumped"`
Expected: FAIL on the first example — `sequence_before` and `sequence_after` are equal (both derive from `template.lock_version` alone, which didn't change).

- [ ] **Step 3: Fix `add_series_event`**

In `modules/meeting/app/services/meetings/icalendar_builder.rb`, change lines 92-93:

```ruby
        e.last_modified = [recurring_meeting.template.updated_at, recurring_meeting.updated_at].max.utc
        e.sequence = recurring_meeting.template.lock_version
```

to:

```ruby
        e.last_modified = [recurring_meeting.template.updated_at, recurring_meeting.updated_at].max.utc
        e.sequence = recurring_meeting.lock_version + recurring_meeting.template.lock_version
```

(`last_modified` here was already correct — only `sequence` needs the added term.)

- [ ] **Step 4: Fix `add_virtual_occurences_for_interim_responses`**

In the same file, change line 326:

```ruby
          e.sequence = recurring_meeting.template.lock_version
```

to:

```ruby
          e.sequence = recurring_meeting.lock_version + recurring_meeting.template.lock_version
```

(`last_modified` on line 325 is already `[recurring_meeting.template.updated_at, recurring_meeting.updated_at].max.utc` — no change needed there.)

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec modules/meeting/spec/services/meetings/icalendar_builder_spec.rb -e "REGRESSION: series SEQUENCE never bumped"`
Expected: PASS

- [ ] **Step 6: Run the full existing builder spec to check for regressions**

Run: `bundle exec rspec modules/meeting/spec/services/meetings/icalendar_builder_spec.rb`
Expected: all examples PASS (the sequence values used in other examples are not asserted against fixed numbers, only presence/attendee fields, so this change should not break them — verify by reading any failure output if one appears).

- [ ] **Step 7: Rubocop and commit**

Run: `bundle exec rubocop modules/meeting/app/services/meetings/icalendar_builder.rb modules/meeting/spec/services/meetings/icalendar_builder_spec.rb`

```bash
git add modules/meeting/app/services/meetings/icalendar_builder.rb modules/meeting/spec/services/meetings/icalendar_builder_spec.rb
git commit -m "Fix stale SEQUENCE on schedule-only recurring meeting edits"
```

---

### Task 3: Faster refresh interval (`PT15M` + `X-PUBLISHED-TTL`)

**Files:**
- Modify: `modules/meeting/app/services/meetings/icalendar_builder.rb:203-208` (`build_icalendar`)
- Test: `modules/meeting/spec/services/meetings/icalendar_builder_spec.rb:46` (existing `"sets the calendar properties"` example)

**Interfaces:**
- Produces: no new methods — changes the `REFRESH-INTERVAL` value emitted by every generated calendar and adds `X-PUBLISHED-TTL`.

- [ ] **Step 1: Update the failing assertion**

In `modules/meeting/spec/services/meetings/icalendar_builder_spec.rb`, change the existing example (around line 40-46):

```ruby
    it "sets the calendar properties" do
      expect(parsed_calendar.prodid).to eq("-//OpenProject GmbH//#{OpenProject::VERSION}//Meeting//EN")
      expect(parsed_calendar.version).to eq("2.0")
      expect(parsed_calendar.calscale).to eq("GREGORIAN")
      expect(parsed_calendar.refresh_interval.value_ical).to eq("PT6H")
    end
```

to:

```ruby
    it "sets the calendar properties" do
      expect(parsed_calendar.prodid).to eq("-//OpenProject GmbH//#{OpenProject::VERSION}//Meeting//EN")
      expect(parsed_calendar.version).to eq("2.0")
      expect(parsed_calendar.calscale).to eq("GREGORIAN")
      expect(parsed_calendar.refresh_interval.value_ical).to eq("PT15M")
      expect(parsed_calendar.custom_property("X-PUBLISHED-TTL").first).to eq("PT15M")
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec modules/meeting/spec/services/meetings/icalendar_builder_spec.rb -e "sets the calendar properties"`
Expected: FAIL — current value is still `PT6H` and `X-PUBLISHED-TTL` is not set (empty array from `custom_property`).

- [ ] **Step 3: Implement the fix**

In `modules/meeting/app/services/meetings/icalendar_builder.rb`, change `build_icalendar` (lines 203-208):

```ruby
    def build_icalendar
      ::Icalendar::Calendar.new.tap do |calendar|
        calendar.prodid = "-//OpenProject GmbH//#{OpenProject::VERSION}//Meeting//EN"
        calendar.refresh_interval = 6.hours.iso8601
      end
    end
```

to:

```ruby
    def build_icalendar
      ::Icalendar::Calendar.new.tap do |calendar|
        calendar.prodid = "-//OpenProject GmbH//#{OpenProject::VERSION}//Meeting//EN"
        # REFRESH-INTERVAL is the RFC 7986 property; X-PUBLISHED-TTL is the
        # older de-facto one some clients (older Thunderbird/Lightning
        # builds) read instead — set both so refresh timing is honored
        # regardless of which one a given client supports.
        calendar.refresh_interval = 15.minutes.iso8601
        calendar.append_custom_property("X-PUBLISHED-TTL", 15.minutes.iso8601)
      end
    end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec modules/meeting/spec/services/meetings/icalendar_builder_spec.rb -e "sets the calendar properties"`
Expected: PASS. If `append_custom_property` is not the correct `icalendar` gem API for a calendar-level `X-` property, check the gem's `Icalendar::Calendar` source (`bundle show icalendar` to find the gem path, then `grep -n "custom_property\|def x_property\|ATTRIBUTES\|method_missing" <gem_path>/lib/icalendar/component.rb`) and adjust to whatever accessor the gem exposes for calendar-level `X-` properties — the test's `custom_property("X-PUBLISHED-TTL")` read must match however it was written.

- [ ] **Step 5: Rubocop and commit**

Run: `bundle exec rubocop modules/meeting/app/services/meetings/icalendar_builder.rb modules/meeting/spec/services/meetings/icalendar_builder_spec.rb`

```bash
git add modules/meeting/app/services/meetings/icalendar_builder.rb modules/meeting/spec/services/meetings/icalendar_builder_spec.rb
git commit -m "Reduce ICS feed refresh interval from 6h to 15m"
```

---

### Task 4: Let `add_single_meeting_event` render in an explicit timezone

**Files:**
- Modify: `modules/meeting/app/services/meetings/icalendar_builder.rb:53-79` (`add_single_meeting_event`)
- Test: `modules/meeting/spec/services/meetings/icalendar_builder_spec.rb` (new example in the existing `context "with a single meeting"` block)

**Interfaces:**
- Consumes: nothing new.
- Produces: `add_single_meeting_event(meeting:, cancelled: false, timezone: builder_internal_timezone)` — the new `timezone:` keyword, defaulting to today's behavior. Task 5's `add_ended_series_history` calls this with `timezone: recurring_meeting.time_zone` explicitly so history events keep rendering in the series' own zone (matching how they rendered while the series was active) rather than switching to the viewing user's zone the moment the series ends.

- [ ] **Step 1: Write the failing test**

Add to the `context "with a single meeting"` block in `modules/meeting/spec/services/meetings/icalendar_builder_spec.rb` (as a sibling to the existing nested contexts):

```ruby
    context "when an explicit timezone is passed" do
      subject(:builder) { described_class.new(timezone: ActiveSupport::TimeZone["UTC"]) }

      let(:tokyo) { ActiveSupport::TimeZone["Asia/Tokyo"] }
      let(:parsed_calendar) { Icalendar::Calendar.parse(builder.to_ical).first }

      it "renders DTSTART/DTEND in the passed timezone instead of the builder's own" do
        builder.add_single_meeting_event(meeting:, timezone: tokyo)
        builder.update_calendar_status(cancelled: false)

        event = parsed_calendar.events.find { |e| e.uid == meeting.uid }
        expect(event.dtstart.ical_params["tzid"]).to eq(["Asia/Tokyo"])
      end
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec modules/meeting/spec/services/meetings/icalendar_builder_spec.rb -e "when an explicit timezone is passed"`
Expected: FAIL — `add_single_meeting_event` doesn't accept a `timezone:` keyword (`ArgumentError: unknown keyword: :timezone`).

- [ ] **Step 3: Implement the fix**

In `modules/meeting/app/services/meetings/icalendar_builder.rb`, change `add_single_meeting_event` (lines 53-79):

```ruby
    def add_single_meeting_event(meeting:, cancelled: false) # rubocop:disable Metrics/AbcSize
      calendar.event do |e|
        e.dtstart = ical_datetime(meeting.start_time)
        e.dtend = ical_datetime(meeting.end_time)
```

to:

```ruby
    def add_single_meeting_event(meeting:, cancelled: false, timezone: builder_internal_timezone) # rubocop:disable Metrics/AbcSize
      calendar.event do |e|
        e.dtstart = ical_datetime(meeting.start_time, timezone:)
        e.dtend = ical_datetime(meeting.end_time, timezone:)
```

(the rest of the method body is unchanged — only the signature and these two lines).

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec modules/meeting/spec/services/meetings/icalendar_builder_spec.rb -e "when an explicit timezone is passed"`
Expected: PASS

- [ ] **Step 5: Run the full builder spec to confirm the default-timezone callers are unaffected**

Run: `bundle exec rspec modules/meeting/spec/services/meetings/icalendar_builder_spec.rb`
Expected: all PASS — existing callers don't pass `timezone:`, so they keep using `builder_internal_timezone` exactly as before.

- [ ] **Step 6: Rubocop and commit**

Run: `bundle exec rubocop modules/meeting/app/services/meetings/icalendar_builder.rb modules/meeting/spec/services/meetings/icalendar_builder_spec.rb`

```bash
git add modules/meeting/app/services/meetings/icalendar_builder.rb modules/meeting/spec/services/meetings/icalendar_builder_spec.rb
git commit -m "Let add_single_meeting_event render in an explicit timezone"
```

---

### Task 5: Ended-series history rendering + series-UID tombstone

**Files:**
- Modify: `modules/meeting/app/services/meetings/icalendar_builder.rb` (add `add_ended_series_history`, add the internal ended-series guard to `add_series_event`)
- Test: `modules/meeting/spec/services/meetings/icalendar_builder_spec.rb` (new `context "with an ended recurring meeting series"` block)

**Interfaces:**
- Consumes: `RecurringMeeting#has_ended?` (existing), `RecurringMeeting#lock_version`/`#time_zone`/`#current_schedule_start`/`#current_schedule_end` (existing plus Task 1), `add_single_meeting_event(meeting:, cancelled:, timezone:)` (Task 4).
- Produces: `IcalendarBuilder#add_ended_series_history(recurring_meeting:)` (public). Task 6 is test-only and calls no new method directly — `AllMeetings::ICalService#call` needs no code change, since `add_series_event`'s self-guard (added in this task) covers it, and `RecurringMeetings::ICalService#generate_series` (the mailer path) picks up the same fix automatically for the same reason.

- [ ] **Step 1: Write the failing tests**

Add a new top-level context to `modules/meeting/spec/services/meetings/icalendar_builder_spec.rb`, as a sibling of `context "with recurring meeting series"`:

```ruby
  context "with an ended recurring meeting series" do
    subject(:builder) { described_class.new(timezone:) }

    let(:project) { create(:project) }
    let(:parsed_calendar) { Icalendar::Calendar.parse(builder.to_ical).first }

    let(:recurring_meeting) do
      create(:recurring_meeting,
             start_time: Time.zone.parse("2025-08-01 09:00"),
             project:,
             end_after: :specific_date,
             end_date: 3.days.ago.to_date,
             time_zone: timezone.tzinfo.name)
    end

    let!(:past_occurrence) do
      create(:scheduled_meeting, :persisted,
             recurring_meeting:,
             start_time: 2.days.ago,
             meeting_start_time: 2.days.ago)
    end

    let!(:cancelled_past_occurrence) do
      create(:scheduled_meeting, :cancelled, :persisted,
             recurring_meeting:,
             start_time: 4.days.ago,
             meeting_start_time: 4.days.ago)
    end

    it "renders each surviving past instantiated occurrence as a standalone VEVENT" do
      builder.add_ended_series_history(recurring_meeting:)

      history_event = parsed_calendar.events.find { |e| e.uid == past_occurrence.meeting.uid }
      expect(history_event).to be_present
      expect(history_event.recurrence_id).to be_blank
      expect(history_event.rrule).to be_empty
      expect(history_event.status).to eq("CONFIRMED")
    end

    it "excludes cancelled past occurrences" do
      builder.add_ended_series_history(recurring_meeting:)

      expect(parsed_calendar.events.map(&:uid)).not_to include(cancelled_past_occurrence.meeting.uid)
    end

    it "does not render interim-response placeholder events" do
      # No factory exists for this model in the codebase — every existing spec
      # (e.g. icalendar_builder_spec.rb's other context) builds it directly.
      RecurringMeetingInterimResponse.create!(
        recurring_meeting:,
        user: create(:user),
        start_time: 1.day.from_now,
        participation_status: :accepted
      )

      builder.add_ended_series_history(recurring_meeting:)

      expect(parsed_calendar.events.map(&:uid)).to all(eq(recurring_meeting.uid).or(eq(past_occurrence.meeting.uid)))
    end

    it "emits a CANCELLED tombstone for the series UID with no RECURRENCE-ID or RRULE" do
      builder.add_ended_series_history(recurring_meeting:)

      tombstone = parsed_calendar.events.find { |e| e.uid == recurring_meeting.uid }
      expect(tombstone).to be_present
      expect(tombstone.status).to eq("CANCELLED")
      expect(tombstone.recurrence_id).to be_blank
      expect(tombstone.rrule).to be_empty
    end

    it "gives the tombstone a SEQUENCE strictly greater than what the master last advertised" do
      cached_sequence = recurring_meeting.lock_version + recurring_meeting.template.lock_version

      builder.add_ended_series_history(recurring_meeting:)

      tombstone = parsed_calendar.events.find { |e| e.uid == recurring_meeting.uid }
      expect(tombstone.sequence).to be > cached_sequence
    end

    it "excludes an occurrence whose scheduled slot is past but whose meeting time was edited to the future" do
      future_edited = create(:scheduled_meeting, :persisted,
                              recurring_meeting:,
                              start_time: 1.day.ago,
                              meeting_start_time: 1.day.ago)
      future_edited.meeting.update_column(:start_time, 1.day.from_now) # rubocop:disable Rails/SkipsModelValidations

      builder.add_ended_series_history(recurring_meeting:)

      expect(parsed_calendar.events.map(&:uid)).not_to include(future_edited.meeting.uid)
    end

    it "self-guards inside add_series_event so the mailer path also gets history rendering" do
      builder.add_series_event(recurring_meeting:)

      expect(parsed_calendar.events.map(&:uid)).to include(past_occurrence.meeting.uid, recurring_meeting.uid)
      expect(parsed_calendar.events.none? { |e| e.rrule.present? }).to be true
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec modules/meeting/spec/services/meetings/icalendar_builder_spec.rb -e "with an ended recurring meeting series"`
Expected: FAIL — `add_ended_series_history` doesn't exist yet (`NoMethodError`), and `add_series_event` still renders the old (buggy) master-event behavior for the self-guard example.

- [ ] **Step 3: Add the ended-series guard and the new method**

In `modules/meeting/app/services/meetings/icalendar_builder.rb`, change the top of `add_series_event` (line 81):

```ruby
    def add_series_event(recurring_meeting:, cancelled: false) # rubocop:disable Metrics/AbcSize
      calendar.event do |e|
```

to:

```ruby
    def add_series_event(recurring_meeting:, cancelled: false) # rubocop:disable Metrics/AbcSize
      return add_ended_series_history(recurring_meeting:) if recurring_meeting.has_ended?

      calendar.event do |e|
```

Then add the new public method right after `add_single_recurring_occurrence` ends (after line 158, before `def update_calendar_status`):

```ruby
    # Renders history for a series that has already ended: standalone VEVENTs
    # for its past, non-cancelled instantiated occurrences (own UID each, no
    # RECURRENCE-ID/RRULE — there is no live master to attach an override to
    # once the series stops projecting future occurrences), plus one
    # CANCELLED tombstone for the series UID so a client that cached the old
    # master (and its overrides) under that UID is told it is gone.
    #
    # Filters on the *rendered* field (meeting.start_time), not
    # scheduled_meeting.start_time: the two can diverge when a single
    # occurrence's time was edited directly without its scheduled slot
    # following, and filtering on the wrong one could still emit a future
    # DTSTART for an "ended" series.
    def add_ended_series_history(recurring_meeting:)
      recurring_meeting
        .scheduled_meetings
        .instantiated
        .not_cancelled
        .includes(meeting: [:project])
        .select { |scheduled_meeting| scheduled_meeting.meeting.start_time <= Time.zone.now }
        .each do |scheduled_meeting|
          add_single_meeting_event(
            meeting: scheduled_meeting.meeting,
            cancelled: false,
            timezone: recurring_meeting.time_zone
          )
        end

      add_series_tombstone(recurring_meeting:)
    end
```

Separately, add the tombstone method as a **private** method — insert it directly below the `private` keyword (line 197), right before `def series_cache_loaded?`:

```ruby
    def add_series_tombstone(recurring_meeting:) # rubocop:disable Metrics/AbcSize
      calendar.event do |e|
        e.uid = recurring_meeting.uid
        e.summary = recurring_meeting.title
        e.organizer = ical_organizer
        e.status = "CANCELLED"
        e.sequence = recurring_meeting.lock_version + recurring_meeting.template.lock_version
        e.last_modified = [recurring_meeting.updated_at, recurring_meeting.template.updated_at].max.utc
        e.dtstart = ical_datetime(recurring_meeting.current_schedule_start, timezone: recurring_meeting.time_zone)
        e.dtend = ical_datetime(recurring_meeting.current_schedule_end, timezone: recurring_meeting.time_zone)
      end
    end
```

So the file ends up with `add_ended_series_history` (public, called by `add_series_event`'s guard) living alongside the other public `add_*` methods above the `private` line, and `add_series_tombstone` (private, called only from `add_ended_series_history`) living just below `private` alongside `series_cache_loaded?` and the other helpers.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec modules/meeting/spec/services/meetings/icalendar_builder_spec.rb -e "with an ended recurring meeting series"`
Expected: PASS on all seven examples.

- [ ] **Step 5: Fix a real, confirmed regression in the existing `"with recurring meeting series"` context before running it**

The existing `recurring_meeting` fixture shared across that whole context
(lines 224-236: `start_time: Time.zone.parse("2025-08-25 09:00"), iterations: 10,
end_after: :iterations`) has already ended as of any 2026 test run —
verified directly: `RecurringMeeting.new(start_time: Time.zone.parse("2025-08-25 09:00"),
iterations: 10, end_after: "iterations").last_occurrence` evaluates to
`2025-10-27`, in the past. Once `add_series_event` self-guards on
`has_ended?`, every example in that context (which asserts master-event/RRULE/
EXDATE behavior) would silently start exercising the new history path
instead and fail. Fix the fixture, not the guard — change line 226 from:

```ruby
             start_time: Time.zone.parse("2025-08-25 09:00"),
```

to:

```ruby
             start_time: 1.week.from_now.change(hour: 9, min: 0, sec: 0),
```

This keeps every other assertion in the context intact (all of them use
offsets relative to `recurring_meeting.start_time`, e.g. `+ 1.week`,
`+ 2.weeks` — none hardcode the 2025-08-25 date directly), while keeping
`last_occurrence` (10 weekly iterations out, ~10 weeks from whenever the
suite runs) always in the future regardless of run date.

Run: `bundle exec rspec modules/meeting/spec/services/meetings/icalendar_builder_spec.rb`
Expected: all PASS.

- [ ] **Step 6: Rubocop and commit**

Run: `bundle exec rubocop modules/meeting/app/services/meetings/icalendar_builder.rb modules/meeting/spec/services/meetings/icalendar_builder_spec.rb`

```bash
git add modules/meeting/app/services/meetings/icalendar_builder.rb modules/meeting/spec/services/meetings/icalendar_builder_spec.rb
git commit -m "Render standalone history + tombstone for ended recurring series"
```

---

### Task 6: `all_meetings/ical_service_spec.rb` regression coverage for the ended-series feed

**Files:**
- Test: `modules/meeting/spec/services/all_meetings/ical_service_spec.rb` (append)

**Interfaces:**
- Consumes: `AllMeetings::ICalService#call` (existing, unchanged — Task 5's self-guard inside `add_series_event` means this service needs no code change at all; this task only adds feed-level regression coverage so the fix is proven at the service boundary users actually hit, not just at the builder unit level).

This file's top-level `let`s (confirmed by reading it) are `user` (zone `America/New_York`, granted `view_meetings` on `project`), `user2`, `project`, `relevant_time`, `service`, `result`, `include_historic`, `ical`. The existing `context "with recurring meetings"` block's `recurring_meeting` fixture pattern is:

```ruby
create(:recurring_meeting,
       author: user,
       title: "Recurring meeting",
       start_time: relevant_time,
       end_date: relevant_time.advance(week: 52).to_date,
       iterations: 52,
       project:,
       time_zone: user.time_zone).tap do |rm|
  rm.template.participants = [
    MeetingParticipant.new(user:),
    MeetingParticipant.new(user: user2)
  ]
end
```

- [ ] **Step 1: Write the failing test**

Add a new context as a sibling of `context "with a recurring meeting that has no derived meetings yet"` and `context "with a recurring meeting that has derived meetings"`, inside the existing `context "with recurring meetings"` block (after line 267's closing, i.e. before the outer block's final `end` at line 268 — nest it at the same level as the two contexts above, reusing that block's `recurring_meeting` `let!`, not redefining it):

```ruby
    context "when the series has ended" do
      before do
        recurring_meeting.update!(end_after: "specific_date", end_date: 3.days.ago.to_date)
      end

      let!(:past_occurrence) do
        RecurringMeetings::InitOccurrenceService
          .new(user: User.system, recurring_meeting:)
          .call(start_time: relevant_time - 2.days)
          .result
      end

      it "renders no VEVENT with a future DTSTART, and includes the past occurrence plus a series-UID tombstone",
         :aggregate_failures do
        expect(result).to be_a String
        expect(ical.events).to all(satisfy { |e| e.dtstart.to_time <= Time.zone.now })

        history_event = ical.events.find { |e| e.uid == past_occurrence.uid && e.recurrence_id.blank? }
        expect(history_event).to be_present
        expect(history_event.rrule).to be_empty

        tombstone = ical.events.find { |e| e.uid == recurring_meeting.uid }
        expect(tombstone.status).to eq "CANCELLED"
      end
    end
```

- [ ] **Step 2: Run test to verify it fails or passes**

Run: `bundle exec rspec modules/meeting/spec/services/all_meetings/ical_service_spec.rb -e "when the series has ended"`

This should already PASS given Task 5's fix — no service-level code change is needed here, since `add_series_event`'s internal `has_ended?` guard covers this caller (`recurring_meetings.each { |rm| calendar.add_series_event(recurring_meeting: rm, ...) }`) automatically. If it fails, read the failure carefully: check first whether `RecurringMeeting.visible(user).participated_by(user)` (used by `AllMeetings::ICalService#recurring_meetings`) excludes the now-ended series from the query entirely (in which case the fixture, not the production code, needs adjusting) before assuming the guard itself needs a service-level change.

- [ ] **Step 3: Rubocop and commit**

Run: `bundle exec rubocop modules/meeting/spec/services/all_meetings/ical_service_spec.rb`

```bash
git add modules/meeting/spec/services/all_meetings/ical_service_spec.rb
git commit -m "Add feed-level regression coverage for ended-series ICS rendering"
```

---

### Task 7: Fix occurrence-level `update_column` → `update_columns` (title sync)

**Files:**
- Modify: `modules/meeting/app/services/recurring_meetings/update_service.rb:160-170` (`update_future_occurrence_titles`)
- Test: `modules/meeting/spec/services/recurring_meetings/update_service_integration_spec.rb` (extend the existing `describe "updating series title"` block, lines 377-408)

**Interfaces:**
- Consumes: nothing new.
- Produces: no signature change — `update_future_occurrence_titles` still takes `(recurring_meeting)` and returns nothing meaningful; only its side effect changes (bumps `lock_version`/`updated_at` on synced rows in addition to `title`).

- [ ] **Step 1: Write the failing test**

This file already has a `describe "updating series title"` block (confirmed, lines 377-408) with exactly the fixtures needed: `shared_let(:past_scheduled_meeting)` and `shared_let(:scheduled_meetings)` (an array of 3 future instantiated occurrences), plus the outer file's `instance`/`params`/`service_result` `let`s (`instance = described_class.new(model: series, user:)`, `service_result = instance.call(**params)`). Add a new example inside that `describe` block, after the existing `"does not update past meeting occurrence titles"` example (before its closing `end` at line 408):

```ruby
    it "bumps the synced occurrence's lock_version and updated_at, not just its title (ICS change-detection)" do
      target = scheduled_meetings.first.meeting
      target.update_column(:updated_at, 1.day.ago) # rubocop:disable Rails/SkipsModelValidations
      lock_version_before = target.lock_version

      expect(service_result).to be_success

      target.reload
      expect(target.title).to eq("Updated series title")
      expect(target.lock_version).to be > lock_version_before
      expect(target.updated_at).to be_within(5.seconds).of(Time.current)
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec modules/meeting/spec/services/recurring_meetings/update_service_integration_spec.rb -e "bumps the synced occurrence's lock_version"`
Expected: FAIL — `lock_version` is unchanged (still equals `lock_version_before`) since `update_future_occurrence_titles` currently uses `update_column(:title, new_title)`, which touches only that one column.

- [ ] **Step 3: Implement the fix**

In `modules/meeting/app/services/recurring_meetings/update_service.rb`, change `update_future_occurrence_titles` (lines 160-170):

```ruby
    def update_future_occurrence_titles(recurring_meeting)
      new_title = @template_params[:title]
      return if new_title == @old_title

      recurring_meeting
      .scheduled_instances(upcoming: true)
      .instantiated
      .each do |scheduled|
        scheduled.meeting.update_column(:title, new_title)
      end
    end
```

to:

```ruby
    def update_future_occurrence_titles(recurring_meeting)
      new_title = @template_params[:title]
      return if new_title == @old_title

      recurring_meeting
      .scheduled_instances(upcoming: true)
      .instantiated
      .each do |scheduled|
        # update_columns (not update_column) so lock_version/updated_at bump
        # too — otherwise the propagated title is invisible to subscribed
        # calendar clients even though the in-app page shows it immediately
        # (SEQUENCE/LAST-MODIFIED on the occurrence's VEVENT derive from
        # these two fields; see icalendar_builder.rb#add_single_meeting_event
        # and #add_single_recurring_occurrence). Still skips
        # validations/callbacks like the old update_column call did — no
        # per-occurrence mail fires from this sync.
        scheduled.meeting.update_columns(
          title: new_title,
          updated_at: Time.current,
          lock_version: scheduled.meeting.lock_version + 1
        )
      end
    end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec modules/meeting/spec/services/recurring_meetings/update_service_integration_spec.rb -e "bumps the synced occurrence's lock_version"`
Expected: PASS

- [ ] **Step 5: Run the full spec file for regressions**

Run: `bundle exec rspec modules/meeting/spec/services/recurring_meetings/update_service_integration_spec.rb`
Expected: all PASS.

- [ ] **Step 6: Rubocop and commit**

Run: `bundle exec rubocop modules/meeting/app/services/recurring_meetings/update_service.rb modules/meeting/spec/services/recurring_meetings/update_service_integration_spec.rb`

```bash
git add modules/meeting/app/services/recurring_meetings/update_service.rb modules/meeting/spec/services/recurring_meetings/update_service_integration_spec.rb
git commit -m "Bump lock_version/updated_at when syncing occurrence titles (ICS visibility)"
```

---

### Task 8: Full-suite check and PR

- [ ] **Step 1: Run the full meeting module spec suite**

Run: `bundle exec rspec modules/meeting/spec`
Expected: all PASS. Investigate and fix any failures before proceeding — do not skip or comment out failing examples.

- [ ] **Step 2: Run rubocop across all touched files**

Run: `bundle exec rubocop modules/meeting/app/services/meetings/icalendar_builder.rb modules/meeting/app/services/recurring_meetings/update_service.rb modules/meeting/db/migrate/20260814100000_add_lock_version_to_recurring_meetings.rb modules/meeting/spec/models/recurring_meeting_spec.rb modules/meeting/spec/services/meetings/icalendar_builder_spec.rb modules/meeting/spec/services/all_meetings/ical_service_spec.rb modules/meeting/spec/services/recurring_meetings/update_service_integration_spec.rb`
Expected: no offenses.

- [ ] **Step 3: Push and open the PR**

```bash
git push -u origin <branch-name>
gh pr create --base epic --title "Fix meeting calendar subscription feed defects (R10)" --body "$(cat <<'EOF'
## Summary
- Fixes three reported calendar-subscription-feed defects (docs/superpowers/specs/2026-08-14-meeting-batch2-calendar-timezone-scope-design.md, Part 1): stale SEQUENCE on schedule-only series edits, ended series still projecting future occurrences, and a 6-hour refresh interval.
- Adds recurring_meetings.lock_version so the series master's SEQUENCE can reflect schedule-only changes, not just template edits.
- Adds IcalendarBuilder#add_ended_series_history: renders an ended series' past occurrences as standalone VEVENTs plus a CANCELLED tombstone for the old series UID, self-guarded inside add_series_event so both the subscription feed and the email-attachment path get the fix.
- Fixes a related occurrence-level bug: bulk title-sync used update_column, which never bumped lock_version/updated_at, making the change invisible to subscribed calendar clients.

## Test plan
- [x] bundle exec rspec modules/meeting/spec
- [x] bundle exec rubocop on all touched files
EOF
)"
```

## Self-Review Notes (already applied above, kept for the executor's context)

- **Spec coverage:** §1a (Task 2), §1b (Task 5, Task 6), §1c (Task 3), §1d (Task 7) all have a task. R8/R9 need no task (already shipped, per spec). Parts 2/3 are explicitly out of scope for this plan.
- **No placeholders:** every step has literal code, not a description of code.
- **Type/name consistency:** `add_ended_series_history(recurring_meeting:)`, `add_series_tombstone(recurring_meeting:)`, and the extended `add_single_meeting_event(meeting:, cancelled:, timezone:)` signature are used identically across Tasks 4, 5, and 6.
