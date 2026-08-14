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

module MeetingParticipants
  # Applies a participation response across a recurring series: the template's
  # participant row plus future, instantiated occurrences — in ONE transaction under
  # a row lock on the template Meeting. InitOccurrenceService takes the same lock
  # around occurrence instantiation, so sweeps (in-app or email REPLY) and occurrence
  # copying serialize: no occurrence can be created mid-sweep with a stale status,
  # and concurrent sweeps cannot leave the template and occurrences disagreeing.
  #
  # Used by MeetingParticipants::RespondService (only_awaiting: false — the explicit
  # "this and all future occurrences" choice) and by
  # AllMeetings::HandleICalResponseService (only_awaiting: true — a generic email
  # REPLY only fills in occurrences still awaiting a response).
  class ApplySeriesResponse
    # Distinguishes "don't touch the comment" (in-app responses) from an explicit
    # value, including nil (email replies carry the parsed comment, possibly empty).
    COMMENT_UNSET = Object.new.freeze

    attr_reader :series, :user

    def initialize(series:, user:)
      @series = series
      @user = user
    end

    def call(status:, stamp:, only_awaiting:, comment: COMMENT_UNSET)
      updated_any = false

      MeetingParticipant.transaction do
        # Row lock on the template Meeting via a throwaway instance (with_lock
        # would reload the caller's cached template). The occurrence query runs
        # after the lock is acquired, so a concurrently instantiated occurrence is
        # either visible here or will copy the updated template.
        Meeting.lock.find(series.template.id)

        rows_to_update(only_awaiting).each do |participant|
          participant.update!(**attributes_for(status, stamp, comment))
          updated_any = true
        end
      end

      if updated_any
        # After commit only: a rolled-back sweep must not produce a digest
        Meetings::SendParticipationDigestJob
          .set(wait: 10.minutes)
          .perform_later(series, since: stamp)
      end

      updated_any
    end

    private

    def rows_to_update(only_awaiting)
      [template_participant, *future_occurrence_participants(only_awaiting)].compact
    end

    def template_participant
      series.template.participants.find_by(user:)
    end

    def future_occurrence_participants(only_awaiting)
      scope = MeetingParticipant
        .where(user:)
        .joins(:meeting)
        .where(meetings: { recurring_meeting_id: series.id, template: false })
        .where(meetings: { start_time: Time.current.. })

      only_awaiting ? scope.participation_needs_action : scope
    end

    def attributes_for(status, stamp, comment)
      attributes = { participation_status: status, participation_responded_at: stamp }
      attributes[:comment] = comment unless comment == COMMENT_UNSET
      attributes
    end
  end
end
