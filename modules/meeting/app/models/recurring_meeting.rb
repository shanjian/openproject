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

class RecurringMeeting < ApplicationRecord
  # Magical maximum of iterations
  MAX_ITERATIONS = 1000
  # Magical maximum of interval, derived from other calendars
  MAX_INTERVAL = 100
  # ISO weekday numbers as ice_cube symbols (1 = Monday .. 7 = Sunday)
  ISO_WEEKDAY_SYMBOLS = {
    1 => :monday, 2 => :tuesday, 3 => :wednesday, 4 => :thursday,
    5 => :friday, 6 => :saturday, 7 => :sunday
  }.freeze

  include ::Meeting::VirtualStartTime
  include ::Meeting::MeetingUid
  include Redmine::I18n

  belongs_to :project
  belongs_to :author, class_name: "User"

  validates :start_time, :title, :frequency, :end_after, :time_zone, presence: true
  validates :end_date, presence: { if: -> { end_after_specific_date? } }
  validates :iterations,
            numericality: { only_integer: true,
                            greater_than_or_equal_to: 1,
                            less_than_or_equal_to: MAX_ITERATIONS,
                            if: -> { end_after_iterations? } }
  validates :interval,
            numericality: { only_integer: true,
                            greater_than_or_equal_to: 1,
                            less_than_or_equal_to: MAX_INTERVAL,
                            if: -> { !frequency_working_days? } }

  validate :end_date_constraints,
           if: -> { end_after_specific_date? }

  validate :weekdays_constraints,
           if: -> { frequency_weekly? }
  validates :month_day,
            inclusion: { in: [-1, *1..31], allow_nil: true }
  validates :week_ordinal,
            inclusion: { in: [-1, *1..4], allow_nil: true }
  validates :weekday,
            inclusion: { in: 1..7, allow_nil: true }

  after_initialize :set_defaults

  # Unset any previously set schedule before running validations
  before_validation :unset_schedule
  before_validation :apply_preset
  before_validation :apply_schedule_mode_option
  before_validation :normalize_schedule_fields

  before_destroy :remove_jobs
  after_save :unset_schedule

  enum :frequency,
       {
         daily: 0,
         working_days: 1,
         weekly: 2,
         monthly: 3,
         yearly: 4
       },
       prefix: true,
       default: "weekly"

  enum :schedule_mode,
       {
         day_of_month: 0,
         nth_weekday: 1
       },
       prefix: true,
       default: "day_of_month"

  enum :end_after,
       {
         specific_date: 0,
         iterations: 1,
         never: 3
       },
       prefix: true,
       default: "never"

  has_many :meetings,
           inverse_of: :recurring_meeting,
           dependent: :destroy

  has_many :scheduled_meetings,
           inverse_of: :recurring_meeting,
           dependent: :delete_all

  has_one :template, -> { where(template: true) },
          class_name: "Meeting"

  has_many :recurring_meeting_interim_responses,
           inverse_of: :recurring_meeting,
           dependent: :destroy

  scope :visible, ->(*args) {
    includes(:project)
      .references(:projects)
      .merge(Project.allowed_to(args.first || User.current, :view_meetings))
  }

  scope :participated_by, ->(user) {
    left_outer_joins(template: :participants).where(participants: { user_id: user.id })
  }

  # Virtual attributes that can be passed on to the template on save
  virtual_attribute :location do
    nil
  end
  virtual_attribute :duration do
    nil
  end
  virtual_attribute :notify do
    nil
  end

  def will_end?
    last_occurrence.present?
  end

  def has_ended?
    will_end? && last_occurrence < Time.zone.now
  end

  def notify?
    template&.notify?
  end

  def human_frequency
    case frequency
    when "working_days"
      I18n.t("recurring_meeting.frequency.working_days")
    else
      I18n.t("recurring_meeting.frequency.x_#{frequency}", count: interval)
    end
  end

  def human_day_of_week
    I18n.t("recurring_meeting.frequency.every_weekday", day_of_the_week: start_weekday_name)
  end

  def start_weekday_name
    return I18n.t(:label_empty_element) if start_time.blank?

    I18n.l(start_time, format: "%A")
  end

  def date
    start_time.day.ordinalize
  end

  def start_time
    super&.in_time_zone(time_zone)
  end

  def current_schedule_end
    start_time + template.duration.hours
  end

  def time_zone_differs?
    time_zone != User.current.time_zone
  end

  def time_zone
    time_zone_string = super
    zone = ActiveSupport::TimeZone[time_zone_string] if time_zone_string.present?

    zone || User.current.time_zone
  end

  def schedule
    @schedule ||= IceCube::Schedule.new(start_time, duration: template&.duration).tap do |s|
      s.add_recurrence_rule count_rule(frequency_rule)
      exclude_non_working_days(s) if frequency_working_days?
    end
  end

  def ical_schedule
    @ical_schedule ||= IceCube::Schedule.new(current_schedule_start, duration: template&.duration).tap do |s|
      s.add_recurrence_rule count_rule(frequency_rule, only_upcoming_iterations: true)
      exclude_non_working_days(s) if frequency_working_days?
    end
  end

  def base_schedule
    case frequency
    when "daily"
      if interval == 1
        human_frequency
      else
        I18n.t("recurring_meeting.in_words.daily_interval", interval:)
      end
    when "working_days"
      I18n.t("recurring_meeting.in_words.working_days")
    when "weekly"
      weekly_schedule_in_words
    when "monthly"
      monthly_schedule_in_words
    when "yearly"
      yearly_schedule_in_words
    end
  end

  def human_weekdays
    days = weekdays.presence || default_weekdays
    days.map { |day| weekday_name(day) }.join(", ")
  end

  def weekday_name(iso_day)
    I18n.t("date.day_names")[iso_day % 7]
  end

  def human_ordinal
    I18n.t("recurring_meeting.ordinal.#{effective_week_ordinal}")
  end

  def full_schedule_in_words # rubocop:disable Metrics/AbcSize
    time = "#{format_time(start_time, time_zone:, include_date: false)} (#{friendly_timezone_name(time_zone)})"
    if has_ended?
      I18n.t("recurring_meeting.in_words.full_past",
             base: base_schedule,
             time:,
             end_date: format_date(last_occurrence))
    elsif will_end?
      I18n.t("recurring_meeting.in_words.full",
             base: base_schedule,
             time:,
             end_date: format_date(last_occurrence))
    else
      I18n.t("recurring_meeting.in_words.never_ending",
             base: base_schedule,
             time:)
    end
  end

  def human_frequency_schedule
    formatted_time = format_time(start_time, time_zone:, include_date: false)
    time = time_zone_differs? ? "#{formatted_time} (#{friendly_timezone_name(time_zone)})" : formatted_time
    I18n.t("recurring_meeting.in_words.frequency",
           base: base_schedule,
           time:)
  end

  def reschedule_required?(previous: false)
    (previous ? previous_changes : changes)
      .keys
      .intersect?(%w[frequency start_date start_time start_time_hour iterations interval end_after end_date location
                     weekdays schedule_mode month_day week_ordinal weekday])
  end

  # The form preset (R1) this schedule corresponds to, or "custom" when the stored
  # fields express something no preset can.
  def matching_preset # rubocop:disable Metrics/PerceivedComplexity, Metrics/AbcSize
    return "custom" unless interval == 1

    case frequency
    when "daily", "working_days"
      frequency
    when "weekly"
      (weekdays.presence || default_weekdays) == default_weekdays ? "weekly" : "custom"
    when "monthly"
      if schedule_mode_nth_weekday? &&
         effective_week_ordinal == start_ordinal_in_month &&
         effective_weekday == start_time.to_date.cwday
        "monthly_nth_weekday"
      else
        "custom"
      end
    when "yearly"
      if schedule_mode_day_of_month? && effective_month_day == start_time.day
        "yearly"
      else
        "custom"
      end
    end
  end

  def default_weekdays
    start_time.present? ? [start_time.to_date.cwday] : []
  end

  def effective_month_day
    month_day || start_time.day
  end

  def effective_week_ordinal
    week_ordinal || start_ordinal_in_month
  end

  # ISO weekday a monthly/yearly nth-weekday rule recurs on; falls back to the
  # start date's weekday when none was chosen explicitly.
  def effective_weekday
    weekday || start_time.to_date.cwday
  end

  # Which occurrence of its weekday the start date is within its month (1..5)
  def start_ordinal_in_month
    ((start_time.day - 1) / 7) + 1
  end

  # Form-level virtual attribute (R1): a named preset that expands to concrete
  # schedule fields in a before_validation callback, so it wins regardless of
  # the order form fields are assigned in.
  def preset=(value)
    @preset = value.presence
  end

  def preset
    @preset || matching_preset
  end

  # Form-level virtual attribute: composite mode select for monthly/yearly
  # ("on day 4" / "on the first Friday" / "on the last Friday" / "on the last day").
  def schedule_mode_option=(value)
    @schedule_mode_option = value.presence
  end

  def schedule_mode_option
    return @schedule_mode_option if @schedule_mode_option

    if schedule_mode_nth_weekday?
      "nth_weekday"
    else
      month_day == -1 ? "last_day" : "day_of_month"
    end
  end

  def scheduled_occurrences(limit:, from_time: Time.current)
    schedule.next_occurrences(limit, from_time)
  end

  def first_occurrence
    @first_occurrence ||= schedule.first
  end

  def last_occurrence
    return if end_after_never?

    @last_occurrence ||= schedule.last
  end

  def next_occurrence(from_time: Time.current)
    schedule.next_occurrence(from_time)&.to_time
  end

  def first_non_cancelled_occurrence(from_time: Time.current)
    skipped = []
    time = from_time

    while (occurrence = next_occurrence(from_time: time))
      if scheduled_meetings.cancelled.exists?(start_time: occurrence)
        skipped << occurrence
        time = occurrence
      else
        return { occurrence:, skipped: }
      end
    end

    nil
  end

  def previous_occurrence(from_time: Time.current)
    schedule.previous_occurrence(from_time)&.to_time
  end

  delegate :occurs_at?, to: :schedule

  def remaining_occurrences(after_time: Time.current)
    case end_after
    when "specific_date"
      schedule.occurrences_between(after_time, end_date.to_time(:utc).end_of_day)
    when "iterations"
      schedule.remaining_occurrences(after_time)
    end
  end

  def scheduled_instances(upcoming: true)
    filter_scope = upcoming ? :upcoming : :past
    direction = upcoming ? :asc : :desc

    scheduled_meetings
      .includes(:meeting)
      .public_send(filter_scope)
      .then { |o| filter_scope == :past ? o.not_cancelled : o }
      .order(start_time: direction)
  end

  def upcoming_instantiated_meetings
    @upcoming_instantiated_meetings ||= scheduled_meetings
      .includes(:meeting)
      .not_cancelled
      .joins(:meeting)
      .where("meetings.start_time + (interval '1 hour' * meetings.duration) >= ?", Time.current)
      .order(start_time: :asc)
  end

  def ongoing_meetings
    upcoming_instantiated_meetings
      .includes(:meeting)
      .where(meetings: { start_time: ..Time.current })
      .order(start_time: :asc)
  end

  def upcoming_cancelled_meetings
    # Include ongoing cancelled meetings by setting a start time in the past
    scheduled_meetings
      .cancelled
      .where(start_time: (Time.current - template.duration.hours)..)
      .order(start_time: :asc)
  end

  def instantiated_meetings
    meetings.not_templated
  end

  private

  def unset_schedule
    @schedule = nil
    @first_occurence = nil
    @last_occurrence = nil
  end

  def end_date_constraints
    return if end_date.nil?

    if parsed_start_date.present? && end_date < parsed_start_date
      errors.add(:end_date, :after, date: format_date(parsed_start_date))
    end
  end

  def weekdays_constraints
    errors.add(:weekdays, :invalid) unless weekdays.all? { |day| ISO_WEEKDAY_SYMBOLS.key?(day) }
  end

  def weekly_schedule_in_words # rubocop:disable Metrics/AbcSize
    days = weekdays.presence || default_weekdays

    if days.length > 1
      key = interval == 1 ? "weekly_days" : "weekly_interval_days"
      I18n.t("recurring_meeting.in_words.#{key}", interval:, weekdays: human_weekdays)
    elsif interval == 1
      I18n.t("recurring_meeting.in_words.weekly", weekday: weekday_name(days.first))
    else
      I18n.t("recurring_meeting.in_words.weekly_interval", interval:, weekday: weekday_name(days.first))
    end
  end

  def monthly_schedule_in_words # rubocop:disable Metrics/AbcSize
    if schedule_mode_nth_weekday?
      key = interval == 1 ? "monthly_nth_weekday" : "monthly_nth_weekday_interval"
      I18n.t("recurring_meeting.in_words.#{key}",
             interval:, ordinal: human_ordinal, weekday: weekday_name(effective_weekday))
    elsif effective_month_day == -1
      key = interval == 1 ? "monthly_last_day" : "monthly_last_day_interval"
      I18n.t("recurring_meeting.in_words.#{key}", interval:)
    else
      key = interval == 1 ? "monthly_day" : "monthly_day_interval"
      I18n.t("recurring_meeting.in_words.#{key}", interval:, day: effective_month_day)
    end
  end

  def yearly_schedule_in_words # rubocop:disable Metrics/AbcSize
    month = I18n.t("date.month_names")[start_time.month]

    if schedule_mode_nth_weekday?
      key = interval == 1 ? "yearly_nth_weekday" : "yearly_nth_weekday_interval"
      I18n.t("recurring_meeting.in_words.#{key}",
             interval:, ordinal: human_ordinal, weekday: weekday_name(effective_weekday), month:)
    elsif effective_month_day == -1
      key = interval == 1 ? "yearly_last_day" : "yearly_last_day_interval"
      I18n.t("recurring_meeting.in_words.#{key}", interval:, month:)
    else
      key = interval == 1 ? "yearly" : "yearly_interval"
      I18n.t("recurring_meeting.in_words.#{key}", interval:, date: "#{month} #{effective_month_day}")
    end
  end

  def apply_preset # rubocop:disable Metrics/AbcSize
    return if @preset.blank? || @preset == "custom"

    self.interval = 1
    case @preset
    when "daily", "working_days"
      self.frequency = @preset
    when "weekly"
      self.frequency = "weekly"
      self.weekdays = [] # normalized to the start date's weekday below
    when "monthly_nth_weekday"
      self.frequency = "monthly"
      self.schedule_mode = "nth_weekday"
      self.month_day = nil
      self.week_ordinal = nil
      self.weekday = nil
    when "yearly"
      self.frequency = "yearly"
      self.schedule_mode = "day_of_month"
      self.month_day = nil
      self.week_ordinal = nil
      self.weekday = nil
    end
  end

  def apply_schedule_mode_option
    # Only relevant when the custom fields are authoritative
    return if @schedule_mode_option.blank?
    return unless @preset.blank? || @preset == "custom"

    case @schedule_mode_option
    when "day_of_month"
      self.schedule_mode = "day_of_month"
      self.month_day = nil
    when "last_day"
      self.schedule_mode = "day_of_month"
      self.month_day = -1
    when "nth_weekday"
      # The form submits ordinal and weekday alongside; keep them as assigned so an
      # explicit choice wins over deriving both from the start date.
      self.schedule_mode = "nth_weekday"
    when "last_weekday"
      # Legacy option value, no longer offered by the form
      self.schedule_mode = "nth_weekday"
      self.week_ordinal = -1
    end
  end

  def normalize_schedule_fields
    normalize_weekly_fields

    if frequency_monthly? || frequency_yearly?
      normalize_monthly_fields
    else
      self.schedule_mode = "day_of_month"
      self.month_day = nil
      self.week_ordinal = nil
      self.weekday = nil
    end
  end

  def normalize_weekly_fields
    self.weekdays = if frequency_weekly?
                      weekdays.compact_blank.map(&:to_i).uniq.sort.presence || default_weekdays
                    else
                      []
                    end
  end

  # The form keeps submitting the hidden inputs of the non-selected mode;
  # only the selected mode's fields are authoritative.
  def normalize_monthly_fields
    if schedule_mode_day_of_month?
      self.week_ordinal = nil
      self.weekday = nil
    else
      self.month_day = nil
    end
  end

  def exclude_non_working_days(schedule)
    NonWorkingDay
      .where(date: start_date...)
      .pluck(:date)
      .each do |date|
      schedule.add_exception_time(date.to_time(:utc))
    end
  end

  def frequency_rule # rubocop:disable Metrics/AbcSize
    case frequency
    when "daily"
      IceCube::Rule.daily(interval)
    when "working_days"
      IceCube::Rule
        .weekly(interval)
        .day(*Setting.working_day_names)
    when "weekly"
      rule = IceCube::Rule.weekly(interval)
      rule = rule.day(*weekday_symbols) if weekdays.any?
      rule
    when "monthly"
      if schedule_mode_nth_weekday?
        IceCube::Rule.monthly(interval)
                     .day_of_week(nth_weekday_symbol => [effective_week_ordinal])
      else
        IceCube::Rule.monthly(interval).day_of_month(effective_month_day)
      end
    when "yearly"
      if schedule_mode_nth_weekday?
        IceCube::Rule.yearly(interval)
                     .month_of_year(start_time.month)
                     .day_of_week(nth_weekday_symbol => [effective_week_ordinal])
      else
        IceCube::Rule.yearly(interval)
                     .month_of_year(start_time.month)
                     .day_of_month(effective_month_day)
      end
    else
      raise NotImplementedError
    end
  end

  def weekday_symbols
    weekdays.map { |number| ISO_WEEKDAY_SYMBOLS.fetch(number) }
  end

  def nth_weekday_symbol
    ISO_WEEKDAY_SYMBOLS.fetch(effective_weekday)
  end

  def count_rule(rule, only_upcoming_iterations: false)
    case end_after
    when "specific_date"
      rule.until((end_date + 1.day).to_time(:utc))
    when "iterations"
      rule.count(iterations_for_schedule(only_upcoming_iterations: only_upcoming_iterations))
    else
      rule
    end
  end

  def iterations_for_schedule(only_upcoming_iterations:)
    if only_upcoming_iterations
      remaining_occurrences(after_time: current_schedule_start).size
    else
      iterations
    end
  end

  def set_defaults
    self.end_date ||= 1.year.from_now if end_after_specific_date?
  end

  def remove_jobs
    RecurringMeetings::InitNextOccurrenceJob.delete_jobs(self)
  end
end
