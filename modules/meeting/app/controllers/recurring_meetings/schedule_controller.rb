# frozen_string_literal: true

module RecurringMeetings
  class ScheduleController < ApplicationController
    around_action :with_user_time_zone
    before_action :require_login, :build_meeting
    no_authorization_required! :humanize_schedule

    def humanize_schedule
      respond_to do |format|
        format.html { render plain: @recurring_meeting.human_frequency_schedule }
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.update(
              "recurring-meeting-frequency-schedule",
              render_to_string(RecurringMeetings::SchedulePreviewComponent.new(meeting: @recurring_meeting),
                               layout: false)
            ),
            turbo_stream.update("meeting_preset", preset_options_html)
          ]
        end
      end
    end

    private

    def with_user_time_zone(&)
      User.execute_as(User.current, &)
    end

    def build_meeting
      @recurring_meeting = RecurringMeeting.new(schedule_params.compact_blank)
      # Expands preset/schedule_mode_option and normalizes weekdays so the
      # preview reflects what would actually be saved.
      @recurring_meeting.validate
    end

    def preset_options_html
      selected = @recurring_meeting.preset

      view_context.safe_join(
        RecurringMeeting::Preset.options_for(@recurring_meeting).map do |value, label|
          view_context.tag.option(label, value:, selected: value == selected)
        end
      )
    end

    def schedule_params
      params.expect(meeting: [:start_date, :start_time_hour, :frequency, :interval, :time_zone,
                              :end_after, :end_date, :iterations, :preset, :schedule_mode_option,
                              :schedule_mode, :month_day, :week_ordinal, :weekday,
                              { weekdays: [] }])
    end
  end
end
