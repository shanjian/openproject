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

RSpec.describe Projects::Settings::ReleasesController do
  shared_let(:user) { create(:admin) }
  shared_let(:project) { create(:project) }
  shared_let(:other_project) { create(:project) }
  shared_let(:sprint) { create(:version, project:, name: "Sprint A", kind: "sprint") }
  shared_let(:release) { create(:version, project:, name: "Release 1.0", kind: "release") }
  shared_let(:shared_release) do
    create(:version, project: other_project, name: "Shared Release", kind: "release", sharing: "system")
  end

  before { login_as(user) }

  describe "#show" do
    render_views

    before { get :show, params: { project_id: project.id } }

    it { expect(response).to have_http_status(:ok) }
    it { expect(response).to render_template("show") }

    it "lists only this project's release versions, excluding sprints and releases shared from other projects" do
      expect(assigns(:versions)).to contain_exactly(release)
    end

    it "renders the Releases page with a new-release action" do
      expect(response.body).to include("Releases")
      expect(response.body).to include(new_project_version_path(project, kind: "release"))
    end
  end

  describe "#show authorization" do
    render_views

    shared_let(:member_user) { create(:user) }

    before { login_as(member_user) }

    context "with a member holding :view_releases but not :manage_versions" do
      before do
        role = create(:project_role, permissions: %i[view_work_packages view_releases])
        create(:member, project:, principal: member_user, roles: [role])
        get :show, params: { project_id: project.id }
      end

      it { expect(response).to have_http_status(:ok) }

      it "lists the project's releases" do
        expect(assigns(:versions)).to contain_exactly(release)
      end

      it "does not offer the read-write new-release action" do
        expect(response.body).not_to include(new_project_version_path(project, kind: "release"))
      end
    end

    context "with a member holding neither :view_releases nor :manage_versions" do
      before do
        create(:member, project:, principal: member_user, roles: [create(:project_role, permissions: %i[view_work_packages])])
        get :show, params: { project_id: project.id }
      end

      it { expect(response).to have_http_status(:forbidden) }
    end
  end
end
