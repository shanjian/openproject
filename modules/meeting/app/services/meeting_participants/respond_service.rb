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
  # Records the current user's own participation response (in-app accept /
  # tentative / decline). A participant action, not an organizer action: the caller
  # only needs view_meetings plus an invited participant row
  # (Meeting#respondable_by?, shared with the side panel).
  #
  # scope: "series" on a recurring occurrence additionally sweeps the template and
  # all future occurrences via ApplySeriesResponse; anything else responds to this
  # one meeting only. The comment column is never touched (email replies own it).
  class RespondService < ::BaseServices::BaseCallable
    RESPONDABLE_STATUSES = MeetingParticipant::RESPONDED_STATUSES

    attr_reader :meeting, :current_user

    def initialize(meeting, current_user:)
      super()

      @meeting = meeting
      @current_user = current_user
    end

    def call(status:, scope: nil) # rubocop:disable Metrics/AbcSize
      return ServiceResult.failure(result: meeting) unless RESPONDABLE_STATUSES.include?(status)
      return ServiceResult.failure(result: meeting) unless meeting.respondable_by?(current_user)

      participant = meeting.participants.invited.find_by!(user: current_user)
      stamp = Time.current

      if scope == "series" && meeting.recurring?
        apply_to_series(participant, status, stamp)
      else
        apply_to_meeting(participant, status, stamp)
      end

      ServiceResult.success(result: participant.reload)
    end

    private

    def apply_to_meeting(participant, status, stamp)
      participant.update!(participation_status: status,
                          participation_responded_at: stamp)

      Meetings::SendParticipationDigestJob.schedule(meeting, since: stamp)
    end

    # The sweep itself is future-only, but the responded-on occurrence may already
    # have started (in_progress is respondable) — its row rides along explicitly.
    # The helper handles locking, atomicity, and the digest enqueue.
    def apply_to_series(participant, status, stamp)
      ApplySeriesResponse
        .new(series: meeting.recurring_meeting, user: current_user)
        .call(status:, stamp:, only_awaiting: false, also: participant)
    end
  end
end
