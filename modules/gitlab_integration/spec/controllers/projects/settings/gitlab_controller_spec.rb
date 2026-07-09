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
require_module_spec_helper

RSpec.describe Projects::Settings::GitlabController do
  shared_let(:project) { create(:project, enabled_module_names: %w[work_package_tracking gitlab]) }

  # The page is gated on `edit_project` (like every other project settings page),
  # NOT on a bespoke permission — so project admins reach it with no extra setup.
  describe "GET show" do
    context "as a project admin (edit_project)" do
      current_user { create(:user, member_with_permissions: { project => %i[edit_project] }) }

      it "renders the settings page" do
        get :show, params: { project_id: project.id }

        expect(response).to have_http_status(:ok)
        expect(response).to render_template :show
      end
    end

    context "as a member without edit_project" do
      current_user { create(:user, member_with_permissions: { project => %i[view_project] }) }

      it "is forbidden" do
        get :show, params: { project_id: project.id }

        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "PATCH update" do
    current_user { create(:user, member_with_permissions: { project => %i[edit_project] }) }

    it "stores the GitLab project mapping" do
      patch :update, params: {
        project_id: project.id,
        gitlab_project_settings: { gitlab_project_id: "my-group/my-repo", default_ref: "develop" }
      }

      expect(response).to redirect_to(project_settings_gitlab_path(project))
      settings = GitlabProjectSettings.find_by(project:)
      expect(settings.gitlab_project_id).to eq("my-group/my-repo")
      expect(settings.default_ref).to eq("develop")
    end
  end
end
