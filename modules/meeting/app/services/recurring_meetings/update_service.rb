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
  class UpdateService < ::BaseServices::Update
    include WithTemplate

    protected

    def validate_params
      @old_schedule_model = model.dup
      @old_location = model.template.location
      @old_title = model.title
      super
    end

    def after_perform(call)
      return call unless call.success?

      recurring_meeting = call.result

      if should_reschedule?(recurring_meeting)
        reschedule_future_occurrences(recurring_meeting)
        reschedule_init_job(recurring_meeting)
        send_updated_mail(recurring_meeting)
      end

      cleanup_cancelled_schedules(recurring_meeting)
      update_future_occurrence_titles(recurring_meeting)

      update_template(call)
    end

    def update_template(call)
      recurring_meeting = call.result
      template = recurring_meeting.template

      unless template.update(@template_params)
        call.merge! ServiceResult.failure(result: template, errors: template.errors)
      end

      call
    end

    def reschedule_future_occurrences(recurring_meeting)
      if only_time_of_day_changed?(recurring_meeting) && !multi_instances_per_day?(recurring_meeting)
        update_time_of_day(recurring_meeting)
      else
        remove_cancelled_schedules(recurring_meeting)
        reschedule_all_occurrences(recurring_meeting)
      end
    end

    def only_time_of_day_changed?(recurring_meeting)
      changes = recurring_meeting.previous_changes.keys
      changes.include?("start_time_hour") && changes.exclude?("start_date")
    end

    ##
    # In some edit cases, we end up with multiple meetings being created
    # per day. This ensures we can reschedule them on update.
    def multi_instances_per_day?(recurring_meeting)
      recurring_meeting
        .scheduled_meetings
        .group("start_time::date")
        .having("COUNT(*) > 1")
        .exists?
    end

    def update_time_of_day(recurring_meeting)
      schedule_meetings = recurring_meeting.scheduled_meetings

      schedule_meetings.each do |scheduled|
        # Ensure we treat the start_time as a local time of the series
        start_time = scheduled.start_time.in_time_zone(recurring_meeting.time_zone)
        # so that we change the correct hour/minute
        new_time = start_time.change(
          hour: recurring_meeting.start_time.hour,
          min: recurring_meeting.start_time.min
        )

        Meeting.transaction do
          scheduled.update_column(:start_time, new_time)
          if scheduled.meeting_id.present? && scheduled.meeting.start_time.future?
            # for past meetings we do not change the time
            scheduled.meeting.update_column(:start_time, new_time)
          end
        end
      end
    end

    def remove_cancelled_schedules(recurring_meeting)
      recurring_meeting
        .scheduled_meetings
        .cancelled
        .delete_all
    end

    def reschedule_all_occurrences(recurring_meeting)
      # Get all future scheduled meetings that have been instantiated, ordered by start time
      future_meetings = recurring_meeting
        .scheduled_instances(upcoming: true)
        .instantiated
        .not_cancelled

      # Get the next occurrences from the schedule matching the number of future meetings
      next_occurrences = recurring_meeting.scheduled_occurrences(limit: future_meetings.count)

      # Update each meeting's timing to match the new schedule
      # Wrap in transaction to allow deferrable unique constraint to work
      Meeting.transaction do
        future_meetings.each_with_index do |scheduled, index|
          next_time = next_occurrences[index]&.to_time

          if next_time
            scheduled.update_column(:start_time, next_time)
            scheduled.meeting.update_column(:start_time, next_time)
          end
        end
      end
    end

    def cleanup_cancelled_schedules(recurring_meeting)
      ScheduledMeeting
        .where(recurring_meeting:)
        .cancelled
        .find_each do |scheduled|
        occurring = recurring_meeting.schedule.occurs_at?(scheduled.start_time)
        scheduled.delete unless occurring
      end
    end

    def update_future_occurrence_titles(recurring_meeting)
      new_title = @template_params[:title]
      return if new_title == @old_title

      recurring_meeting
      .scheduled_instances(upcoming: true)
      .instantiated
      .each do |scheduled|
        # update_columns (not update_column) so lock_version/updated_at bump
        # too — otherwise the propagated title is invisible to subscribed
        # calendar clients even though the in-app page shows it immediately
        # (SEQUENCE/LAST-MODIFIED on the occurrence's VEVENT derive from
        # these two fields; see icalendar_builder.rb#add_single_meeting_event
        # and #add_single_recurring_occurrence). Still skips
        # validations/callbacks like the old update_column call did — no
        # per-occurrence mail fires from this sync.
        scheduled.meeting.update_columns(
          title: new_title,
          updated_at: Time.current,
          lock_version: scheduled.meeting.lock_version + 1
        )
      end
    end

    def send_updated_mail(recurring_meeting)
      # The notify? gate moves into the job (checked at send time, not enqueue time).
      SendUpdatedNotificationJob
        .set(wait: 5.minutes)
        .perform_later(recurring_meeting,
                       actor_id: user.id,
                       old_schedule_attributes: @old_schedule_model.attributes
                                                                   .slice(*SendUpdatedNotificationJob::SCHEDULE_ATTRS),
                       old_location: @old_location)
    end

    def reschedule_init_job(recurring_meeting)
      concurrency_key = InitNextOccurrenceJob.unique_key(recurring_meeting)

      # Delete all scheduled jobs for this meeting
      GoodJob::Job.where(finished_at: nil, concurrency_key:).delete_all

      # Don't init the next meeting in draft mode
      return if recurring_meeting.template.draft?

      # Ensure we init the next meeting directly
      InitNextOccurrenceJob.perform_now(recurring_meeting, recurring_meeting.next_occurrence)
    end

    def should_reschedule?(recurring_meeting)
      return false if recurring_meeting.next_occurrence.nil?

      recurring_meeting.reschedule_required?(previous: true)
    end
  end
end
