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
      render_views

      current_user { create(:user, member_with_permissions: { project => %i[edit_project] }) }

      it "renders the settings page" do
        get :show, params: { project_id: project.id }

        expect(response).to have_http_status(:ok)
        expect(response).to render_template :show
      end

      it "renders a switch per GitLab activity setting, reflecting its default" do
        get :show, params: { project_id: project.id }

        OpenProject::GitlabIntegration::Patches::ProjectPatch::COMMENT_SETTINGS.each do |setting, default|
          selector = "input[type=checkbox][name='gitlab_activity[#{setting}]']"
          state = default ? "[checked]" : ":not([checked])"

          expect(response.body).to have_css("#{selector}#{state}", visible: :all),
                                   "expected #{setting} to render #{default ? 'checked' : 'unchecked'}"
        end
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

  describe "POST create" do
    current_user { create(:user, member_with_permissions: { project => %i[edit_project] }) }

    it "adds a GitLab project mapping" do
      expect do
        post :create, params: {
          project_id: project.id,
          gitlab_project_mapping: { name: "Backend", gitlab_project_id: "my-group/backend", default_ref: "develop" }
        }
      end.to change(GitlabProjectMapping, :count).by(1)

      expect(response).to redirect_to(project_settings_gitlab_path(project))
      mapping = GitlabProjectMapping.find_by(project:, gitlab_project_id: "my-group/backend")
      expect(mapping.name).to eq("Backend")
      expect(mapping.default_ref).to eq("develop")
    end

    it "supports several mappings for one project" do
      post :create, params: { project_id: project.id, gitlab_project_mapping: { gitlab_project_id: "group/a" } }
      post :create, params: { project_id: project.id, gitlab_project_mapping: { gitlab_project_id: "group/b" } }

      expect(GitlabProjectMapping.where(project:).pluck(:gitlab_project_id)).to contain_exactly("group/a", "group/b")
    end
  end

  describe "PATCH update" do
    current_user { create(:user, member_with_permissions: { project => %i[edit_project] }) }

    shared_let(:mapping) { GitlabProjectMapping.create!(project:, gitlab_project_id: "group/a", default_ref: "main") }

    it "updates the mapping" do
      patch :update, params: {
        project_id: project.id,
        id: mapping.id,
        gitlab_project_mapping: { default_ref: "develop" }
      }

      expect(response).to redirect_to(project_settings_gitlab_path(project))
      expect(mapping.reload.default_ref).to eq("develop")
    end
  end

  describe "DELETE destroy" do
    current_user { create(:user, member_with_permissions: { project => %i[edit_project] }) }

    shared_let(:mapping) { GitlabProjectMapping.create!(project:, gitlab_project_id: "group/a") }

    it "removes the mapping" do
      expect do
        delete :destroy, params: { project_id: project.id, id: mapping.id }
      end.to change(GitlabProjectMapping, :count).by(-1)

      expect(response).to redirect_to(project_settings_gitlab_path(project))
    end
  end

  describe "PATCH update_activity" do
    context "as a project admin (edit_project)" do
      current_user { create(:user, member_with_permissions: { project => %i[edit_project] }) }

      # Every checkbox is paired with a hidden "0", so an unchecked box arrives
      # as "0" rather than not at all.
      it "switches the named event families off and leaves the rest on" do
        patch :update_activity, params: {
          project_id: project.id,
          gitlab_activity: {
            gitlab_comment_on_push: "0",
            gitlab_comment_on_merge_request: "1",
            gitlab_comment_on_note: "0",
            gitlab_comment_on_issue: "1"
          }
        }

        expect(response).to redirect_to(project_settings_gitlab_path(project))

        project.reload
        expect(project.gitlab_comments_on?(:push)).to be(false)
        expect(project.gitlab_comments_on?(:note)).to be(false)
        expect(project.gitlab_comments_on?(:merge_request)).to be(true)
        expect(project.gitlab_comments_on?(:issue)).to be(true)
      end
    end

    context "as a member without edit_project" do
      current_user { create(:user, member_with_permissions: { project => %i[view_project] }) }

      it "is forbidden" do
        patch :update_activity, params: {
          project_id: project.id,
          gitlab_activity: { gitlab_comment_on_push: "0" }
        }

        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
