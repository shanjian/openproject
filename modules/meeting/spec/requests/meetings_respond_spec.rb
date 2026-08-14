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

RSpec.describe "Meeting respond requests",
               :skip_csrf,
               type: :rails_request do
  shared_let(:project) { create(:project, enabled_module_names: %i[meetings]) }
  shared_let(:user) { create(:user, member_with_permissions: { project => %i[view_meetings] }) }

  let(:meeting) { create(:meeting, project:, state: :open) }
  let!(:participant) { create(:meeting_participant, meeting:, user:, invited: true) }
  let(:current_user) { user }

  before do
    login_as current_user
  end

  describe "POST /respond" do
    it "records the response and streams the participants section" do
      post respond_project_meeting_path(project, meeting, status: "accepted"), as: :turbo_stream

      expect(response).to have_http_status(:ok)
      expect(participant.reload).to be_participation_accepted
    end

    it "closes the scope dialog and confirms with a flash" do
      post respond_project_meeting_path(project, meeting, status: "accepted"), as: :turbo_stream

      expect(response.body).to include("closeDialog")
      expect(response.body).to include("op-primer-flash-message")
    end

    it "renders an error for non-participants" do
      participant.destroy!

      post respond_project_meeting_path(project, meeting, status: "accepted"), as: :turbo_stream

      expect(response.body).to include("op-primer-flash-message")
    end

    context "without view_meetings" do
      let(:current_user) { create(:user) }

      it "is rejected" do
        post respond_project_meeting_path(project, meeting, status: "accepted"), as: :turbo_stream

        expect(response).to have_http_status(:not_found).or have_http_status(:forbidden)
        expect(participant.reload).to be_participation_needs_action
      end
    end

    context "on a recurring occurrence with scope=series" do
      let(:series) do
        create(:recurring_meeting,
               project:,
               start_time: 1.week.ago.beginning_of_day + 10.hours,
               frequency: "daily", interval: 1,
               end_after: "specific_date", end_date: 1.month.from_now)
      end
      let(:meeting) do
        create(:scheduled_meeting, :persisted,
               recurring_meeting: series,
               start_time: 2.days.from_now.beginning_of_day + 10.hours).meeting
      end
      let!(:template_participant) do
        create(:meeting_participant, meeting: series.template, user:, invited: true)
      end

      it "updates the whole series" do
        post respond_project_meeting_path(project, meeting, status: "declined", scope: "series"),
             as: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(participant.reload).to be_participation_declined
        expect(template_participant.reload).to be_participation_declined
      end
    end
  end

  describe "GET /respond_dialog" do
    let(:series) do
      create(:recurring_meeting,
             project:,
             start_time: 1.week.ago.beginning_of_day + 10.hours,
             frequency: "daily", interval: 1,
             end_after: "specific_date", end_date: 1.month.from_now)
    end
    let(:meeting) do
      create(:scheduled_meeting, :persisted,
             recurring_meeting: series,
             start_time: 2.days.from_now.beginning_of_day + 10.hours).meeting
    end

    it "renders the scope dialog" do
      get respond_dialog_project_meeting_path(project, meeting, status: "accepted"), as: :turbo_stream

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("scope")
    end
  end
end
