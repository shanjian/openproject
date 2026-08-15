# Meeting Batch-2 Part 2: Timezone Selection at Creation (R11) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make timezone a real, user-selectable field at meeting creation for both one-time and recurring meetings, instead of the current silent "hardcoded to `User.current.time_zone`" (one-time) / "hidden field set from creator's profile" (recurring) behavior — and wire the value through everywhere it currently gets silently dropped (strong params, contract, reschedule detection, ICS TZID).

**Architecture:** A new nullable `meetings.time_zone` string column mirrors the existing `recurring_meetings.time_zone` column. `Meeting#time_zone` gains the same "resolve-or-fall-back" shape `RecurringMeeting#time_zone` already has. A shared form (`Meeting::TimeGroup`) gets one new select field used by both meeting kinds. Everywhere the value already flows through the stack for `RecurringMeeting` (contract attribute, `reschedule_required?`, `SCHEDULE_ATTRS`) either already works or gets the one missing wire; everywhere it's new for `Meeting` (contract, strong params, ICS TZID) gets added fresh.

**Tech Stack:** Ruby 3.4.7 / Rails 8.0.3, RSpec (`type: :model`, `type: :rails_request`), `ActiveSupport::TimeZone`, Primer::Forms DSL (`select_list`), Stimulus (TypeScript).

**Spec:** `docs/superpowers/specs/2026-08-14-meeting-batch2-calendar-timezone-scope-design.md` (Part 2 — R11, lines 282–391). Kickoff/orientation note: `docs/superpowers/2026-08-15-r11-timezone-session-kickoff.md`.

## Scope note — two additions beyond the kickoff's literal file list

The kickoff's "files this session touches" list is a *starting* list, not exhaustive — while tracing how a submitted `time_zone` actually reaches the database, this plan found two more spots that silently defeat the feature if left alone. Both are firmly inside R11's territory (neither is `RecurringMeetings::UpdateService`/`EndService`/`EndSeriesContract`/`engine.rb`, which stay off-limits per the kickoff), so they're folded in here rather than deferred:

1. **`RecurringMeetings::SetAttributesService#set_default_attributes`** (`modules/meeting/app/services/recurring_meetings/set_attributes_service.rb:36`) unconditionally does `model.time_zone = user.time_zone.name`, and `BaseServices::SetAttributes#set_attributes` runs `model.attributes = params` (which would apply a submitted `time_zone`) *before* calling this — so today's flow would silently overwrite any explicit selection on every create. Task 4 fixes this.
2. **`MeetingsController#fetch_timezone`** (the turbo-stream endpoint that live-updates the DST-abbreviation caption under the start-time field as the user edits date/time) hardcodes `User.current.time_zone` and only accepts `start_date`/`start_time_hour`. Once the zone is user-selectable, this caption must reflect the *selected* zone, not always the viewer's own profile zone, or picking a non-default zone will show a caption for the wrong zone. Task 6 fixes this (controller + the `meetings--form` Stimulus controller that calls it).

## Global Constraints

