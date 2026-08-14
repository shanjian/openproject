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

module Meetings
  # Batched digest of participant responses, mailed to the meeting's author.
  # The first response in a burst opens a 10-minute window (the caller passes the
  # stamp it just wrote as `since:`); further responses within the window are
  # dropped by the concurrency guard, so one mail covers them all.
  #
  # The target is the top-level object — the RecurringMeeting for occurrences, the
  # Meeting itself for one-offs — which is what collapses a series-wide email reply
  # touching N occurrence rows into a single digest.
  class SendParticipationDigestJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    # Target deleted before delivery — nothing left to report
    discard_on ActiveJob::DeserializationError

    CONCURRENCY_KEY_BASE = "Meetings::SendParticipationDigestJob-"

    good_job_control_concurrency_with(
      enqueue_limit: 1,
      key: -> { self.class.unique_key(arguments.first) }
    )

    RESPONDED_STATUSES = %w[accepted declined tentative].freeze

    def self.delete_jobs(target)
      GoodJob::Job.where(finished_at: nil, concurrency_key: unique_key(target)).delete_all
    end

    # Class-qualified: Meeting and RecurringMeeting ids can collide
    def self.unique_key(target)
      "#{CONCURRENCY_KEY_BASE}#{target.class.name}-#{target.id}"
    end

    def perform(target, since:)
      return if obsolete?(target)

      author = target.author
      return if author.nil? || author.locked?
      return unless author_opted_in?(author)

      responses = collect_responses(target, since)
      return if responses.empty?

      MeetingMailer.participation_digest(target, author, responses).deliver_now
    end

    private

    # Belt for jobs already past the queue when the meeting was cancelled or the
    # series ended; CancelService/EndService additionally delete pending jobs by
    # concurrency key. (Deletion of the target is covered by discard_on.)
    def obsolete?(target)
      (target.is_a?(Meeting) && target.cancelled?) ||
        (target.is_a?(RecurringMeeting) && target.has_ended?)
    end

    def collect_responses(target, since)
      MeetingParticipant
        .invited
        .where(participation_status: RESPONDED_STATUSES)
        .where(participation_responded_at: since..)
        .where.not(user_id: target.author_id)
        .where(meeting_id: target_meeting_ids(target))
        .includes(:user, :meeting)
        .to_a
    end

    def target_meeting_ids(target)
      if target.is_a?(RecurringMeeting)
        # Template plus every occurrence of the series
        Meeting.where(recurring_meeting_id: target.id).select(:id)
      else
        target.id
      end
    end

    # The digest is the author's personal mail — governed by their global
    # meeting_responses setting, not by the org-level notify? mute toggle.
    # Global rows only, as with meeting_updated.
    def author_opted_in?(author)
      NotificationSetting.exists?(project_id: nil, meeting_responses: true, user_id: author.id)
    end
  end
end
