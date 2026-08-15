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
require "icalendar/tzinfo"

module Meetings
  class IcalendarBuilder
    attr_reader :builder_internal_timezone, :calendar, :all_times, :calendar_generated_for_user

    delegate :publish, to: :calendar

    def initialize(timezone:, user: User.current)
      @calendar_generated_for_user = user
      @builder_internal_timezone = timezone
      @calendar = build_icalendar
      @all_times = Hash.new { |hash, key| hash[key] = Array.new }
      @excluded_dates_cache = {}
      @instantiated_occurrences_cache = {}
      @series_cache_loaded = false
    end

    def calendar_title=(title)
      calendar.x_wr_calname = title
    end

    def add_single_meeting_event(meeting:, cancelled: false, timezone: builder_internal_timezone) # rubocop:disable Metrics/AbcSize
      calendar.event do |e|
        e.dtstart = ical_datetime(meeting.start_time, timezone:)
        e.dtend = ical_datetime(meeting.end_time, timezone:)

        e.created = meeting.created_at.utc
        e.last_modified = meeting.updated_at.utc
        e.sequence = meeting.lock_version

        url = url_helpers.meeting_url(meeting)
        e.url = url

        e.description = I18n.t(:text_meeting_ics_description, url:)
        e.summary = meeting.title

        e.uid = meeting.uid
        e.organizer = ical_organizer
        e.location = meeting.location.presence
        e.status = if cancelled
                     "CANCELLED"
                   else
                     "CONFIRMED"
                   end

        add_attendees(event: e, meeting: meeting)
      end
    end

    def add_series_event(recurring_meeting:, cancelled: false) # rubocop:disable Metrics/AbcSize
      return add_ended_series_history(recurring_meeting:, cancelled:) if recurring_meeting.has_ended?

      calendar.event do |e|
        e.uid = recurring_meeting.uid
        e.summary = recurring_meeting.title

        url = url_helpers.recurring_meeting_url(recurring_meeting)
        e.url = url
        e.description = I18n.t(:text_meeting_ics_meeting_series_description, url:)
        e.organizer = ical_organizer

        e.created = recurring_meeting.template.created_at.utc
        e.last_modified = [recurring_meeting.template.updated_at, recurring_meeting.updated_at].max.utc
        e.sequence = recurring_meeting.lock_version + recurring_meeting.template.lock_version

        e.rrule = recurring_meeting.ical_schedule.rrules.first.to_ical # We currently only have one recurrence rule
        e.dtstart = ical_datetime(recurring_meeting.current_schedule_start, timezone: recurring_meeting.time_zone)
        e.dtend = ical_datetime(recurring_meeting.current_schedule_end, timezone: recurring_meeting.time_zone)
        e.location = recurring_meeting.template.location.presence
        e.status = if cancelled
                     "CANCELLED"
                   else
                     "CONFIRMED"
                   end

        add_attendees(event: e, meeting: recurring_meeting.template)

        # Add all occurence dates to the dates set, so that we bake in all timezone rules correcly
        if recurring_meeting.end_after_never?
          all_times[recurring_meeting.time_zone].push(5.years.from_now.in_time_zone(recurring_meeting.time_zone))
        else
          all_times[recurring_meeting.time_zone].push(
            recurring_meeting.schedule.all_occurrences.max.in_time_zone(recurring_meeting.time_zone)
          )
        end

        # Add exceptions for all cancelled recurrences
        set_excluded_recurrence_dates(event: e, recurring_meeting: recurring_meeting)
      end

      # Add single events for all occurrences
      add_instantiated_occurrences(recurring_meeting: recurring_meeting)

      # add single events for leftover interim responses
      add_virtual_occurences_for_interim_responses(recurring_meeting: recurring_meeting)
    end

    def add_single_recurring_occurrence(scheduled_meeting:, cancelled: false) # rubocop:disable Metrics/AbcSize
      recurring_meeting = scheduled_meeting.recurring_meeting
      meeting = scheduled_meeting.meeting

      calendar.event do |e|
        e.uid = recurring_meeting.uid
        e.summary = recurring_meeting.title

        occurrence_url = url_helpers.meeting_url(meeting)
        e.url = occurrence_url
        e.description = I18n.t(:text_meeting_occurrence_ics_description,
                               series_url: url_helpers.recurring_meeting_url(recurring_meeting),
                               url: occurrence_url)
        e.organizer = ical_organizer

        e.created = meeting.created_at.utc
        e.last_modified = meeting.updated_at.utc
        e.sequence = meeting.lock_version

        e.recurrence_id = ical_datetime(scheduled_meeting.start_time, timezone: recurring_meeting.time_zone)
        e.dtstart = ical_datetime(meeting.start_time, timezone: recurring_meeting.time_zone)
        e.dtend = ical_datetime(meeting.end_time, timezone: recurring_meeting.time_zone)
        e.location = meeting.location.presence

        add_attendees(event: e, meeting: meeting)
        e.status = if cancelled || scheduled_meeting.cancelled?
                     "CANCELLED"
                   else
                     "CONFIRMED"
                   end
      end
    end

    # Renders history for a series that has already ended: standalone VEVENTs
    # for its past, non-cancelled instantiated occurrences (own UID each, no
    # RECURRENCE-ID/RRULE — there is no live master to attach an override to
    # once the series stops projecting future occurrences), plus one
    # CANCELLED tombstone for the series UID so a client that cached the old
    # master (and its overrides) under that UID is told it is gone.
    #
    # Filters on the *rendered* field (meeting.start_time), not
    # scheduled_meeting.start_time: the two can diverge when a single
    # occurrence's time was edited directly without its scheduled slot
    # following, and filtering on the wrong one could still emit a future
    # DTSTART for an "ended" series.
    #
    # With cancelled: true the caller is building a METHOD:CANCEL payload
    # (MeetingMailer.cancelled_series -> RecurringMeetings::ICalService
    # #generate_series -> #update_calendar_status): only the tombstone is
    # rendered then. Shipping brand-new VEVENTs under UIDs the client has
    # never seen inside a cancellation message is a protocol mismatch some
    # clients resolve by *creating* those events. The historical occurrences
    # are not flipped to CANCELLED either — they are meetings that actually
    # took place, and retroactively cancelling them would misrepresent
    # history; the tombstone already cancels the series identity itself.
    def add_ended_series_history(recurring_meeting:, cancelled: false)
      unless cancelled
        recurring_meeting
          .scheduled_meetings
          .instantiated
          .not_cancelled
          .includes(meeting: [:project])
          .select { |scheduled_meeting| scheduled_meeting.meeting.start_time <= Time.zone.now }
          .each do |scheduled_meeting|
            add_single_meeting_event(
              meeting: scheduled_meeting.meeting,
              cancelled: false,
              timezone: recurring_meeting.time_zone
            )
          end
      end

      add_series_tombstone(recurring_meeting:)
    end

    def update_calendar_status(cancelled:)
      if cancelled
        calendar.cancel
      else
        calendar.request
      end
    end

    def to_ical
      calendar.timezones.clear
      build_timezones
      calendar.to_ical
    end

    def preload_for_recurring_meetings(recurring_meetings:)
      @excluded_dates_cache = ScheduledMeeting
        .cancelled
        .where(recurring_meeting: recurring_meetings)
        .group(:recurring_meeting_id)
        .pluck(:recurring_meeting_id, "array_agg(start_time)")
        .to_h

      @instantiated_occurrences_cache = ScheduledMeeting
        .where(recurring_meeting: recurring_meetings)
        .not_cancelled
        .instantiated
        .includes(meeting: [:project], recurring_meeting: [:project])
        .group_by(&:recurring_meeting_id)

      @interim_responses_cache = RecurringMeetingInterimResponse
        .where(recurring_meeting: recurring_meetings)
        .includes(:user)
        .group_by(&:recurring_meeting_id)

      @series_cache_loaded = true
    end

    private

    def add_series_tombstone(recurring_meeting:) # rubocop:disable Metrics/AbcSize
      # Defense in depth for the "no VEVENT with a future DTSTART may be emitted
      # for an ended series" invariant: current_schedule_start is a rolling
      # cursor maintained by RecurringMeetings::SetAttributesService and should
      # never point past now once the series has ended, but the invariant is
      # stated unconditionally, so clamp rather than trust the cursor.
      tombstone_start = [recurring_meeting.current_schedule_start, Time.zone.now].min

      calendar.event do |e|
        e.uid = recurring_meeting.uid
        e.summary = recurring_meeting.title
        e.organizer = ical_organizer
        e.status = "CANCELLED"
        # +1: a naturally ended series (its schedule simply ran out, the scenario
        # SendParticipationDigestJob calls a "naturally ended series") never bumps
        # lock_version on recurring_meeting or its template -- nothing ever calls
        # .update!/.save to end it. Without the +1 this tombstone's SEQUENCE could
        # tie the last value a client already cached from the live series, and a
        # compliant client is entitled to ignore a cancellation that doesn't
        # strictly exceed what it has seen.
        e.sequence = recurring_meeting.lock_version + recurring_meeting.template.lock_version + 1
        e.last_modified = [recurring_meeting.updated_at, recurring_meeting.template.updated_at].max.utc
        e.dtstart = ical_datetime(tombstone_start, timezone: recurring_meeting.time_zone)
        e.dtend = ical_datetime(tombstone_start + recurring_meeting.template.duration.hours,
                                timezone: recurring_meeting.time_zone)

        add_attendees(event: e, meeting: recurring_meeting.template)
      end
    end

    def series_cache_loaded?
      @series_cache_loaded
    end

    def build_icalendar
      ::Icalendar::Calendar.new.tap do |calendar|
        calendar.prodid = "-//OpenProject GmbH//#{OpenProject::VERSION}//Meeting//EN"
        # REFRESH-INTERVAL is the RFC 7986 property; X-PUBLISHED-TTL is the
        # older de-facto one some clients (older Thunderbird/Lightning
        # builds) read instead — set both so refresh timing is honored
        # regardless of which one a given client supports.
        calendar.refresh_interval = 15.minutes.iso8601
        calendar.append_custom_property("X-PUBLISHED-TTL", 15.minutes.iso8601)
      end
    end

    def add_attendees(event:, meeting:, override_participation_status: {})
      meeting.participants.includes(:user).find_each do |participant|
        user = participant.user
        next unless user

        participant = override_participation_status.fetch(participant.user_id, participant)

        address = Icalendar::Values::CalAddress.new(
          "mailto:#{user.mail}",
          {
            "CN" => user.name,
            "EMAIL" => user.mail,
            "PARTSTAT" => attendee_participation_status(participant),
            "RSVP" => attendee_rsvp_needed?(participant) ? "TRUE" : nil,
            "CUTYPE" => "INDIVIDUAL",
            "ROLE" => "REQ-PARTICIPANT"
          }.compact
        )

        event.append_attendee(address)
      end
    end

    def attendee_participation_status(participant)
      return nil if participant.participation_status.nil?

      if participant.participation_needs_action?
        "NEEDS-ACTION"
      elsif participant.participation_accepted?
        "ACCEPTED"
      elsif participant.participation_declined?
        "DECLINED"
      elsif participant.participation_tentative?
        "TENTATIVE"
      elsif participant.participation_unknown?
        nil
      end
    end

    def attendee_rsvp_needed?(participant)
      calendar_generated_for_user == participant.user && participant.participation_needs_action?
    end

    def ical_datetime(time, timezone: builder_internal_timezone)
      tzid = timezone.tzinfo.canonical_identifier

      time_in_time_zone = time.in_time_zone(timezone)
      all_times[timezone] << time_in_time_zone

      Icalendar::Values::DateTime.new time_in_time_zone, "tzid" => tzid
    end

    def format_ical_offset(offset_seconds)
      hours = offset_seconds / 3600
      minutes = (offset_seconds.abs / 60) % 60
      sprintf("%<hours>+03d%<minutes>02d", hours:, minutes:)
    end

    def build_timezones # rubocop:disable Metrics/AbcSize
      all_times.each do |timezone, times|
        calendar.timezone do |tz|
          tz.tzid = timezone.tzinfo.canonical_identifier
          transitions = timezone.tzinfo.transitions_up_to(times.max + 6.months, times.min - 6.months)

          transitions.each do |tr|
            if tr.offset.dst?
              tz.daylight { |d| transition_to_component(d, tr) }
            else
              tz.standard { |s| transition_to_component(s, tr) }
            end
          end
        end
      end
    end

    def transition_to_component(component, transition)
      component.dtstart = transition.at.utc.strftime("%Y%m%dT%H%M%SZ")
      component.tzoffsetfrom = format_ical_offset(transition.previous_offset.utc_total_offset)
      component.tzoffsetto = format_ical_offset(transition.offset.utc_total_offset)
      component.tzname = transition.offset.abbreviation.to_s
    end

    def ical_organizer
      Icalendar::Values::CalAddress.new("mailto:#{ApplicationMailer.reply_to_address}", cn: Setting.app_title)
    end

    def url_helpers
      @url_helpers ||= OpenProject::StaticRouting::StaticUrlHelpers.new
    end

    # Methods for recurring meetings
    def add_instantiated_occurrences(recurring_meeting:)
      upcoming_instantiated_schedules(recurring_meeting).each do |scheduled_meeting|
        add_single_recurring_occurrence(scheduled_meeting:)
      end
    end

    def add_virtual_occurences_for_interim_responses(recurring_meeting:) # rubocop:disable Metrics/AbcSize
      interim_responses_for(recurring_meeting).each do |start_time, responses|
        # Ensure interim responses still match the meeting
        unless recurring_meeting.schedule.occurs_at?(start_time)
          warn "Interim response has start time that does not match #{recurring_meeting.id}, skipping."
          next
        end

        calendar.event do |e|
          e.uid = recurring_meeting.uid
          e.summary = recurring_meeting.title

          url = url_helpers.recurring_meeting_url(recurring_meeting)
          e.url = url
          e.description = I18n.t(:text_meeting_ics_meeting_series_description, url:)
          e.organizer = ical_organizer

          e.created = recurring_meeting.template.created_at.utc
          e.last_modified = [recurring_meeting.template.updated_at, recurring_meeting.updated_at].max.utc
          e.sequence = recurring_meeting.lock_version + recurring_meeting.template.lock_version

          e.dtstart = ical_datetime(start_time, timezone: recurring_meeting.time_zone)
          e.dtend = ical_datetime(start_time + recurring_meeting.template.duration.hours, timezone: recurring_meeting.time_zone)
          e.location = recurring_meeting.template.location.presence
          e.recurrence_id = ical_datetime(start_time, timezone: recurring_meeting.time_zone)

          add_attendees(
            event: e,
            meeting: recurring_meeting.template,
            override_participation_status: responses.index_by(&:user_id)
          )
          e.status = "CONFIRMED"
        end
      end
    end

    def set_excluded_recurrence_dates(event:, recurring_meeting:)
      event.exdate = if series_cache_loaded?
                       @excluded_dates_cache[recurring_meeting.id] || []
                     else
                       recurring_meeting
                         .scheduled_meetings
                         .cancelled
                         .pluck(:start_time)
                     end.map { ical_datetime(it, timezone: recurring_meeting.time_zone) }
    end

    def upcoming_instantiated_schedules(recurring_meeting)
      if series_cache_loaded?
        @instantiated_occurrences_cache[recurring_meeting.id] || []
      else
        recurring_meeting
          .scheduled_meetings
          .not_cancelled
          .instantiated
          .includes(meeting: [:project], recurring_meeting: [:project])
      end
    end

    def interim_responses_for(recurring_meeting)
      if series_cache_loaded?
        @interim_responses_cache[recurring_meeting.id] || []
      else
        recurring_meeting
          .recurring_meeting_interim_responses
          .includes(:user)
      end.group_by(&:start_time)
    end
  end
end
