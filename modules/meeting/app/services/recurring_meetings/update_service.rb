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

    APPLY_SCOPES = %w[future all].freeze
    DETAIL_ATTRIBUTES = %i[title location duration].freeze

    def call(attributes = {}, apply_scope: "future", **keyword_attributes)
      @apply_scope = apply_scope
      super(attributes.merge(keyword_attributes))
    end

    protected

    def validate_params
      @old_schedule_model = model.dup
      @old_location = model.template.location
      @old_title = model.title
      @old_duration = model.template.duration

      return invalid_apply_scope_result unless APPLY_SCOPES.include?(@apply_scope)

      super
    end

    def before_perform(call)
      # apply_scope controls the occurrence sweep. It is not a model or
      # contract attribute and must not reach SetAttributesService.
      # WithTemplate's included before_perform is shadowed by this override, so
      # extract its template attributes explicitly before Write sets the series.
      @template_params = extract_template_params(params)
      super
    end

    def after_perform(call)
      return call unless call.success?

      recurring_meeting = call.result
      call = update_template(call)
      return call unless call.success?

      if should_reschedule?(recurring_meeting)
        reschedule_future_occurrences(recurring_meeting)
        reschedule_init_job(recurring_meeting)
        send_updated_mail(recurring_meeting)
      end

      cleanup_cancelled_schedules(recurring_meeting)
      sync_occurrence_details(recurring_meeting)

      call
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
      recurring_meeting.scheduled_meetings.each do |scheduled|
        update_scheduled_time_of_day(scheduled, recurring_meeting)
      end
    end

    def update_scheduled_time_of_day(scheduled, recurring_meeting)
      new_time = scheduled_time_of_day(scheduled, recurring_meeting)

      Meeting.transaction do
        # ScheduledMeeting has no lock_version and is not rendered as its own
        # ICS component, so a bare update_column is fine on that row.
        scheduled.update_column(:start_time, new_time)
        sync_occurrence_start_time_if_future(scheduled, new_time)
      end
    end

    def scheduled_time_of_day(scheduled, recurring_meeting)
      # Ensure we treat the start_time as a local time of the series so that we
      # change the correct hour/minute.
      scheduled.start_time
        .in_time_zone(recurring_meeting.time_zone)
        .change(hour: recurring_meeting.start_time.hour, min: recurring_meeting.start_time.min)
    end

    def sync_occurrence_start_time_if_future(scheduled, new_time)
      return unless scheduled.meeting_id.present? && scheduled.meeting.start_time.future?

      # For past meetings we do not change the time.
      sync_occurrence_start_time(scheduled.meeting, new_time)
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
            # See update_time_of_day: only the Meeting row needs the
            # calendar-visible treatment, the ScheduledMeeting row does not.
            scheduled.update_column(:start_time, next_time)
            sync_occurrence_start_time(scheduled.meeting, next_time)
          end
        end
      end
    end

    # update_columns (not update_column) so lock_version/updated_at bump too --
    # otherwise the new start time is invisible to subscribed calendar clients
    # even though the in-app page shows it immediately (SEQUENCE/LAST-MODIFIED
    # on the occurrence's VEVENT derive from these two fields; see
    # icalendar_builder.rb#add_single_meeting_event and
    # #add_single_recurring_occurrence). Still skips validations/callbacks like
    # the old update_column call did -- no per-occurrence mail fires from this
    # sweep, the series-level update mail covers it.
    def sync_occurrence_start_time(meeting, new_time)
      meeting.update_columns(
        start_time: new_time,
        updated_at: Time.current,
        lock_version: meeting.lock_version + 1
      )
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

    def sync_occurrence_details(recurring_meeting)
      detail_changes = changed_detail_attributes

      return if detail_changes.empty?

      occurrence_scopes(recurring_meeting).each do |occurrences|
        occurrences
          .instantiated
          .not_cancelled
          .reorder(nil)
          .find_in_batches(batch_size: 100) do |scheduled_batch|
            sync_occurrence_detail_batch(scheduled_batch, detail_changes)
          end
      end
    end

    def occurrence_scopes(recurring_meeting)
      return [recurring_meeting.scheduled_instances(upcoming: true)] if @apply_scope == "future"

      [
        recurring_meeting.scheduled_instances(upcoming: false),
        recurring_meeting.scheduled_instances(upcoming: true)
      ]
    end

    def changed_detail_attributes
      DETAIL_ATTRIBUTES.each_with_object({}) do |attribute, changes|
        next unless @template_params.key?(attribute)

        old_value = instance_variable_get("@old_#{attribute}")
        new_value = @template_params[attribute]
        changes[attribute] = new_value if detail_value_changed?(attribute, old_value, new_value)
      end
    end

    def detail_value_changed?(attribute, old_value, new_value)
      return old_value != new_value unless attribute == :duration
      return old_value != new_value if old_value.nil? || new_value.nil?

      old_value.to_d != new_value.to_d
    end

    def sync_occurrence_detail_batch(scheduled_batch, detail_changes)
      meeting_ids = scheduled_batch.map(&:meeting_id)

      return if meeting_ids.empty?

      # update_all avoids callbacks and per-occurrence notifications while
      # still making the change visible to calendar clients. Incrementing
      # lock_version in SQL preserves the per-row calendar cache contract
      # without issuing one write per occurrence.
      Meeting
        .where(id: meeting_ids)
        .where.not(state: [Meeting.states[:closed], Meeting.states[:cancelled]])
        .update_all(
          detail_changes.merge(
            updated_at: Time.current,
            lock_version: Arel.sql("lock_version + 1")
          )
        )
    end

    def invalid_apply_scope_result
      result = ServiceResult.success(result: model)
      result.errors.add(:apply_scope, :inclusion)
      result.success = false
      result
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
