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

RSpec.describe "Meeting time_zone param",
               :skip_csrf,
               type: :rails_request do
  shared_let(:project) { create(:project, enabled_module_names: %i[meetings]) }
  shared_let(:user) do
    create(:user, member_with_permissions: { project => %i[view_meetings create_meetings edit_meetings] })
  end

  before { login_as user }

  describe "create" do
    it "persists an explicitly submitted time_zone (regression: meeting_params didn't permit it)" do
      post meetings_path(project),
           params: {
             project_id: project.id,
             meeting: {
               title: "Zoned meeting", project_id: project.id,
               start_date: Date.tomorrow.iso8601, start_time_hour: "09:00", duration: "1",
               time_zone: "Asia/Tokyo"
             }
           }

      meeting = Meeting.find_by(title: "Zoned meeting")
      expect(meeting).to be_present
      expect(meeting[:time_zone]).to eq("Asia/Tokyo")
    end
  end

  describe "update" do
    shared_let(:legacy_meeting) { create(:meeting, project:, author: user, time_zone: nil) }

    it "leaves a legacy NULL time_zone unchanged on an unrelated update" do
      patch project_meeting_path(project, legacy_meeting), params: { meeting: { title: "Renamed" } }

      expect(legacy_meeting.reload[:time_zone]).to be_nil
      expect(legacy_meeting.title).to eq("Renamed")
    end
  end

  # Finding 1 regression: an unresolvable submitted time_zone must be rejected as a
  # normal validation error, not crash with a NoMethodError. The create and update
  # crashes were on two different lines (parsed_start_time vs.
  # Meeting::TimeGroup#initial_time_zone_value), so both real request paths are
  # covered here: POST /meetings (the new-meeting dialog form) and PUT
  # update_details (the side-panel edit form's actual submit path - see
  # Meetings::SidePanel::DetailsFormComponent).
  describe "submitting an invalid time_zone" do
    describe "create" do
      it "is rejected as a normal validation error, not an unhandled exception " \
         "(regression: crashed in parsed_start_time)" do
        expect do
          post project_meetings_path(project),
               params: {
                 project_id: project.id,
                 meeting: {
                   title: "Bad zone meeting", project_id: project.id,
                   start_date: Date.tomorrow.iso8601, start_time_hour: "09:00", duration: "1",
                   time_zone: "Not/AZone"
                 }
               },
               as: :turbo_stream
        end.not_to raise_error

        expect(response).to have_http_status(:bad_request)
        expect(Meeting.find_by(title: "Bad zone meeting")).to be_nil
      end
    end

    describe "update (via update_details, the form's real submit path)" do
      shared_let(:existing_meeting) { create(:meeting, project:, author: user, time_zone: "Europe/Berlin") }

      it "is rejected as a normal validation error, not an unhandled exception " \
         "(regression: crashed in Meeting::TimeGroup#initial_time_zone_value on re-render)" do
        expect do
          put update_details_project_meeting_path(project, existing_meeting),
              params: { meeting: { time_zone: "Not/AZone" } },
              as: :turbo_stream
        end.not_to raise_error

        expect(response).to have_http_status(:bad_request)
        expect(existing_meeting.reload[:time_zone]).to eq("Europe/Berlin")
      end
    end
  end

  # Finding 4 regression: a series occurrence never carries a private zone - its
  # reader always delegates to the series (Meeting#time_zone, when recurring?).
  # The occurrence's own time_zone select is disabled in the form (see the
  # request spec in meetings_time_zone_field_spec.rb), but this confirms the
  # underlying read-side guarantee holds even if a value is submitted anyway.
  describe "submitting a different time_zone for a series occurrence" do
    shared_let(:recurring_meeting) { create(:recurring_meeting, project:, time_zone: "America/New_York") }
    shared_let(:occurrence) { create(:meeting, project:, author: user, recurring_meeting:) }

    it "does not change what the occurrence's time_zone reports afterward" do
      put update_details_project_meeting_path(project, occurrence),
          params: { meeting: { time_zone: "Asia/Tokyo" } },
          as: :turbo_stream

      expect(occurrence.reload.time_zone).to eq(ActiveSupport::TimeZone["America/New_York"])
    end
  end
end
