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

require "spec_helper"

# The meeting create/edit form is only ever rendered as a turbo-stream dialog
# fragment (MeetingsController#new/#edit have no HTML templates), so these
# specs hit the dialog-rendering actions with `as: :turbo_stream` rather than
# a plain `get` on the "new" page.
RSpec.describe "Meeting time_zone select field",
               :skip_csrf,
               type: :rails_request do
  shared_let(:project) { create(:project, enabled_module_names: %i[meetings]) }
  shared_let(:user) do
    create(:user,
           preferences: { time_zone: "Asia/Tokyo" },
           member_with_permissions: { project => %i[view_meetings create_meetings edit_meetings] })
  end

  before { login_as user }

  # Note: the dialog's markup is delivered as a turbo-stream <template> fragment.
  # <template> contents are inert per the HTML5 spec, so Capybara's `have_select`
  # (which parses response.body as a normal document) can't see inside it -
  # hence plain string assertions against response.body here rather than
  # `have_select`/`have_css`.
  it "defaults the new one-time meeting's time zone select to the creator's profile zone" do
    get new_dialog_project_meetings_path(project), as: :turbo_stream

    expect(response.body).to include('name="meeting[time_zone]"')
    expect(response.body).to include('<option selected="selected" value="Asia/Tokyo">(UTC+09:00) Tokyo</option>')
  end

  it "defaults the new recurring meeting's time zone select to the creator's profile zone" do
    get new_dialog_project_meetings_path(project, type: "recurring"), as: :turbo_stream

    expect(response.body).to include('name="meeting[time_zone]"')
    expect(response.body).to include('<option selected="selected" value="Asia/Tokyo">(UTC+09:00) Tokyo</option>')
  end

  it "defaults an existing recurring series' time zone select to the series' own zone, " \
     "not the viewer's, and shows the mismatch banner" do
    recurring_meeting = create(:recurring_meeting, project:, time_zone: "America/New_York")

    get details_dialog_project_recurring_meeting_path(project, recurring_meeting), as: :turbo_stream

    expect(response.body).to include('name="meeting[time_zone]"')
    expect(response.body).to include(
      '<option selected="selected" value="America/New_York">(UTC-05:00) Eastern Time (US &amp; Canada)</option>'
    )
    expect(response.body).to include(I18n.t("recurring_meeting.time_zone_difference_banner.title"))
  end

  describe "start-time field caption on first paint (Finding 2 regression)" do
    it "reflects a standalone meeting's own stored zone, not the viewer's" do
      meeting = create(:meeting, project:, author: user, time_zone: "America/New_York",
                                 start_time: DateTime.iso8601("2026-07-01T10:00:00-04:00"))

      get details_dialog_project_meeting_path(project, meeting), as: :turbo_stream

      expect(response.body).to include("EDT")
      expect(response.body).not_to include("JST")
    end

    it "reflects a persisted recurring series' own stored zone, not the viewer's " \
       "(previously suppressed entirely by an early return for this exact case)" do
      recurring_meeting = create(:recurring_meeting, project:, time_zone: "America/New_York",
                                                     start_time: DateTime.iso8601("2026-07-01T10:00:00-04:00"))

      get details_dialog_project_recurring_meeting_path(project, recurring_meeting), as: :turbo_stream

      # Note: "JST" legitimately still appears elsewhere in the response, in the
      # unrelated time-zone-difference banner's mention of the viewer's own zone -
      # so we only assert the caption itself (the only place "EDT" can appear).
      expect(response.body).to include("EDT")
    end
  end

  describe "time zone select on a series occurrence's edit form (Finding 4 regression)" do
    it "is disabled, since the occurrence's own time_zone column is functionally unused " \
       "(the reader always delegates to the series for recurring? meetings)" do
      recurring_meeting = create(:recurring_meeting, project:, time_zone: "America/New_York")
      occurrence = create(:meeting, project:, author: user, recurring_meeting:)

      get details_dialog_project_meeting_path(project, occurrence), as: :turbo_stream

      expect(response.body).to include('name="meeting[time_zone]"')
      select_tag = response.body[/<select[^>]*name="meeting\[time_zone\]"[^>]*>/]
      expect(select_tag).to be_present
      expect(select_tag).to match(/\bdisabled="disabled"/)
    end
  end

  describe "GET fetch_timezone (the live DST-caption turbo-stream endpoint)" do
    it "reflects the selected zone's DST abbreviation, not the viewer's own zone" do
      get fetch_timezone_project_meetings_path(
        project,
        meeting: { start_date: "2026-07-01", start_time_hour: "10:00", time_zone: "America/New_York" }
      ), as: :turbo_stream

      # July is Eastern Daylight Time (EDT), not the viewer's JST.
      expect(response.body).to include("EDT")
      expect(response.body).not_to include("JST")
    end

    it "falls back to the viewer's own zone when no time_zone param is given" do
      get fetch_timezone_project_meetings_path(
        project,
        meeting: { start_date: "2026-07-01", start_time_hour: "10:00" }
      ), as: :turbo_stream

      expect(response.body).to include("JST")
    end

    it "computes the DST abbreviation in the selected zone, not the viewer's " \
       "(Finding 3 regression: the submitted date/time were parsed in the viewer's zone " \
       "before asking the selected zone for its abbreviation, which flips the answer " \
       "when the two interpretations straddle a DST transition)" do
      # 2026-03-08 is the US spring-forward day: 02:00 America/New_York becomes 03:00.
      # A naive 10:00 wall-clock entry is unambiguously EDT in New York's own zone,
      # but misinterpreting it as 10:00 Asia/Tokyo (UTC+9, no DST) first lands the
      # instant at 01:00 UTC - still 20:00 EST the previous day in New York - which
      # is the wrong side of the transition.
      get fetch_timezone_project_meetings_path(
        project,
        meeting: { start_date: "2026-03-08", start_time_hour: "10:00", time_zone: "America/New_York" }
      ), as: :turbo_stream

      expect(response.body).to include("EDT")
      expect(response.body).not_to include("EST")
    end
  end
end
