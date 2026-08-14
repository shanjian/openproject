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

require "icalendar"

module AllMeetings
  class HandleICalResponseService < BaseServices::BaseCallable
    attr_reader :user

    def initialize(user:)
      @user = user
      super()
    end

    def perform
      result = ServiceResult.success

      ical_events.each do |event|
        event_result = handle_ical_event(event)
        result.merge!(event_result)
      end

      result
    rescue ArgumentError => e
      errors = ActiveModel::Errors.new(self)
      errors.add(:base, e.message)

      ServiceResult.failure(
        message: I18n.t("meeting.ical_response.update_failed"),
        errors: errors
      )
    end

    private

    def handle_ical_event(event) # rubocop:disable Metrics/AbcSize
      uid = event.uid&.value_ical
      recurrence_id = event.recurrence_id&.to_time

      # First check if the UID belongs to a single meeeting
      meeting = Meeting.visible(user).find_by(uid:)

      if meeting
        update_participation_status(meeting, event)
        return ServiceResult.success
      end

      # No single meeting found, check for a recurring meeting
      recurring_meeting = RecurringMeeting.visible(user).find_by(uid:)

      if recurring_meeting.blank?
        # No recurring meeting, we can leave
        errors = ActiveModel::Errors.new(self)
        errors.add(uid, I18n.t("meeting.ical_response.meeting_not_found"))
        return ServiceResult.failure(errors:)
      end

      if recurrence_id.nil?
        # Series-wide reply: template + future occurrences still awaiting a
        # response, in one locked transaction (shared with the in-app path)
        apply_series_response(recurring_meeting, event)

        return ServiceResult.success
      end

      # We do have a recurrence ID, so we need to find the scheduled meeting
      scheduled_meeting = recurring_meeting.scheduled_meetings.find_by(start_time: recurrence_id)

      if scheduled_meeting
        # We have an instantiated meeting, so update that one
        update_participation_status(scheduled_meeting.meeting, event)
      else
        # No instantiated meeting, create or update an interim response
        response = RecurringMeetingInterimResponse.find_or_initialize_by(
          user: user,
          recurring_meeting: recurring_meeting,
          start_time: recurrence_id
        )

        attendee_from_event = attendee(event)
        response.participation_status = partstat(attendee_from_event)
        response.comment = comment(attendee_from_event, event)

        response.save!
      end

      ServiceResult.success
    end

    def parsed_calendar
      @parsed_calendar ||= Icalendar::Calendar.parse(params[:ical_string]).first.tap do |calendar|
        raise ArgumentError, "No events found in the provided iCal data" if calendar&.events.blank?
        raise ArgumentError, "Invalid METHOD in iCal data" unless calendar.ip_method&.upcase == "REPLY"
      end
    end

    def ical_events
      parsed_calendar.events
    end

    def attendee(event)
      event.attendee.find { it.value_ical == "mailto:#{user.mail}" }
    end

    def partstat(attendee)
      attendee.ical_params["partstat"].first.downcase
    end

    def comment(attendee, event)
      comment = attendee.ical_params["x-response-comment"]&.first || event.comment&.first
      return if comment.blank?

      if comment.is_a?(Array)
        comment.join
      else
        comment
      end
    end

    def update_participation_status(meeting, event)
      attendee_from_event = attendee(event)

      if attendee_from_event.present?
        stamp = Time.current
        participant = meeting.participants.find_by!(user: user)
        participant.update!(
          participation_status: partstat(attendee_from_event),
          comment: comment(attendee_from_event, event),
          participation_responded_at: stamp
        )
        enqueue_digest(meeting, stamp)
      else
        log_missing_attendee(event)
      end
    end

    def apply_series_response(recurring_meeting, event)
      attendee_from_event = attendee(event)
      return log_missing_attendee(event) if attendee_from_event.nil?

      # The helper stamps rows and enqueues the digest (keyed on the series)
      # after its transaction commits
      result = MeetingParticipants::ApplySeriesResponse
        .new(series: recurring_meeting, user:)
        .call(status: partstat(attendee_from_event),
              stamp: Time.current,
              only_awaiting: true,
              comment: comment(attendee_from_event, event))

      if result.result.zero?
        # E.g. a stale invite in the sender's calendar after being removed from
        # the series — don't let the reply vanish without a trace
        Rails.logger.warn("[iCal Meeting Response] Series reply from #{user.mail} for " \
                          "#{recurring_meeting.uid} matched no participant rows")
      end
    end

    def enqueue_digest(meeting, stamp)
      Meetings::SendParticipationDigestJob.schedule(meeting, since: stamp)
    end

    def log_missing_attendee(event)
      Rails.logger.warn("[iCal Meeting Response] No attendee found for user #{user.mail} in " \
                        "event #{event.uid}#{" with recurrence ID #{event.recurrence_id.iso8601}" if event.recurrence_id}")
    end
  end
end
