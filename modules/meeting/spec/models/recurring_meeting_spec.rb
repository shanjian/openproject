# frozen_string_literal: true

require "spec_helper"
require_module_spec_helper

RSpec.describe RecurringMeeting,
               with_settings: {
                 date_format: "%Y-%m-%d"
               } do
  describe "end_date" do
    subject { build(:recurring_meeting, start_date: (Date.current + 2.days).iso8601, end_date:) }

    context "with end_date before start_date" do
      let(:end_date) { Date.current + 1.day }

      it "is invalid" do
        expect(subject).not_to be_valid
        expect(subject.errors[:end_date]).to include("must be after #{subject.start_date}.")
      end
    end
  end

  describe "intervals" do
    subject { build(:recurring_meeting) }

    it "validates integer values >= 1" do
      subject.interval = 1
      expect(subject).to be_valid
      expect(subject.errors[:interval]).to be_empty
    end

    it "validates max value" do
      subject.interval = 101
      expect(subject).not_to be_valid
      expect(subject.errors[:interval]).to include("must be less than or equal to 100.")

      subject.interval = 100
      expect(subject).to be_valid
    end

    it "adds errors for invalid values", :aggregate_failures do
      subject.interval = 0
      expect(subject).not_to be_valid
      expect(subject.errors[:interval]).to include("must be greater than or equal to 1.")

      subject.interval = -1
      expect(subject).not_to be_valid
      expect(subject.errors[:interval]).to include("must be greater than or equal to 1.")

      subject.interval = 0.1
      expect(subject).not_to be_valid
      expect(subject.errors[:interval]).to include("is not an integer.")

      subject.interval = "asdf"
      expect(subject).not_to be_valid
      expect(subject.errors[:interval]).to include("is not a number.")
    end
  end

  describe "iterations" do
    subject { build(:recurring_meeting, end_after: "iterations") }

    it "does not validate if end_after is not iterations" do
      subject.end_after = "specific_date"
      subject.iterations = nil
      expect(subject).to be_valid
    end

    it "validates integer values >= 1" do
      subject.iterations = 1
      expect(subject).to be_valid
      expect(subject.errors[:iterations]).to be_empty
    end

    it "validates max value" do
      subject.iterations = 1001
      expect(subject).not_to be_valid
      expect(subject.errors[:iterations]).to include("must be less than or equal to 1000.")

      subject.iterations = 1000
      expect(subject).to be_valid
    end

    it "adds errors for invalid values", :aggregate_failures do
      subject.iterations = 0
      expect(subject).not_to be_valid
      expect(subject.errors[:iterations]).to include("must be greater than or equal to 1.")

      subject.iterations = -1
      expect(subject).not_to be_valid
      expect(subject.errors[:iterations]).to include("must be greater than or equal to 1.")

      subject.iterations = 0.1
      expect(subject).not_to be_valid
      expect(subject.errors[:iterations]).to include("is not an integer.")

      subject.iterations = "asdf"
      expect(subject).not_to be_valid
      expect(subject.errors[:iterations]).to include("is not a number.")
    end
  end

  describe "daily schedule" do
    subject do
      build(:recurring_meeting,
            start_time: Time.zone.tomorrow + 10.hours,
            frequency: "daily",
            end_after: "specific_date",
            end_date: Time.zone.tomorrow + 1.week)
    end

    it "schedules daily", :aggregate_failures do
      expect(subject.first_occurrence).to eq Time.zone.tomorrow + 10.hours
      expect(subject.last_occurrence).to eq Time.zone.tomorrow + 7.days + 10.hours

      occurrence_in_two_days = Time.zone.today + 2.days + 10.hours
      Timecop.freeze(Time.zone.tomorrow + 11.hours) do
        expect(subject.next_occurrence).to eq occurrence_in_two_days
      end

      next_occurrences = subject.scheduled_occurrences(limit: 5).map(&:to_time)
      expect(next_occurrences).to eq [
        Time.zone.tomorrow + 10.hours,
        Time.zone.today + 2.days + 10.hours,
        Time.zone.today + 3.days + 10.hours,
        Time.zone.today + 4.days + 10.hours,
        Time.zone.today + 5.days + 10.hours
      ]

      Timecop.freeze(Time.zone.tomorrow + 2.weeks) do
        expect(subject.next_occurrence).to be_nil
      end
    end
  end

  describe "working_days schedule" do
    subject do
      build(:recurring_meeting,
            start_time: DateTime.parse("2024-12-02T10:00Z"),
            frequency: "working_days",
            end_after: "specific_date",
            end_date: DateTime.parse("2024-12-29T10:00Z"))
    end

    context "with working days set to four-week", with_settings: { working_days: [1, 2, 3, 4] } do
      it "schedules working days", :aggregate_failures do
        # Monday, 9AM
        Timecop.freeze(DateTime.parse("2024-12-02T09:00Z")) do
          expect(subject.first_occurrence).to eq Time.zone.today + 10.hours
          # Last thursday of the year
          expect(subject.last_occurrence).to eq DateTime.parse("2024-12-26T10:00Z")

          next_occurrences = subject.scheduled_occurrences(limit: 5).map(&:to_time)
          expect(next_occurrences).to eq [
            DateTime.parse("2024-12-02T10:00Z"),
            DateTime.parse("2024-12-03T10:00Z"),
            DateTime.parse("2024-12-04T10:00Z"),
            DateTime.parse("2024-12-05T10:00Z"),
            DateTime.parse("2024-12-09T10:00Z")
          ]
        end

        # Go to Saturday, expect next on Monday
        Timecop.freeze(DateTime.parse("2024-12-07T09:00Z")) do
          expect(subject.next_occurrence).to eq DateTime.parse("2024-12-09T10:00Z")
        end
      end
    end
  end

  describe "weekly schedule" do
    subject do
      build(:recurring_meeting,
            start_time: Time.zone.tomorrow + 10.hours,
            frequency: "weekly",
            end_after: "specific_date",
            end_date: Time.zone.tomorrow + 4.weeks)
    end

    it "schedules weekly", :aggregate_failures do
      expect(subject.first_occurrence).to eq Time.zone.tomorrow + 10.hours
      expect(subject.last_occurrence).to eq Time.zone.tomorrow + 4.weeks + 10.hours

      following_occurrence = Time.zone.tomorrow + 7.days + 10.hours
      Timecop.freeze(Time.zone.tomorrow + 11.hours) do
        expect(subject.next_occurrence).to eq following_occurrence
      end

      next_occurrences = subject.scheduled_occurrences(limit: 5).map(&:to_time)
      expect(next_occurrences).to eq [
        Time.zone.tomorrow + 10.hours,
        Time.zone.tomorrow + 7.days + 10.hours,
        Time.zone.tomorrow + 14.days + 10.hours,
        Time.zone.tomorrow + 21.days + 10.hours,
        Time.zone.tomorrow + 28.days + 10.hours
      ]

      Timecop.freeze(Time.zone.tomorrow + 5.weeks) do
        expect(subject.next_occurrence).to be_nil
      end
    end
  end

  describe "never ending meeting" do
    subject do
      build(:recurring_meeting,
            start_time: Time.zone.tomorrow + 10.hours,
            frequency: "daily",
            end_after: "never")
    end

    it "schedules daily", :aggregate_failures do
      expect(subject.first_occurrence).to eq Time.zone.tomorrow + 10.hours
      expect(subject.remaining_occurrences).to be_nil
      expect(subject.last_occurrence).to be_nil
    end
  end

  describe "#upcoming_instantiated_meetings" do
    let!(:recurring_meeting) { create(:recurring_meeting) }
    let!(:ongoing_meeting) do
      create(:scheduled_meeting, :persisted, start_time: 5.minutes.ago, recurring_meeting: recurring_meeting)
    end
    let!(:cancelled_meeting) { create(:scheduled_meeting, recurring_meeting: recurring_meeting, cancelled: true) }

    it "returns only upcoming and not cancelled meetings" do
      expect(recurring_meeting.upcoming_instantiated_meetings).to eq [ongoing_meeting]
    end
  end

  describe "#ical_schedule / #schedule" do
    context "with a schedule with number of iterations" do
      let(:recurring_meeting) do
        build(:recurring_meeting,
              start_time: DateTime.parse("2024-10-01T12:00Z"),
              frequency: "weekly",
              end_after: "iterations",
              iterations: 5,
              current_schedule_start: DateTime.parse("2024-10-15T12:00Z"))

        # Occurrences on 2024-10-01, 2024-10-08, 2024-10-15, 2024-10-22, 2024-10-29
      end

      it "builds an IceCube schedule for iCal based on current_schedule_start" do
        schedule = recurring_meeting.ical_schedule

        expect(schedule.start_time).to eq(recurring_meeting.current_schedule_start)
        expect(schedule.rrules.count).to eq 1

        rrule = schedule.rrules.first

        expect(rrule).to be_a(IceCube::WeeklyRule)
        expect(rrule.occurrence_count).to eq(3) # 15th is the 3rd occurrence, so with it 3 remaining
      end

      it "builds an IceCube schedule for based on start_time" do
        schedule = recurring_meeting.schedule

        expect(schedule.start_time).to eq(recurring_meeting.start_time)
        expect(schedule.rrules.count).to eq 1

        rrule = schedule.rrules.first

        expect(rrule).to be_a(IceCube::WeeklyRule)
        expect(rrule.occurrence_count).to eq(5)
      end
    end

    context "with a schedule until a specific date" do
      let(:recurring_meeting) do
        build(:recurring_meeting,
              start_time: DateTime.parse("2024-10-01T12:00Z"),
              frequency: "weekly",
              end_after: "specific_date",
              end_date: Date.parse("2024-11-05"),
              current_schedule_start: DateTime.parse("2024-10-15T12:00Z"))
      end

      it "builds an IceCube schedule for iCal based on current_schedule_start" do
        schedule = recurring_meeting.ical_schedule

        expect(schedule.start_time).to eq(recurring_meeting.current_schedule_start)
        expect(schedule.rrules.count).to eq 1

        rrule = schedule.rrules.first

        expect(rrule).to be_a(IceCube::WeeklyRule)
        expect(rrule.until_time).to eq(recurring_meeting.end_date + 1.day)
      end

      it "builds an IceCube schedule for based on start_time" do
        schedule = recurring_meeting.schedule

        expect(schedule.start_time).to eq(recurring_meeting.start_time)
        expect(schedule.rrules.count).to eq 1

        rrule = schedule.rrules.first

        expect(rrule).to be_a(IceCube::WeeklyRule)
        expect(rrule.until_time).to eq(recurring_meeting.end_date + 1.day)
      end
    end
  end

  describe "#uid" do
    it "assigns a uid on create" do
      series = build(:recurring_meeting)
      expect(series.uid).to be_present
      expect(series.uid).to include "@#{Setting.host_name}"
    end
  end

  # Expected values below are the measured RRULE results from the requirements doc,
  # all anchored on DTSTART 2026-09-04T17:00Z (a Friday).
  describe "extended recurrence rules" do
    shared_let(:anchor) { DateTime.parse("2026-09-04T17:00Z") }

    def build_series(**attributes)
      build(:recurring_meeting,
            start_time: anchor,
            end_after: "never",
            interval: 1,
            **attributes)
    end

    def first_occurrences(series, count)
      series
        .scheduled_occurrences(limit: count, from_time: anchor - 1.minute)
        .map { |occurrence| occurrence.to_time.utc }
    end

    def expected_times(*dates)
      dates.map { |date| Time.zone.parse("#{date}T17:00Z") }
    end

    describe "weekly with multiple weekdays" do
      it "recurs on Mon/Wed/Fri every 2 weeks" do
        series = build_series(frequency: "weekly", interval: 2, weekdays: [1, 3, 5])

        expect(first_occurrences(series, 6)).to eq expected_times(
          "2026-09-04", "2026-09-14", "2026-09-16", "2026-09-18", "2026-09-28", "2026-09-30"
        )
      end

      it "keeps the start-date weekday when weekdays are not chosen (legacy behaviour)" do
        series = build_series(frequency: "weekly")
        series.validate

        expect(series.weekdays).to eq [5]
        expect(first_occurrences(series, 3)).to eq expected_times(
          "2026-09-04", "2026-09-11", "2026-09-18"
        )
      end
    end

    describe "monthly on the nth weekday" do
      it "recurs on the first Friday" do
        series = build_series(frequency: "monthly", schedule_mode: "nth_weekday", week_ordinal: 1)

        expect(first_occurrences(series, 6)).to eq expected_times(
          "2026-09-04", "2026-10-02", "2026-11-06", "2026-12-04", "2027-01-01", "2027-02-05"
        )
      end

      it "recurs on the last Friday, starting after the start date" do
        series = build_series(frequency: "monthly", schedule_mode: "nth_weekday", week_ordinal: -1)

        expect(first_occurrences(series, 6)).to eq expected_times(
          "2026-09-25", "2026-10-30", "2026-11-27", "2026-12-25", "2027-01-29", "2027-02-26"
        )
      end

      it "derives the ordinal from the start date when not set" do
        series = build_series(frequency: "monthly", schedule_mode: "nth_weekday")

        expect(first_occurrences(series, 3)).to eq expected_times(
          "2026-09-04", "2026-10-02", "2026-11-06"
        )
      end

      it "recurs on a chosen weekday different from the start date's" do
        series = build_series(frequency: "monthly", schedule_mode: "nth_weekday",
                              week_ordinal: 1, weekday: 1)

        expect(first_occurrences(series, 3)).to eq expected_times(
          "2026-09-07", "2026-10-05", "2026-11-02"
        )
      end

      it "recurs on the last occurrence of a chosen weekday" do
        series = build_series(frequency: "monthly", schedule_mode: "nth_weekday",
                              week_ordinal: -1, weekday: 3)

        expect(first_occurrences(series, 3)).to eq expected_times(
          "2026-09-30", "2026-10-28", "2026-11-25"
        )
      end

      it "keeps an explicitly chosen ordinal and weekday when the weekday mode option is submitted" do
        series = build_series(frequency: "monthly", schedule_mode_option: "nth_weekday",
                              week_ordinal: 1, weekday: 1)
        series.validate

        expect(series.week_ordinal).to eq 1
        expect(series.weekday).to eq 1
        expect(first_occurrences(series, 2)).to eq expected_times("2026-09-07", "2026-10-05")
      end

      it "reads stored last-weekday schedules as the weekday mode option" do
        series = build_series(frequency: "monthly", schedule_mode: "nth_weekday", week_ordinal: -1)

        expect(series.schedule_mode_option).to eq "nth_weekday"
      end
    end

    describe "monthly on a day of the month" do
      it "skips months shorter than the requested day" do
        series = build_series(frequency: "monthly", schedule_mode: "day_of_month", month_day: 31)

        expect(first_occurrences(series, 6)).to eq expected_times(
          "2026-10-31", "2026-12-31", "2027-01-31", "2027-03-31", "2027-05-31", "2027-07-31"
        )
      end

      it "supports the last day of the month" do
        series = build_series(frequency: "monthly", schedule_mode: "day_of_month", month_day: -1)

        expect(first_occurrences(series, 6)).to eq expected_times(
          "2026-09-30", "2026-10-31", "2026-11-30", "2026-12-31", "2027-01-31", "2027-02-28"
        )
      end

      it "derives the day from the start date when not set" do
        series = build_series(frequency: "monthly", schedule_mode: "day_of_month")

        expect(first_occurrences(series, 3)).to eq expected_times(
          "2026-09-04", "2026-10-04", "2026-11-04"
        )
      end
    end

    describe "yearly" do
      it "recurs on the start date's month and day" do
        series = build_series(frequency: "yearly", schedule_mode: "day_of_month")

        expect(first_occurrences(series, 6)).to eq expected_times(
          "2026-09-04", "2027-09-04", "2028-09-04", "2029-09-04", "2030-09-04", "2031-09-04"
        )
      end

      it "recurs on the first Friday of the start month" do
        series = build_series(frequency: "yearly", schedule_mode: "nth_weekday", week_ordinal: 1)

        expect(first_occurrences(series, 3)).to eq expected_times(
          "2026-09-04", "2027-09-03", "2028-09-01"
        )
      end

      it "recurs on a chosen weekday of the start month" do
        series = build_series(frequency: "yearly", schedule_mode: "nth_weekday",
                              week_ordinal: 1, weekday: 1)

        expect(first_occurrences(series, 3)).to eq expected_times(
          "2026-09-07", "2027-09-06", "2028-09-04"
        )
      end
    end

    describe "field normalization and validation" do
      it "clears weekdays for non-weekly frequencies" do
        series = build_series(frequency: "daily", weekdays: [1, 2])
        series.validate

        expect(series.weekdays).to be_empty
      end

      it "deduplicates and sorts weekdays" do
        series = build_series(frequency: "weekly", weekdays: [5, 1, 5, 3])
        series.validate

        expect(series.weekdays).to eq [1, 3, 5]
      end

      it "rejects weekday values outside 1..7" do
        series = build_series(frequency: "weekly", weekdays: [0, 8])

        expect(series).not_to be_valid
        expect(series.errors[:weekdays]).to be_present
      end

      it "rejects invalid month_day values" do
        series = build_series(frequency: "monthly", schedule_mode: "day_of_month", month_day: 32)

        expect(series).not_to be_valid
        expect(series.errors[:month_day]).to be_present
      end

      it "rejects invalid week_ordinal values" do
        series = build_series(frequency: "monthly", schedule_mode: "nth_weekday", week_ordinal: 5)

        expect(series).not_to be_valid
        expect(series.errors[:week_ordinal]).to be_present
      end

      it "rejects invalid weekday values" do
        series = build_series(frequency: "monthly", schedule_mode: "nth_weekday", weekday: 8)

        expect(series).not_to be_valid
        expect(series.errors[:weekday]).to be_present
      end

      it "clears the weekday and ordinal when the schedule is by day of month" do
        series = build_series(frequency: "monthly", schedule_mode_option: "day_of_month",
                              week_ordinal: 2, weekday: 1)
        series.validate

        expect(series.weekday).to be_nil
        expect(series.week_ordinal).to be_nil
      end

      it "clears the weekday for non-monthly/yearly frequencies" do
        series = build_series(frequency: "weekly", weekday: 1)
        series.validate

        expect(series.weekday).to be_nil
      end
    end

    describe "schedule humanization" do
      it "includes the interval for monthly last-day rules" do
        series = build_series(frequency: "monthly", interval: 2,
                              schedule_mode: "day_of_month", month_day: -1)

        expect(series.base_schedule).to eq "Every 2 months on the last day"
      end

      it "includes the interval for yearly nth-weekday rules" do
        series = build_series(frequency: "yearly", interval: 2,
                              schedule_mode: "nth_weekday", week_ordinal: 1)

        expect(series.base_schedule).to eq "Every 2 years on the first Friday of September"
      end

      it "words yearly last-day rules instead of rendering day -1" do
        series = build_series(frequency: "yearly",
                              schedule_mode: "day_of_month", month_day: -1)

        expect(series.base_schedule).to eq "Every year on the last day of September"
      end

      it "uses the chosen weekday for monthly nth-weekday rules" do
        series = build_series(frequency: "monthly",
                              schedule_mode: "nth_weekday", week_ordinal: 1, weekday: 1)

        expect(series.base_schedule).to eq "Every month on the first Monday"
      end

      it "uses the chosen weekday for yearly nth-weekday rules" do
        series = build_series(frequency: "yearly",
                              schedule_mode: "nth_weekday", week_ordinal: -1, weekday: 3)

        expect(series.base_schedule).to eq "Every year on the last Wednesday of September"
      end
    end

    describe "#matching_preset" do
      it "maps each preset round-trip" do
        aggregate_failures do
          expect(build_series(frequency: "daily").matching_preset).to eq "daily"
          expect(build_series(frequency: "working_days").matching_preset).to eq "working_days"
          expect(build_series(frequency: "weekly", weekdays: [5]).matching_preset).to eq "weekly"
          expect(build_series(frequency: "monthly", schedule_mode: "nth_weekday", week_ordinal: 1)
            .matching_preset).to eq "monthly_nth_weekday"
          expect(build_series(frequency: "yearly", schedule_mode: "day_of_month").matching_preset).to eq "yearly"
        end
      end

      it "returns custom for anything a preset cannot express" do
        aggregate_failures do
          expect(build_series(frequency: "weekly", interval: 2, weekdays: [5]).matching_preset).to eq "custom"
          expect(build_series(frequency: "weekly", weekdays: [1, 3, 5]).matching_preset).to eq "custom"
          expect(build_series(frequency: "monthly", schedule_mode: "nth_weekday", week_ordinal: -1)
            .matching_preset).to eq "custom"
          expect(build_series(frequency: "monthly", schedule_mode: "day_of_month", month_day: 31)
            .matching_preset).to eq "custom"
          expect(build_series(frequency: "monthly", schedule_mode: "nth_weekday", weekday: 1)
            .matching_preset).to eq "custom"
        end
      end
    end
  end

  describe "#lock_version" do
    it "increments on every save (optimistic locking)" do
      recurring_meeting = create(:recurring_meeting)

      expect { recurring_meeting.update!(interval: recurring_meeting.interval + 1) }
        .to change(recurring_meeting, :lock_version).by(1)
    end
  end
end
