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
  # Debounces "meeting updated" mails: the first edit in a burst enqueues this job
  # with the pre-edit values and a delay; further edits within the window are dropped
  # by the concurrency guard, so participants get one mail describing the overall change.
  class SendUpdatedNotificationJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    # The meeting was deleted before delivery — nothing to notify about anymore
    # (deletion sends its own cancellation mail). The actor is deliberately carried
    # as a plain id, not a GlobalID, so a deleted actor does not discard the job.
    discard_on ActiveJob::DeserializationError

    CONCURRENCY_KEY_BASE = "Meetings::SendUpdatedNotificationJob-"

    # enqueue_limit (not total_limit): a job already delivering must not block a
    # fresh edit from opening the next batching window.
    good_job_control_concurrency_with(
      enqueue_limit: 1,
      key: -> { self.class.unique_key(arguments.first) }
    )

    def self.delete_jobs(meeting)
      GoodJob::Job.where(finished_at: nil, concurrency_key: unique_key(meeting)).delete_all
    end

    def self.unique_key(meeting)
      "#{CONCURRENCY_KEY_BASE}#{meeting.id}"
    end

    def perform(meeting, actor_id:, old_values:)
      return if meeting.cancelled? || meeting.closed?

      actor = User.find_by(id: actor_id) || DeletedUser.first
      changes = old_values.symbolize_keys.merge(
        new_start: meeting.start_time,
        new_duration: meeting.duration,
        new_location: meeting.location,
        new_title: meeting.title
      )

      MeetingNotificationService
        .new(meeting)
        .call(:updated, actor:, changes:)
    end
  end
end
