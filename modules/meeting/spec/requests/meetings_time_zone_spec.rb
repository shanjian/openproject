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
end
