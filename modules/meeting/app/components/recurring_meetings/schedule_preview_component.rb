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

module RecurringMeetings
  class SchedulePreviewComponent < ApplicationComponent
    def initialize(meeting:)
      super

      @meeting = meeting
    end

    def render?
      @meeting.start_time.present? && @meeting.frequency.present?
    end

    def summary
      # Unlike human_frequency_schedule, this includes "ends on {date}" for
      # date- and iteration-bounded series.
      @meeting.full_schedule_in_words
    end

    def occurrences
      @occurrences ||= @meeting
        .scheduled_occurrences(limit: 5, from_time: @meeting.start_time - 1.minute)
        .map(&:to_time)
    rescue StandardError
      []
    end

    def total_count
      return unless @meeting.end_after_iterations?

      @meeting.iterations
    end

    def first_differs?
      occurrences.first.present? && occurrences.first != @meeting.start_time
    end

    def short_months_skipped?
      (@meeting.frequency_monthly? || @meeting.frequency_yearly?) &&
        @meeting.schedule_mode_day_of_month? &&
        @meeting.effective_month_day != -1 &&
        @meeting.effective_month_day >= 29
    end
  end
end
