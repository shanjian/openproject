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
      data: {
        action: "input->meetings--form#updateTimezoneText"
      }
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

  # The curated list, plus - when the meeting's own zone is not in it - one extra
  # option for that zone. Without the extra option nothing would be selected and
  # an unmodified browser submit would silently rewrite the meeting's zone to the
  # first option, the regression a6d027e300c fixed.
  def available_time_zones
    @available_time_zones ||= begin
      options = Meeting::TimeZones.options
      extra = uncurated_time_zone_option(options)

      extra.nil? ? options : options + [extra]
    end
  end

  def uncurated_time_zone_option(options)
    return if options.any? { |(_label, value)| value == @initial_time_zone }

    Meeting::TimeZones.uncurated_option(@initial_time_zone)
  end

  def initial_time_zone_value(meeting)
    zone =
      if meeting.persisted? || (meeting.is_a?(RecurringMeeting) && meeting.template&.persisted?)
        meeting.time_zone
      else
        # New record: default to the creator's profile zone; if they have none set,
        # show UTC explicitly in the select rather than applying it silently.
        User.current.time_zone
      end

    # The select's option values are canonical tzinfo identifiers
    # (`Meeting::TimeZones`), but `ActiveSupport::TimeZone#name` returns
    # whichever string was used to look the zone up - e.g. "UTC" for
    # `ActiveSupport::TimeZone["UTC"]`, whose canonical identifier is
    # "Etc/UTC". Comparing on `#name` left no option selected for any zone
    # where those differ, so the browser silently submitted the first option
    # on save. Compare canonical identifiers instead.
    zone.tzinfo.canonical_zone.identifier
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
