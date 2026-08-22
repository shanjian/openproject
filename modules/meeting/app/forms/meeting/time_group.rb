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

class Meeting::TimeGroup < ApplicationForm
  include Redmine::I18n

  # The zones our offices actually use. The full Rails zone list (~120 grouped
  # entries, labeled by Rails names like "Eastern Time (US & Canada)") made the
  # common case - finding your own city - needlessly hard. Zones outside this
  # list stay valid; see the safety valve in #available_time_zones.
  COMMON_TIME_ZONES = %w[
    America/New_York
    America/Toronto
    America/Los_Angeles
    America/Mexico_City
    America/Sao_Paulo
    Europe/London
    Europe/Paris
    Europe/Berlin
    Europe/Stockholm
    Europe/Madrid
    Europe/Rome
    Europe/Prague
    Europe/Bratislava
    Europe/Bucharest
    Asia/Tokyo
    Asia/Seoul
    Asia/Taipei
    Australia/Sydney
    Pacific/Auckland
    Etc/UTC
  ].freeze

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
      disabled: series_occurrence?,
      data: time_zone_select_data
    ) do |list|
      available_time_zones.each do |zone_label, value|
        list.option(label: zone_label, value:, selected: value == @initial_time_zone)
      end
    end
  end

  def initialize(meeting:)
    super()

    @meeting = meeting
    @initial_time = meeting.start_time_hour.presence
    @initial_date = meeting.start_date.presence
    @initial_time_zone = initial_time_zone_value(meeting)

    duration = duration_value(meeting)
    @duration = duration.nil? ? "" : ChronicDuration.output(duration * 3600, format: :hours_only)
  end

  private

  def available_time_zones
    @available_time_zones ||= begin
      options = COMMON_TIME_ZONES.map { |identifier| [common_zone_label(identifier), identifier] }

      # Safety valve: a meeting stored with (or a creator whose profile is set to)
      # a zone outside the curated list must still see that zone offered and
      # preselected - otherwise the browser would silently submit the first
      # option on save and shift the meeting's wall-clock time.
      unless COMMON_TIME_ZONES.include?(@initial_time_zone)
        options << [fallback_zone_label(@initial_time_zone), @initial_time_zone]
      end

      options
    end
  end

  def common_zone_label(identifier)
    name = I18n.t("meeting.common_time_zones.#{identifier.downcase.gsub(%r{[/\s-]}, '_')}")

    if identifier == "Etc/UTC"
      "(UTC#{live_utc_offset(identifier)}) #{name}"
    else
      "(UTC#{live_utc_offset(identifier)}) #{name} — #{identifier}"
    end
  end

  def fallback_zone_label(identifier)
    "(UTC#{live_utc_offset(identifier)}) #{identifier}"
  end

  # The offset the zone actually observes at the meeting's start (or now, on a
  # blank form) - i.e. DST-aware, unlike the base offset, which for e.g.
  # America/New_York claims -05:00 all summer long.
  def live_utc_offset(identifier)
    period = @meeting.start_time || Time.zone.now
    ActiveSupport::TimeZone.seconds_to_utc_offset(TZInfo::Timezone.get(identifier).observed_utc_offset(period))
  end

  def initial_time_zone_value(meeting)
    zone =
      if persisted_zone_source?
        meeting.time_zone
      else
        # New record: default to the creator's profile zone (which itself falls
        # back to Setting.user_default_timezone); the meetings--form Stimulus
        # controller may then refine a pure fallback to the browser's zone.
        User.current.time_zone
      end

    # `ActiveSupport::TimeZone#tzinfo.name` returns the tzinfo identifier the
    # zone was looked up as - which may be an alias ("UTC" -> "Etc/UTC" via the
    # Rails MAPPING, or a link zone like "Europe/Bratislava"). Prefer an exact
    # match against the curated identifiers so Bratislava selects Bratislava,
    # then fall back to canonical-identifier matching (e.g. a stored
    # "US/Eastern" selects America/New_York), and otherwise hand the canonical
    # identifier to the safety valve in #available_time_zones.
    raw = zone.tzinfo.name
    return raw if COMMON_TIME_ZONES.include?(raw)

    canonical = zone.tzinfo.canonical_zone.identifier
    COMMON_TIME_ZONES.find { |identifier| canonical_identifier(identifier) == canonical } || canonical
  end

  def canonical_identifier(identifier)
    TZInfo::Timezone.get(identifier).canonical_zone.identifier
  end

  def time_zone_select_data
    data = {
      action: "input->meetings--form#updateTimezoneText",
      "meetings--form-target": "timezoneSelect"
    }
    # Only a pure fallback default (nothing stored, no explicit profile zone) may
    # be refined to the browser's zone client-side; an explicit choice never is.
    data["browser-timezone-default"] = "true" if !persisted_zone_source? && !User.current.pref.time_zone?
    data
  end

  def persisted_zone_source?
    @meeting.persisted? || (@meeting.is_a?(RecurringMeeting) && @meeting.template&.persisted?)
  end

  def duration_value(meeting)
    if meeting.is_a?(RecurringMeeting) && meeting.template
      meeting.template.duration
    else
      meeting.duration
    end
  end

  def timezone_caption
    friendly_timezone_name(@meeting.time_zone, period: @meeting.start_time || Time.zone.now)
  end

  def editing_recurring?
    @meeting.is_a?(RecurringMeeting) && @meeting.persisted?
  end

  # A series occurrence never carries a private zone - Meeting#time_zone always
  # delegates to the series once recurring? is true - so its own select would be
  # silently inert if left editable. The series/template case (a RecurringMeeting)
  # is untouched and stays fully editable.
  def series_occurrence?
    @meeting.is_a?(Meeting) && @meeting.recurring?
  end
end
