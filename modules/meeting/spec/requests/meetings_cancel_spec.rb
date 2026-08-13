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

RSpec.describe "Meeting cancellation requests",
               :skip_csrf,
               type: :rails_request do
  shared_let(:project) { create(:project, enabled_module_names: %i[meetings]) }
  shared_let(:user) { create(:user, member_with_permissions: { project => %i[view_meetings edit_meetings] }) }
  shared_let(:viewer) { create(:user, member_with_permissions: { project => %i[view_meetings] }) }

  let(:meeting) { create(:meeting, project:, author: user, state: :open, notify: true) }
  let(:current_user) { user }

  before do
    login_as current_user
  end

  describe "GET /cancel_dialog" do
    it "renders the confirmation dialog" do
      get cancel_dialog_project_meeting_path(project, meeting), as: :turbo_stream

      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /cancel" do
    it "cancels the meeting" do
      post cancel_project_meeting_path(project, meeting), as: :turbo_stream

      expect(response).to have_http_status(:see_other).or have_http_status(:ok)
      expect(meeting.reload).to be_cancelled
    end

    context "without edit_meetings" do
      let(:current_user) { viewer }

      it "is rejected" do
        post cancel_project_meeting_path(project, meeting), as: :turbo_stream

        expect(response).to have_http_status(:forbidden)
        expect(meeting.reload).not_to be_cancelled
      end
    end
  end

  describe "visibility of cancelled meetings" do
    let(:meeting) do
      create(:meeting, project:, author: user, notify: true,
                       state: :cancelled, state_before_cancellation: Meeting.states["open"])
    end

    it "still renders the show page" do
      get project_meeting_path(project, meeting)

      expect(response).to have_http_status(:ok)
    end

    it "lists the meeting with a cancelled badge" do
      create(:meeting_participant, meeting:, user:, invited: true)

      get project_meetings_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(meeting.title)
      expect(response.body).to include("meeting-cancelled-label")
    end
  end

  describe "POST /restore" do
    let(:meeting) do
      create(:meeting, project:, author: user, notify: true,
                       state: :cancelled, state_before_cancellation: Meeting.states["open"])
    end

    it "restores the meeting" do
      post restore_project_meeting_path(project, meeting), as: :turbo_stream

      expect(response).to have_http_status(:see_other).or have_http_status(:ok)
      expect(meeting.reload).to be_open
    end

    context "without edit_meetings" do
      let(:current_user) { viewer }

      it "is rejected" do
        post restore_project_meeting_path(project, meeting), as: :turbo_stream

        expect(response).to have_http_status(:forbidden)
        expect(meeting.reload).to be_cancelled
      end
    end
  end
end