- One PR for this plan (Part 2 only); branch off the current tip of `epic` (already includes Part 1's merge, PR #127). Rebase onto `epic` again right before opening the PR — Part 3 (R12) is landing concurrently in a separate session.
- Do not touch `RecurringMeetings::UpdateService`, `RecurringMeetings::EndService`/`EndSeriesContract`, any close-dialog component/route, or `engine.rb` permissions — that's Part 3's territory. If a task here seems to require it, stop and reconsider (see kickoff note).
- In `modules/meeting/app/models/recurring_meeting.rb`, touch only `reschedule_required?` and the new validation — nothing else in that file.
- Both `Meeting#time_zone` and `RecurringMeeting#time_zone` are reader overrides returning an `ActiveSupport::TimeZone` (or delegating to one), never the raw string — validate the raw column (`self[:time_zone]` / `read_attribute(:time_zone)`), never `validates ... inclusion:` against the reader's return value.
- Any test fixture using date arithmetic must be sanity-checked against "what happens if this suite runs a year from now," not just today (Part 1 found three date-drift bugs, one a silent `advance(week: 52)` typo).
- Re-read each file's actual current content before editing — line numbers below were accurate as of this plan's writing but the codebase moves.
- Run `bundle exec rubocop <changed files>` and `bundle exec rspec <changed specs>` before each commit.
- **Do not widen `Meeting`'s update-mail gate** (`after_update :send_updated_mail, if: -> { saved_change_to_start_time? || saved_change_to_duration? || saved_change_to_location? || saved_change_to_title? }`, `meeting.rb:131-133`) to include `saved_change_to_time_zone?`. This is a deliberate spec decision, not an oversight: a one-off meeting has no future occurrences depending on its zone, so a zone-only edit stays silent, matching how other non-triggering fields (e.g. `notify`) already behave. (The analogous recurring-series case is different and *is* wired up — see Task 2.)

---

### Task 1: `meetings.time_zone` migration + `Meeting` model zone resolution and validation

**Files:**
- Create: `modules/meeting/db/migrate/20260815120000_add_time_zone_to_meetings.rb`
- Modify: `modules/meeting/app/models/meeting.rb:223-227` (the `time_zone` reader), and add a new `validate`
- Test: `modules/meeting/spec/models/meeting_spec.rb`

**Interfaces:**
- Produces: `Meeting#time_zone` → `ActiveSupport::TimeZone` (series meetings delegate to `recurring_meeting.time_zone`; standalone meetings resolve the stored column via `ActiveSupport::TimeZone[...]`, falling back to `User.current.time_zone` when the column is `NULL`). Consumed by `Meeting::VirtualStartTime#parsed_start_time` (unchanged call site, already keys off `time_zone`), by Task 5 (ICS `timezone:` argument), and by Task 6 (form default/caption).

- [ ] **Step 1: Write the migration**

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

class AddTimeZoneToMeetings < ActiveRecord::Migration[8.0]
  def change
    add_column :meetings, :time_zone, :string, null: true
  end
end
```

Run: `bundle exec rails db:migrate` and confirm it applies cleanly.

- [ ] **Step 2: Write the failing model specs**

Add to `modules/meeting/spec/models/meeting_spec.rb` (inside the top-level `RSpec.describe Meeting do ... end`):

```ruby
  describe "#time_zone" do
    shared_let(:zone_user) { create(:user, preferences: { time_zone: "Asia/Tokyo" }) }

    context "when the meeting is a standalone (non-recurring) meeting" do
      context "with an explicit time_zone column value" do
        let(:meeting) { build(:meeting, project:, time_zone: "Europe/Berlin") }

        it "resolves the stored column" do
          expect(meeting.time_zone).to eq(ActiveSupport::TimeZone["Europe/Berlin"])
        end
      end

      context "with no time_zone column value" do
        let(:meeting) { build(:meeting, project:, time_zone: nil, author: zone_user) }

        it "falls back to the current user's time zone" do
          User.execute_as(zone_user) do
            expect(meeting.time_zone).to eq(ActiveSupport::TimeZone["Asia/Tokyo"])
          end
        end
      end

      context "with an invalid raw time_zone string" do
        let(:meeting) { build(:meeting, project:, time_zone: "Not/AZone") }

        it "is invalid" do
          expect(meeting).not_to be_valid
          expect(meeting.errors[:time_zone]).to be_present
        end
      end
    end

    context "when the meeting is a series occurrence or template" do
      let(:recurring_meeting) { create(:recurring_meeting, project:, time_zone: "Australia/Sydney") }
      let(:meeting) { recurring_meeting.template }

      it "delegates to the recurring meeting's time zone, ignoring its own column" do
        meeting.time_zone = "Europe/Berlin" # should never win
        expect(meeting.time_zone).to eq(ActiveSupport::TimeZone["Australia/Sydney"])
      end
    end

    context "parsing start_date/start_time_hour in a non-UTC zone across a DST boundary" do
      let(:meeting) do
        build(:meeting, project:, time_zone: "America/New_York",
                        start_date: "2025-03-09", start_time_hour: "01:30")
      end

      it "interprets the entered local time in the selected zone, not UTC" do
        # 2025-03-09 02:00 America/New_York is the spring-forward DST gap; 01:30 is
        # the last valid local time before it, still EST (UTC-5).
        expect(meeting.start_time).to eq(Time.utc(2025, 3, 9, 6, 30))
      end
    end
  end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bundle exec rspec modules/meeting/spec/models/meeting_spec.rb -e "#time_zone"`
Expected: FAIL — `time_zone` doesn't accept a `time_zone:` factory/build attribute error, or resolves incorrectly, or no validation exists yet.

- [ ] **Step 4: Implement the reader and validation**

Replace lines 223-227 of `modules/meeting/app/models/meeting.rb`:

```ruby
  # One-time meeting time zone. Series meetings (template or occurrence) never
  # carry a private zone — the series' own column always wins. Otherwise the
  # stored column, falling back to the current user's zone when unset.
  def time_zone
    if recurring?
      recurring_meeting.time_zone
    elsif self[:time_zone].present?
      ActiveSupport::TimeZone[self[:time_zone]]
    else
      User.current.time_zone
    end
  end
```

Add a validation near the other `validates`/`validate` calls (around line 127, after the `duration` validation):

```ruby
  validate :time_zone_resolves

  ...

  private

  def time_zone_resolves
    return if self[:time_zone].blank?

    errors.add(:time_zone, :invalid) if ActiveSupport::TimeZone[self[:time_zone]].nil?
  end
```

(Add `time_zone_resolves` to the existing `private` section rather than creating a second one.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bundle exec rspec modules/meeting/spec/models/meeting_spec.rb`
Expected: PASS, including all pre-existing examples in the file (no regressions).

- [ ] **Step 6: Rubocop and commit**

Run: `bundle exec rubocop modules/meeting/app/models/meeting.rb`

```bash
git add modules/meeting/db/migrate/20260815120000_add_time_zone_to_meetings.rb \
        modules/meeting/app/models/meeting.rb \
        modules/meeting/spec/models/meeting_spec.rb
git commit -m "Add meetings.time_zone column and zone-resolution/validation to Meeting"
```

---

### Task 2: `RecurringMeeting#reschedule_required?` + zone-string validation

**Files:**
- Modify: `modules/meeting/app/models/recurring_meeting.rb:294-299` (`reschedule_required?`), and add a new `validate` near the existing validations (around line 49-72)
- Test: `modules/meeting/spec/models/recurring_meeting_spec.rb`

**Interfaces:**
- Produces: `RecurringMeeting#reschedule_required?(previous: false)` now includes `"time_zone"` in its tracked-attribute list — consumed by `RecurringMeetings::UpdateService#should_reschedule?` (existing call site, untouched) and `RecurringMeetings::UpdateContract` (existing call site, untouched).

- [ ] **Step 1: Write the failing tests**

Add to `modules/meeting/spec/models/recurring_meeting_spec.rb` (create the file with a minimal `RSpec.describe RecurringMeeting do ... end` wrapper first if it doesn't already exist — check with `test -f modules/meeting/spec/models/recurring_meeting_spec.rb`):

```ruby
  describe "#reschedule_required?" do
    let(:recurring_meeting) { create(:recurring_meeting, project: create(:project), time_zone: "UTC") }

    it "is true when only time_zone changed" do
      recurring_meeting.time_zone = "Europe/Berlin"
      expect(recurring_meeting.reschedule_required?).to be true
    end

    it "is true when only time_zone changed, checking previous_changes after save" do
      recurring_meeting.update!(time_zone: "Europe/Berlin")
      expect(recurring_meeting.reschedule_required?(previous: true)).to be true
    end
  end

  describe "#time_zone validation" do
    it "rejects a raw zone string that does not resolve" do
      recurring_meeting = build(:recurring_meeting, project: create(:project), time_zone: "Not/AZone")
      expect(recurring_meeting).not_to be_valid
      expect(recurring_meeting.errors[:time_zone]).to be_present
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec modules/meeting/spec/models/recurring_meeting_spec.rb`
Expected: FAIL — `reschedule_required?` returns `false` for a zone-only change; no zone-format validation exists yet (the invalid-string example may currently pass or fail for the wrong reason — check the failure message).

- [ ] **Step 3: Implement the `reschedule_required?` fix**

In `modules/meeting/app/models/recurring_meeting.rb`, change:

```ruby
  def reschedule_required?(previous: false)
    (previous ? previous_changes : changes)
      .keys
      .intersect?(%w[frequency start_date start_time start_time_hour iterations interval end_after end_date location
                     weekdays schedule_mode month_day week_ordinal weekday])
  end
```

to:

```ruby
  def reschedule_required?(previous: false)
    (previous ? previous_changes : changes)
      .keys
      .intersect?(%w[frequency start_date start_time start_time_hour iterations interval end_after end_date location
                     weekdays schedule_mode month_day week_ordinal weekday time_zone])
  end
```

- [ ] **Step 4: Add the zone-string validation**

Near the existing `validates`/`validate` block (after the `weekday` inclusion validation, around line 72), add:

```ruby
  validate :time_zone_resolves
```

And in the `private` section (alongside `end_date_constraints`/`weekdays_constraints`):

```ruby
  def time_zone_resolves
    return if self[:time_zone].blank?

    errors.add(:time_zone, :invalid) if ActiveSupport::TimeZone[self[:time_zone]].nil?
  end
```

Note: `validates :time_zone, presence: true` already exists at line 49 and validates the *overridden reader* (never blank, since it falls back to `User.current.time_zone`) — that pre-existing behavior is untouched by this task. The new `time_zone_resolves` validation is the first check that ever inspects the raw column.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bundle exec rspec modules/meeting/spec/models/recurring_meeting_spec.rb`
Expected: PASS.

- [ ] **Step 6: Regression-test the service-level consequence (should_reschedule?)**

Add to `modules/meeting/spec/services/recurring_meetings/update_service_integration_spec.rb` (append inside its existing top-level describe block, following the file's existing `context`/`it` style around the other `reschedule`/`does not reschedule` examples):

```ruby
  context "when only the series time_zone changes" do
    let(:recurring_meeting) do
      create(:recurring_meeting, project:, author: user, time_zone: "UTC",
                                 start_time: 1.week.from_now.change(hour: 10))
    end

    it "reschedules (enqueues the update mail) but leaves occurrence start times unchanged" do
      original_occurrence_times = recurring_meeting.scheduled_occurrences(limit: 3).to_a

      expect do
        RecurringMeetings::UpdateService
          .new(model: recurring_meeting, user:)
          .call(time_zone: "Europe/Berlin")
      end.to have_enqueued_job(RecurringMeetings::SendUpdatedNotificationJob)

      recurring_meeting.reload
      expect(recurring_meeting.time_zone).to eq(ActiveSupport::TimeZone["Europe/Berlin"])
      expect(recurring_meeting.scheduled_occurrences(limit: 3).to_a).to eq(original_occurrence_times)
    end
  end
```

Before writing this, read the actual current top of `update_service_integration_spec.rb` to match its existing `let(:user)`/`let(:project)` names exactly (they are not repeated here to avoid duplicating a stale guess) — reuse whatever the file already defines rather than redefining `project`/`user`.

- [ ] **Step 7: Run it**

Run: `bundle exec rspec modules/meeting/spec/services/recurring_meetings/update_service_integration_spec.rb`
Expected: PASS.

- [ ] **Step 8: Rubocop and commit**

Run: `bundle exec rubocop modules/meeting/app/models/recurring_meeting.rb`

```bash
git add modules/meeting/app/models/recurring_meeting.rb \
        modules/meeting/spec/models/recurring_meeting_spec.rb \
        modules/meeting/spec/services/recurring_meetings/update_service_integration_spec.rb
git commit -m "Track time_zone in RecurringMeeting#reschedule_required? and validate the raw zone string"
```

---

### Task 3: Fix `RecurringMeetings::SetAttributesService` clobbering the submitted zone on create

**Files:**
- Modify: `modules/meeting/app/services/recurring_meetings/set_attributes_service.rb`
- Test: `modules/meeting/spec/services/recurring_meetings/set_attributes_service_spec.rb`

**Interfaces:**
- Consumes: `RecurringMeeting#[]` (raw attribute read, bypassing the overridden `time_zone` reader).
- Produces: `RecurringMeetings::SetAttributesService#set_default_attributes` only defaults `time_zone` when the record has none yet — an explicitly-submitted value from Task 6's form survives.

- [ ] **Step 1: Write the failing test**

Read the current top of `modules/meeting/spec/services/recurring_meetings/set_attributes_service_spec.rb` first to match its existing `let`/`described_class.new(...)` call shape, then add:

```ruby
  describe "#set_default_attributes" do
    context "when the params already include an explicit time_zone" do
      it "keeps the submitted zone instead of overwriting it with the user's profile zone" do
        result = described_class
          .new(user:, model: RecurringMeeting.new, contract_class: RecurringMeetings::CreateContract)
          .call(title: "Zoned series", project:, time_zone: "Asia/Tokyo", start_time: 1.day.from_now,
                frequency: "weekly", end_after: "never")

        expect(result.result[:time_zone]).to eq("Asia/Tokyo")
      end
    end

    context "when the params do not include a time_zone" do
      it "still defaults to the user's profile zone" do
        result = described_class
          .new(user:, model: RecurringMeeting.new, contract_class: RecurringMeetings::CreateContract)
          .call(title: "Unzoned series", project:, start_time: 1.day.from_now,
                frequency: "weekly", end_after: "never")

        expect(result.result[:time_zone]).to eq(user.time_zone.name)
      end
    end
  end
```

Adjust the exact `described_class.new(...)` keyword shape (`user:`, `model:`, `contract_class:`, or whatever the file's existing examples already use) to match the file's established convention rather than the shape shown here if they differ — check first.

- [ ] **Step 2: Run the test to verify the first case fails**

Run: `bundle exec rspec modules/meeting/spec/services/recurring_meetings/set_attributes_service_spec.rb`
Expected: FAIL on "keeps the submitted zone" — `result.result[:time_zone]` is the user's own zone, not `"Asia/Tokyo"`, because `set_default_attributes` overwrites it unconditionally.

- [ ] **Step 3: Fix `set_default_attributes`**

In `modules/meeting/app/services/recurring_meetings/set_attributes_service.rb`, the file has one `set_attributes` override (which calls `set_default_attributes(params) if model.new_record?`, inherited from `BaseServices::SetAttributes`) and one `set_default_attributes` method:

```ruby
    def set_default_attributes(_params)
      model.change_by_system do
        model.time_zone = user.time_zone.name
        model.author = user
        model.duration ||= 1
      end
    end
```

Change it to:

```ruby
    def set_default_attributes(_params)
      model.change_by_system do
        model.time_zone = user.time_zone.name if model[:time_zone].blank?
        model.author = user
        model.duration ||= 1
      end
    end
```

The key change is `model.time_zone = user.time_zone.name` → `model.time_zone = user.time_zone.name if model[:time_zone].blank?`. `model[:time_zone]` reads the raw column (bypassing the overridden reader, which is never blank since it falls back to `user.time_zone` itself) — this is the same raw-read pattern used in Task 1/2's validations.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec modules/meeting/spec/services/recurring_meetings/set_attributes_service_spec.rb`
Expected: PASS, including all pre-existing examples in the file.

- [ ] **Step 5: Rubocop and commit**

Run: `bundle exec rubocop modules/meeting/app/services/recurring_meetings/set_attributes_service.rb`

```bash
git add modules/meeting/app/services/recurring_meetings/set_attributes_service.rb \
        modules/meeting/spec/services/recurring_meetings/set_attributes_service_spec.rb
git commit -m "Don't overwrite an explicitly submitted recurring-meeting time_zone with the creator's profile zone"
```

---

### Task 4: Controller strong params + contract attribute (persistence plumbing)

**Files:**
- Modify: `modules/meeting/app/controllers/meetings_controller.rb:576-584` (`meeting_params`)
- Modify: `modules/meeting/app/controllers/recurring_meetings_controller.rb:363-369` (`recurring_meeting_params`)
- Modify: `modules/meeting/app/contracts/meetings/base_contract.rb`
- Test: Create `modules/meeting/spec/requests/meetings_time_zone_spec.rb`
- Test: Create `modules/meeting/spec/requests/recurring_meetings/recurring_meetings_time_zone_spec.rb`

**Interfaces:**
- Produces: submitting `meeting[time_zone]` on create/update for either meeting kind now reaches the model and persists — closes the gap Task 6's form depends on.

- [ ] **Step 1: Write the failing request specs**

Create `modules/meeting/spec/requests/meetings_time_zone_spec.rb`:

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

RSpec.describe "Meeting time_zone param",
               :skip_csrf,
               type: :rails_request do
  shared_let(:project) { create(:project, enabled_module_names: %i[meetings]) }
  shared_let(:user) do
    create(:user, member_with_permissions: { project => %i[view_meetings create_meetings edit_meetings] })
  end

  before { login_as user }

  describe "create" do
    it "persists an explicitly submitted time_zone (regression: meeting_params didn't permit it)" do
      post meetings_path(project),
           params: {
             project_id: project.id,
             meeting: {
               title: "Zoned meeting", project_id: project.id,
               start_date: Date.tomorrow.iso8601, start_time_hour: "09:00", duration: "1",
               time_zone: "Asia/Tokyo"
             }
           }

      meeting = Meeting.find_by(title: "Zoned meeting")
      expect(meeting).to be_present
      expect(meeting[:time_zone]).to eq("Asia/Tokyo")
    end
  end

  describe "update" do
    shared_let(:legacy_meeting) { create(:meeting, project:, author: user, time_zone: nil) }

    it "leaves a legacy NULL time_zone unchanged on an unrelated update" do
      patch meeting_path(legacy_meeting), params: { meeting: { title: "Renamed" } }

      expect(legacy_meeting.reload[:time_zone]).to be_nil
      expect(legacy_meeting.title).to eq("Renamed")
    end
  end
end
```

Check the actual current `MeetingsController#update` action and route/param shape before finalizing this file — the `patch meeting_path(...)` call and whether `update` accepts a bare `meeting: { title: }` (vs. requiring other fields) should be verified against the controller's current `update`/`update_details` actions, not assumed.

Create `modules/meeting/spec/requests/recurring_meetings/recurring_meetings_time_zone_spec.rb`:

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

RSpec.describe "Recurring meeting time_zone param",
               :skip_csrf,
               type: :rails_request do
  shared_let(:project) { create(:project, enabled_module_names: %i[meetings]) }
  shared_let(:user) do
    create(:user, member_with_permissions: { project => %i[view_meetings create_meetings] })
  end

  before { login_as user }

  it "persists an explicitly submitted time_zone (regression: recurring_meeting_params didn't permit it)" do
    post recurring_meetings_path,
         params: {
           project_id: project.id,
           meeting: {
             title: "Zoned series", project_id: project.id,
             start_date: Date.tomorrow.iso8601, start_time_hour: "09:00", duration: "1",
             frequency: "weekly", interval: "1", end_after: "never",
             time_zone: "Asia/Tokyo"
           }
         }

    series = RecurringMeeting.find_by(title: "Zoned series")
    expect(series).to be_present
    expect(series[:time_zone]).to eq("Asia/Tokyo")
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec modules/meeting/spec/requests/meetings_time_zone_spec.rb modules/meeting/spec/requests/recurring_meetings/recurring_meetings_time_zone_spec.rb`
Expected: FAIL on both "persists" examples — `time_zone` is silently dropped by strong params today.

- [ ] **Step 3: Permit `time_zone` in `MeetingsController#meeting_params`**

Change:

```ruby
  def meeting_params
    if params[:meeting].present?
      params
        .require(:meeting) # rubocop:disable Rails/StrongParametersExpect
        .permit(:title, :location, :start_time, :project_id,
                :duration, :start_date, :start_time_hour, :notify,
                participants_attributes: %i[email name invited attended user user_id meeting id])
    end
  end
```

to:

```ruby
  def meeting_params
    if params[:meeting].present?
      params
        .require(:meeting) # rubocop:disable Rails/StrongParametersExpect
        .permit(:title, :location, :start_time, :project_id,
                :duration, :start_date, :start_time_hour, :notify, :time_zone,
                participants_attributes: %i[email name invited attended user user_id meeting id])
    end
  end
```

- [ ] **Step 4: Permit `time_zone` in `RecurringMeetingsController#recurring_meeting_params`**

Change:

```ruby
  def recurring_meeting_params
    params
      .expect(meeting: [:project_id, :title, :location, :start_time_hour, :duration, :start_date,
                        :interval, :frequency, :end_after, :end_date, :iterations, :notify,
                        :preset, :schedule_mode_option, :schedule_mode, :month_day, :week_ordinal, :weekday,
                        { weekdays: [] }])
  end
```

to:

```ruby
  def recurring_meeting_params
    params
      .expect(meeting: [:project_id, :title, :location, :start_time_hour, :duration, :start_date,
                        :interval, :frequency, :end_after, :end_date, :iterations, :notify, :time_zone,
                        :preset, :schedule_mode_option, :schedule_mode, :month_day, :week_ordinal, :weekday,
                        { weekdays: [] }])
  end
```

- [ ] **Step 5: Add the contract attribute**

In `modules/meeting/app/contracts/meetings/base_contract.rb`, add `attribute :time_zone` alongside the other simple attributes (after `attribute :notify`):

```ruby
    attribute :notify
    attribute :time_zone
```

(`RecurringMeetings::BaseContract` already declares `attribute :time_zone` — no change needed there.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bundle exec rspec modules/meeting/spec/requests/meetings_time_zone_spec.rb modules/meeting/spec/requests/recurring_meetings/recurring_meetings_time_zone_spec.rb`
Expected: PASS.

- [ ] **Step 7: Rubocop and commit**

Run: `bundle exec rubocop modules/meeting/app/controllers/meetings_controller.rb modules/meeting/app/controllers/recurring_meetings_controller.rb modules/meeting/app/contracts/meetings/base_contract.rb`

```bash
git add modules/meeting/app/controllers/meetings_controller.rb \
        modules/meeting/app/controllers/recurring_meetings_controller.rb \
        modules/meeting/app/contracts/meetings/base_contract.rb \
        modules/meeting/spec/requests/meetings_time_zone_spec.rb \
        modules/meeting/spec/requests/recurring_meetings/recurring_meetings_time_zone_spec.rb
git commit -m "Permit and accept time_zone through meeting and recurring-meeting params/contracts"
```

---

### Task 5: ICS output uses the meeting's own zone, not the viewer's

**Files:**
- Modify: `modules/meeting/app/services/meetings/ical_service.rb:44`
- Modify: `modules/meeting/app/services/all_meetings/ical_service.rb:45`
- Test: `modules/meeting/spec/services/meetings/ical_service_spec.rb`
- Test: `modules/meeting/spec/services/all_meetings/ical_service_spec.rb`

**Interfaces:**
- Consumes: `Meeting#time_zone` (Task 1), `Meetings::IcalendarBuilder#add_single_meeting_event(meeting:, cancelled:, timezone:)` — the `timezone:` keyword already exists (added in Part 1) and is already unit-tested at the builder level (`icalendar_builder_spec.rb`, "when an explicit timezone is passed"); this task only fixes the two call sites that don't pass it yet.

- [ ] **Step 1: Establish the pre-change baseline**

Run: `bundle exec rspec modules/meeting/spec/services/meetings/ical_service_spec.rb modules/meeting/spec/services/all_meetings/ical_service_spec.rb`
Expected: PASS (this is the current, pre-fix behavior — both specs currently assert TZID = the *viewing/generating user's* zone, e.g. literal `"Europe/Berlin"` / `.in_time_zone("Europe/Berlin")` on a meeting authored by a `America/New_York`-preference user). Confirm this passes before touching anything, so any new failure after Step 3 is attributable to this change and not a pre-existing issue.

- [ ] **Step 2: Write the new ICS regression spec**

Add to `modules/meeting/spec/services/meetings/ical_service_spec.rb` (inside the existing `RSpec.describe Meetings::ICalService ... do` block):

```ruby
  context "when the meeting has its own time_zone, different from the viewing user's" do
    let(:zoned_meeting) do
      create(:meeting,
             author: user,
             project:,
             title: "Zoned meeting",
             time_zone: "Asia/Tokyo",
             start_time: Time.zone.parse("2025-08-30T10:00:00Z"))
    end
    let(:zoned_service) { described_class.new(user:, meeting: zoned_meeting) }
    let(:zoned_result) { zoned_service.call.result }
    let(:zoned_entry) { Icalendar::Event.parse(zoned_result).first }

    it "renders TZID as the meeting's own zone, not the viewing user's America/New_York" do
      expect(zoned_entry.dtstart.ical_params["tzid"]).to eq(["Asia/Tokyo"])
    end
  end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bundle exec rspec modules/meeting/spec/services/meetings/ical_service_spec.rb -e "renders TZID as the meeting's own zone"`
Expected: FAIL — TZID is currently the builder's/viewing-user's zone, not `"Asia/Tokyo"`.

- [ ] **Step 4: Fix the `Meetings::ICalService` call site**

In `modules/meeting/app/services/meetings/ical_service.rb`, change:

```ruby
        calendar.add_single_meeting_event(meeting:, cancelled:)
```

to:

```ruby
        calendar.add_single_meeting_event(meeting:, cancelled:, timezone: meeting.time_zone)
```

- [ ] **Step 5: Fix the `AllMeetings::ICalService` call site**

In `modules/meeting/app/services/all_meetings/ical_service.rb`, change:

```ruby
        single_meetings.each do |meeting|
          calendar.add_single_meeting_event(meeting:, cancelled: false)
        end
```

to:

```ruby
        single_meetings.each do |meeting|
          calendar.add_single_meeting_event(meeting:, cancelled: false, timezone: meeting.time_zone)
        end
```

- [ ] **Step 6: Run the new test to verify it passes**

Run: `bundle exec rspec modules/meeting/spec/services/meetings/ical_service_spec.rb -e "renders TZID as the meeting's own zone"`
Expected: PASS.

- [ ] **Step 7: Re-run the full baseline and fix the now-stale pre-existing assertions**

Run: `bundle exec rspec modules/meeting/spec/services/meetings/ical_service_spec.rb modules/meeting/spec/services/all_meetings/ical_service_spec.rb`

This is expected to now show new failures: both spec files have a pre-existing meeting authored by a `preferences: { time_zone: "America/New_York" }` user, with no `time_zone` column set on the meeting. Before this task, the builder rendered such a meeting in the *viewer's* default/builder zone (asserted in the specs as literal `"Europe/Berlin"`). After this task, `meeting.time_zone` (NULL column) falls back to `User.current.time_zone`, which — inside each service's `User.execute_as(user) { ... }` block — is that same author/user, i.e. `"America/New_York"`. This is the correct new behavior (Task 1's fallback), not a bug, but it makes the old literal assertions wrong.

For each failing example the runner reports:
- If it asserts `.in_time_zone("Europe/Berlin")` or `ical_params["tzid"]).to eq(["Europe/Berlin"])` against one of these NULL-zone, `America/New_York`-authored meetings, change the literal to `.in_time_zone("America/New_York")` / `["America/New_York"]`.
- If it asserts DST-transition instants derived from that zone (e.g. in `modules/meeting/spec/services/meetings/ical_service_spec.rb`'s "renders the ICS file" example, the `standard`/`daylight`/`real_standard`/`real_daylight` block), do not hand-derive the new US-Eastern transition instants by guesswork — run the spec, read the actual failure diff (RSpec prints both `expected` and `got` for a `to eq` failure), and set the literal to the `got` value only after confirming from the diff that it is a real DST-transition timestamp for `America/New_York` (2020 fall-back / 2021 spring-forward) rather than some unrelated bug. If the diff looks like anything other than a clean zone swap, stop and treat it as a real regression, not a fixture to patch.
- Any assertion in `all_meetings/ical_service_spec.rb`'s "recurring meetings" contexts (the ones already using `time_zone: user.time_zone` / `.in_time_zone(user.time_zone)`) should be unaffected — those meetings already carry an explicit zone via the `recurring_meeting` factory, so this task changes nothing for them; if the runner shows failures there, investigate before assuming they're expected.

- [ ] **Step 8: Run the full pair again to confirm everything is green**

Run: `bundle exec rspec modules/meeting/spec/services/meetings/ical_service_spec.rb modules/meeting/spec/services/all_meetings/ical_service_spec.rb`
Expected: PASS, all examples.

- [ ] **Step 9: Rubocop and commit**

Run: `bundle exec rubocop modules/meeting/app/services/meetings/ical_service.rb modules/meeting/app/services/all_meetings/ical_service.rb`

```bash
git add modules/meeting/app/services/meetings/ical_service.rb \
        modules/meeting/app/services/all_meetings/ical_service.rb \
        modules/meeting/spec/services/meetings/ical_service_spec.rb \
        modules/meeting/spec/services/all_meetings/ical_service_spec.rb
git commit -m "Render one-off meeting ICS events in the meeting's own zone, not the viewer's"
```

---

### Task 6: Timezone select in `Meeting::TimeGroup` (form) + live DST-caption fix

**Files:**
- Modify: `modules/meeting/app/forms/meeting/time_group.rb`
- Modify: `modules/meeting/app/controllers/meetings_controller.rb` (`fetch_timezone` action + `timezone_params`, around lines 364-377 and 670-672)
- Modify: `frontend/src/stimulus/controllers/dynamic/meetings/form.controller.ts`
- Test: Create `modules/meeting/spec/requests/meetings_time_zone_field_spec.rb` (renders the select; see note on Capybara/feature vs. request testing below)

**Interfaces:**
- Consumes: `UserPreferences::UpdateContract.assignable_time_zones` (existing class method — same one `My::TimeZoneForm` already uses for the profile-settings zone select) for the option list; `Redmine::I18n#friendly_timezone_name` (existing) for the caption.
- Produces: a `time_zone` select field submitted as `meeting[time_zone]`, consumed by Task 4's now-permitted params.

- [ ] **Step 1: Read the current file fresh**

Re-read `modules/meeting/app/forms/meeting/time_group.rb` in full before editing — this plan's line numbers (30-127) were accurate as of research time but may have drifted.

- [ ] **Step 2: Replace the hidden-field arrangement with a real select**

Change the `form do |meeting_form|` block's zone-related section from:

```ruby
  form do |meeting_form|
    if editing_recurring? && friendly_timezone_name(User.current.time_zone) != friendly_timezone_name(@meeting.time_zone)
      meeting_form.html_content do
        render(
          Primer::Alpha::Banner.new(
            description: I18n.t("recurring_meeting.time_zone_difference_banner.description",
                                actual_zone: friendly_timezone_name(@meeting.time_zone),
                                user_zone: friendly_timezone_name(User.current.time_zone)),
            scheme: :warning
          )
        ) { I18n.t("recurring_meeting.time_zone_difference_banner.title") }
      end

      meeting_form.hidden(
        name: :time_zone,
        value: @meeting.time_zone.name
      )
    end

    meeting_form.group(layout: :horizontal) do |group|
      group.text_field(
        name: :start_date,
        ...
      )

      group.text_field(
        name: :start_time_hour,
        ...
        caption: timezone_caption,
        data: {
          action: "input->recurring-meetings--form#updateFrequencyText \
                   input->meetings--form#updateTimezoneText"
        }
      )

      group.text_field(
        name: :duration,
        ...
      )
    end
  end
```

to:

```ruby
  form do |meeting_form|
    if editing_recurring? && friendly_timezone_name(User.current.time_zone) != friendly_timezone_name(@meeting.time_zone)
      meeting_form.html_content do
        render(
          Primer::Alpha::Banner.new(
            description: I18n.t("recurring_meeting.time_zone_difference_banner.description",
                                actual_zone: friendly_timezone_name(@meeting.time_zone),
                                user_zone: friendly_timezone_name(User.current.time_zone)),
            scheme: :warning
          )
        ) { I18n.t("recurring_meeting.time_zone_difference_banner.title") }
      end
    end

    meeting_form.group(layout: :horizontal) do |group|
      group.text_field(
        name: :start_date,
        type: "date",
        value: @initial_date,
        placeholder: @meeting.class.human_attribute_name(:start_date),
        label: @meeting.class.human_attribute_name(:start_date),
        required: true,
        autofocus: false,
        data: {
          action: "input->recurring-meetings--form#updateFrequencyText \
                   input->meetings--form#updateTimezoneText"
        }
      )

      group.text_field(
        name: :start_time_hour,
        type: "time",
        value: @initial_time,
        placeholder: Meeting.human_attribute_name(:start_time),
        label: Meeting.human_attribute_name(:start_time),
        required: true,
        caption: timezone_caption,
        data: {
          action: "input->recurring-meetings--form#updateFrequencyText \
                   input->meetings--form#updateTimezoneText"
        }
      )

      group.text_field(
        name: :duration,
        type: :text,
        value: @duration,
        placeholder: Meeting.human_attribute_name(:duration),
        label: Meeting.human_attribute_name(:duration),
        visually_hide_label: false,
        required: true,
        caption: I18n.t("text_in_hours"),
        data: {
          controller: "chronic-duration"
        }
      )
    end

    meeting_form.select_list(
      name: :time_zone,
      label: I18n.t(:label_time_zone),
      required: true,
      include_blank: false,
      input_width: :large,
      data: {
        action: "input->meetings--form#updateTimezoneText"
      }
    ) do |list|
      available_time_zones.each do |zone_label, value|
        list.option(label: zone_label, value:)
      end
    end
  end
```

- [ ] **Step 3: Add the option list and default-value logic**

In the `private` section, add (mirroring `My::TimeZoneForm`'s existing `assignable_time_zones`-based option list — do not duplicate `UserPreferences::UpdateContract`'s logic, call it):

```ruby
  def available_time_zones
    @available_time_zones ||= UserPreferences::UpdateContract
      .assignable_time_zones
      .group_by { it.tzinfo.canonical_zone }
      .map { |canonical_zone, included_zones| build_time_zone_entry(canonical_zone, included_zones) }
  end

  def build_time_zone_entry(canonical_zone, zones)
    zone_names = zones.map(&:name).join(", ")
    offset = ActiveSupport::TimeZone.seconds_to_utc_offset(canonical_zone.base_utc_offset)

    ["(UTC#{offset}) #{zone_names}", canonical_zone.identifier]
  end
```

- [ ] **Step 4: Wire the select's initial value in `initialize`**

The select's displayed/submitted value on first render comes from the underlying model attribute (`@meeting.time_zone`), the same way `start_date`/`start_time_hour` come from `@initial_date`/`@initial_time` — Primer's `select_list` reads the current value from the form's model via the `name:` unless a `value:` is given explicitly. Since `Meeting#time_zone`/`RecurringMeeting#time_zone` are reader overrides returning an `ActiveSupport::TimeZone`, but the select's `list.option` values are raw identifier strings (e.g. `"Europe/Berlin"`), an explicit `value:` matching that shape is needed on the `select_list` call added in Step 2:

```ruby
    meeting_form.select_list(
      name: :time_zone,
      label: I18n.t(:label_time_zone),
      value: @initial_time_zone,
      required: true,
      include_blank: false,
      input_width: :large,
      data: {
        action: "input->meetings--form#updateTimezoneText"
      }
    ) do |list|
```

And in `initialize`, alongside `@initial_time`/`@initial_date`:

```ruby
  def initialize(meeting:)
    super()

    @meeting = meeting
    @initial_time = meeting.start_time_hour.presence
    @initial_date = meeting.start_date.presence
    @initial_time_zone = initial_time_zone_value(meeting)

    duration = duration_value(meeting)
    @duration = duration.nil? ? "" : ChronicDuration.output(duration * 3600, format: :hours_only)
  end
```

```ruby
  def initial_time_zone_value(meeting)
    if meeting.persisted? || meeting.is_a?(RecurringMeeting) && meeting.template&.persisted?
      meeting.time_zone.name
    else
      # New record: default to the creator's profile zone; if they have none set,
      # show UTC explicitly in the select rather than applying it silently.
      User.current.time_zone.name
    end
  end
```

Note: `User.current.time_zone` already falls back to `"Etc/UTC"` when the user has no preference set (see `User#time_zone`, `app/models/user.rb:450-452`) — so "when unset, UTC is shown explicitly in the select" falls out of the existing default without extra code; a brand-new, non-persisted meeting's `time_zone` reader would otherwise also resolve to `User.current.time_zone` and give the same answer, but going through `User.current.time_zone` directly here (rather than `meeting.time_zone`) avoids depending on the new record having `author` set yet at form-render time.

- [ ] **Step 5: Fix the DST-abbreviation caption to reflect the selected zone**

`timezone_caption` (unchanged so far) and the `fetch_timezone` turbo-stream endpoint it depends on both currently hardcode `User.current.time_zone` — meaning if a user picks a non-default zone in the new select, the caption under the start-time field will show the wrong zone's DST abbreviation. Fix both ends:

In `modules/meeting/app/forms/meeting/time_group.rb`, `timezone_caption` stays as the *initial* render value (it already uses `@meeting.time_zone`/`User.current.time_zone` correctly for first paint); no change needed there.

In `modules/meeting/app/controllers/meetings_controller.rb`, change `timezone_params`:

```ruby
  def timezone_params
    @timezone_params ||= params.expect(meeting: %i[start_date start_time_hour]).compact_blank
  end
```

to:

```ruby
  def timezone_params
    @timezone_params ||= params.expect(meeting: %i[start_date start_time_hour time_zone]).compact_blank
  end
```

And change `fetch_timezone`:

```ruby
  def fetch_timezone
    return unless timezone_params.keys.count == 2

    User.execute_as(User.current) do
      meeting = Meeting.new(timezone_params)
      @text = friendly_timezone_name(User.current.time_zone, period: meeting.start_time)
    end

    add_caption_to_input_element_via_turbo_stream("input[name='meeting[start_time_hour]']",
                                                  caption: @text,
                                                  clean_other_captions: true)

    respond_with_turbo_streams
  end
```

to:

```ruby
  def fetch_timezone
    return unless timezone_params.keys.include?("start_date") && timezone_params.keys.include?("start_time_hour")

    User.execute_as(User.current) do
      meeting = Meeting.new(timezone_params.except(:time_zone))
      zone = timezone_params[:time_zone].presence&.then { |tz| ActiveSupport::TimeZone[tz] } || User.current.time_zone
      @text = friendly_timezone_name(zone, period: meeting.start_time)
    end

    add_caption_to_input_element_via_turbo_stream("input[name='meeting[start_time_hour]']",
                                                  caption: @text,
                                                  clean_other_captions: true)

    respond_with_turbo_streams
  end
```

(The old `return unless timezone_params.keys.count == 2` guard required exactly two keys; since `time_zone` is now an optional third key, switch the guard to explicitly check for the two always-required keys instead of an exact count.)

In `frontend/src/stimulus/controllers/dynamic/meetings/form.controller.ts`, change `updateTimezoneText`'s field list:

```ts
    ['start_date', 'start_time_hour'].forEach((name) => {
```

to:

```ts
    ['start_date', 'start_time_hour', 'time_zone'].forEach((name) => {
```

so the select's currently-chosen value rides along in the same turbo-stream request that already fires on `start_date`/`start_time_hour` input — and the `data: { action: "input->meetings--form#updateTimezoneText" }` added to the select in Step 2 makes changing the zone itself also trigger a refresh (a `select_list` fires a native `input`/`change` event on selection; confirm which event name Stimulus needs to bind to for this specific Primer component by checking how `recurring-meetings--form`'s own `select_list` fields (if any) wire their `data: { action: }`, and match that convention rather than assuming `input->` works identically for a select as for a text field).

- [ ] **Step 6: Manual verification (no automated frontend test in this plan)**

Run `bin/dev` (or the project's existing dev-server workflow) and manually verify in a browser:
- New one-time meeting form shows the zone select, defaulted to your profile zone (or UTC if unset).
- New recurring meeting form shows the same select.
- Editing an existing series with a different zone than yours still shows the warning banner, now alongside an editable (not hidden) select.
- Changing the zone select updates the DST-abbreviation caption under the start-time field without a full page reload.
- Submitting a non-default zone on create persists it (cross-check against Task 4's request specs, which already assert persistence — this step is about the *rendered form*, which those specs don't exercise since they post directly without rendering the page first).

- [ ] **Step 7: Add a request spec asserting the select renders with the right default and options**

Create `modules/meeting/spec/requests/meetings_time_zone_field_spec.rb`:

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

RSpec.describe "Meeting time_zone select field",
               :skip_csrf,
               type: :rails_request do
  shared_let(:project) { create(:project, enabled_module_names: %i[meetings]) }
  shared_let(:user) do
    create(:user,
           preferences: { time_zone: "Asia/Tokyo" },
           member_with_permissions: { project => %i[view_meetings create_meetings] })
  end

  before { login_as user }

  it "defaults the new-meeting time zone select to the creator's profile zone" do
    get new_meeting_path(project_id: project.id)

    expect(response.body).to include('name="meeting[time_zone]"')
    expect(response.body).to include("Asia/Tokyo")
  end
end
```

Check the actual route helper name for the "new one-time meeting" page (`new_meeting_path` is a guess based on the `resources :meetings, only: %i[... new ...]` route — confirm with `bundle exec rails routes | grep meeting` before finalizing) and adjust the request/params shape to match how the form is actually rendered (it may be a dialog/turbo-stream response rather than a plain HTML page — check `MeetingsController#new` before assuming a simple `get` renders the full form HTML in `response.body`).

- [ ] **Step 8: Run it**

Run: `bundle exec rspec modules/meeting/spec/requests/meetings_time_zone_field_spec.rb`
Expected: PASS.

- [ ] **Step 9: Rubocop, eslint, and commit**

Run: `bundle exec rubocop modules/meeting/app/forms/meeting/time_group.rb modules/meeting/app/controllers/meetings_controller.rb`
Run: `cd frontend && npx eslint src/stimulus/controllers/dynamic/meetings/form.controller.ts && cd ..`

```bash
git add modules/meeting/app/forms/meeting/time_group.rb \
        modules/meeting/app/controllers/meetings_controller.rb \
        frontend/src/stimulus/controllers/dynamic/meetings/form.controller.ts \
        modules/meeting/spec/requests/meetings_time_zone_field_spec.rb
git commit -m "Add a real timezone select to Meeting::TimeGroup and keep the DST caption in sync with it"
```

---

### Task 7: Whole-branch review and PR

- [ ] **Step 1: Rebase onto current `epic`**

Run: `git fetch origin && git rebase origin/epic`

Resolve any conflicts. Part 3 (R12) is landing concurrently in a different session — if rebase conflicts touch `RecurringMeetings::UpdateService`/`EndService`/`EndSeriesContract`/`engine.rb`, they are Part 3's changes; take their side unless this branch has an unrelated, legitimate reason to touch the same lines (it shouldn't, per the Global Constraints).

- [ ] **Step 2: Run the full meeting module test suite**

Run: `bundle exec rspec modules/meeting/spec`
Expected: PASS, no regressions anywhere in the module (not just the files this plan touched — Part 1's review found a pre-existing, unrelated bug this way).

- [ ] **Step 3: Run rubocop and eslint across all changed files**

Run: `bin/dirty-rubocop --uncommitted` (or `bundle exec rubocop` against the full changed-file list)
Run: `cd frontend && npx eslint src/ && cd ..`

- [ ] **Step 4: Request a whole-branch code review**

Use `superpowers:requesting-code-review` against the full diff vs. `epic`. Verify every finding against the actual code rather than accepting or dismissing on the reviewer's say-so alone (per the kickoff's Part-1 lesson) — independently re-derive anything that looks off before deciding whether to fix it.

- [ ] **Step 5: Finish the branch**

Use `superpowers:finishing-a-development-branch` — push and open a PR against `epic`, following the same process as Part 1 (PR #127).

- [ ] **Step 6: Update the `meeting-improvements` memory**

Once merged, record what actually shipped (column added, files touched, the two scope additions from the "Scope note" above, and any review findings worth remembering) the same way Part 1's summary was recorded.
