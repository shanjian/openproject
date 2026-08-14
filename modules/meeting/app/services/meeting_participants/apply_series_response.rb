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
  # a row lock on the template Meeting (RecurringMeeting#with_template_lock).
  # InitOccurrenceService takes the same lock around occurrence instantiation, so
  # sweeps (in-app or email REPLY) and occurrence copying serialize: no occurrence
  # can be created mid-sweep with a stale status, and concurrent sweeps cannot leave
  # the template and occurrences disagreeing.
  #
  # Only invited rows are swept — the same eligibility rule the in-app respond path,
  # the digest, and the summary counts enforce.
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

    # also: an extra participant row updated within the same transaction regardless
    # of its occurrence's start time — the responded-on occurrence may already have
    # started (in_progress is respondable) while the sweep itself is future-only.
    #
    # Returns ServiceResult with the number of updated rows as result.
    def call(status:, stamp:, only_awaiting:, comment: COMMENT_UNSET, also: nil)
      updated = 0

      series.with_template_lock do
        # Queried after the lock is acquired, so a concurrently instantiated
        # occurrence is either visible here or will copy the updated template
        rows = rows_to_update(only_awaiting)
        rows << also if also && rows.none? { |row| row.id == also.id }

        rows.each do |participant|
          participant.update!(**attributes_for(status, stamp, comment))
          updated += 1
        end
      end

      if updated.positive?
        # After commit only: a rolled-back sweep must not produce a digest
        Meetings::SendParticipationDigestJob.schedule(series, since: stamp)
      end

      ServiceResult.success(result: updated)
    end

    private

    def rows_to_update(only_awaiting)
      [template_participant, *future_occurrence_participants(only_awaiting)].compact
    end

    def template_participant
      series.template.participants.invited.find_by(user:)
    end

    def future_occurrence_participants(only_awaiting)
      scope = MeetingParticipant
        .invited
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
