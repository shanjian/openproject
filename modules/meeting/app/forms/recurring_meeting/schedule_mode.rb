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

class RecurringMeeting::ScheduleMode < ApplicationForm
  form do |meeting_form|
    meeting_form.select_list(
      name: "schedule_mode_option",
      label: I18n.t("activerecord.attributes.recurring_meeting.schedule_mode"),
      data: {
        action: "input->recurring-meetings--form#updateFrequencyText"
      }
    ) do |list|
      options.each do |value, label|
        list.option(label:, value:, selected: value == @meeting.schedule_mode_option)
      end
    end
  end

  def initialize(meeting:)
    super()

    @meeting = meeting
  end

  private

  def options
    start_date = @meeting.start_time&.to_date || Date.tomorrow
    weekday = I18n.t("date.day_names")[start_date.cwday % 7]
    ordinal = I18n.t("recurring_meeting.ordinal.#{((start_date.day - 1) / 7) + 1}")

    [
      ["day_of_month", I18n.t("recurring_meeting.schedule_mode.day_of_month", day: start_date.day)],
      ["nth_weekday", I18n.t("recurring_meeting.schedule_mode.nth_weekday", ordinal:, weekday:)],
      ["last_weekday", I18n.t("recurring_meeting.schedule_mode.nth_weekday",
                              ordinal: I18n.t("recurring_meeting.ordinal.-1"), weekday:)],
      ["last_day", I18n.t("recurring_meeting.schedule_mode.last_day_of_month")]
    ]
  end
end
