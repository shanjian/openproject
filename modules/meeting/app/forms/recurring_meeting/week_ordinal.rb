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

class RecurringMeeting::WeekOrdinal < ApplicationForm
  ORDINALS = [1, 2, 3, 4, -1].freeze

  form do |meeting_form|
    meeting_form.select_list(
      name: "week_ordinal",
      label: I18n.t("activerecord.attributes.recurring_meeting.week_ordinal"),
      data: {
        action: "input->recurring-meetings--form#updateFrequencyText"
      }
    ) do |list|
      ORDINALS.each do |value|
        list.option(label: I18n.t("recurring_meeting.ordinal.#{value}"),
                    value:,
                    selected: value == selected_ordinal)
      end
    end
  end

  def initialize(meeting:)
    super()

    @meeting = meeting
  end

  private

  def selected_ordinal
    return @meeting.week_ordinal if @meeting.week_ordinal.present?

    start_date = @meeting.start_time&.to_date || Date.tomorrow
    derived = ((start_date.day - 1) / 7) + 1
    # A start date on the fifth occurrence of its weekday has no explicit option;
    # "last" is the closest equivalent.
    derived > 4 ? -1 : derived
  end
end
