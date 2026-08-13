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
  # Debounced "series schedule updated" mails, the series-side counterpart of
  # Meetings::SendUpdatedNotificationJob. Carries the pre-edit schedule as a plain
  # attributes snapshot because the transient old-schedule model cannot ride
  # through GlobalID serialization.
  class SendUpdatedNotificationJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    # See Meetings::SendUpdatedNotificationJob: series deleted → drop; actor rides
    # as a plain id so a deleted actor does not discard the job.
    discard_on ActiveJob::DeserializationError

    CONCURRENCY_KEY_BASE = "RecurringMeetings::SendUpdatedNotificationJob-"

    good_job_control_concurrency_with(
      enqueue_limit: 1,
      key: -> { self.class.unique_key(arguments.first) }
    )

    # String column names: ActiveRecord#attributes returns string keys, so a symbol
    # list would slice to an empty snapshot and the old schedule would render blank.
    # "weekday" is sliced defensively: the column ships with the monthly nth-weekday
    # feature branch, and Hash#slice simply skips keys that don't exist yet.
    SCHEDULE_ATTRS = %w[frequency interval start_time end_after end_date iterations
                        time_zone title weekdays schedule_mode month_day week_ordinal weekday].freeze

    def self.delete_jobs(series)
      GoodJob::Job.where(finished_at: nil, concurrency_key: unique_key(series)).delete_all
    end

    def self.unique_key(series)
      "#{CONCURRENCY_KEY_BASE}#{series.id}"
    end

    def perform(series, actor_id:, old_schedule_attributes:, old_location:) # rubocop:disable Metrics/AbcSize
      # Guard against jobs already past the queue when the series was ended;
      # the destructive services additionally delete pending jobs by concurrency key.
      return if series.has_ended?
      return unless series.notify?

      actor = User.find_by(id: actor_id) || DeletedUser.first
      old_schedule_model = RecurringMeeting.new(old_schedule_attributes.slice(*SCHEDULE_ATTRS))

      each_opted_in_participant(series) do |participant|
        # Render the old schedule in the participant's locale
        old_schedule = User.execute_as(participant.user) do
          old_schedule_model.full_schedule_in_words
        end

        MeetingSeriesMailer.updated(
          series,
          participant.user,
          actor,
          changes: { old_schedule:, old_location: }
        ).deliver_now
      rescue StandardError => e
        Rails.logger.error do
          "Failed to deliver series update for ##{series.id} to #{participant.user.mail}: #{e.message}"
        end
      end
    end

    private

    def each_opted_in_participant(series, &)
      participants = series.template.participants.invited

      # Series update mail is still "update" mail: skip recipients who globally
      # opted out. Global rows only — see MeetingNotificationService#opted_in_user_ids.
      opted_in = NotificationSetting
        .where(project_id: nil, meeting_updated: true, user_id: participants.select(:user_id))
        .pluck(:user_id)

      participants.includes(:user).find_each do |participant|
        next unless opted_in.include?(participant.user_id)

        yield participant
      end
    end
  end
end
