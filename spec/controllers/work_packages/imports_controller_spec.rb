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

RSpec.describe WorkPackages::ImportsController do
  shared_let(:project) { create(:project) }

  current_user { user }

  describe "GET #new" do
    context "with import_work_packages permission" do
      let(:user) do
        create(:user, member_with_permissions: {
                 project => %i[view_work_packages add_work_packages
                               manage_subtasks assign_versions import_work_packages]
               })
      end

      it "renders successfully" do
        get :new, params: { project_id: project.id }

        expect(response).to have_http_status(:ok)
      end
    end

    context "without import_work_packages permission" do
      let(:user) { create(:user, member_with_permissions: { project => %i[view_work_packages] }) }

      it "is forbidden" do
        get :new, params: { project_id: project.id }

        expect(response).to have_http_status(:forbidden)
      end
    end

    # :import_work_packages lives in the :work_package_import project module, which is opt-in per
    # project. allowed_in_project? filters permissions by the project's enabled modules before the
    # admin short-circuit, so the module -- not just the role -- guards the endpoint.
    context "when the work_package_import module is disabled for the project" do
      shared_let(:module_less_project) { create(:project, disable_modules: %i[work_package_import]) }

      context "with a user holding import_work_packages" do
        let(:user) do
          create(:user, member_with_permissions: {
                   module_less_project => %i[view_work_packages add_work_packages
                                             manage_subtasks assign_versions import_work_packages]
                 })
        end

        it "is forbidden" do
          get :new, params: { project_id: module_less_project.id }

          expect(response).to have_http_status(:forbidden)
        end
      end

      context "with an admin" do
        let(:user) { create(:admin) }

        it "is forbidden" do
          get :new, params: { project_id: module_less_project.id }

          expect(response).to have_http_status(:forbidden)
        end
      end
    end
  end

  describe "POST #preview" do
    let(:user) do
      create(:user, member_with_permissions: {
               project => %i[view_work_packages add_work_packages
                             manage_subtasks assign_versions import_work_packages]
             })
    end
    let!(:task_type) { create(:type_task, name: "Task", projects: [project]) }
    # WorkPackages::CreateContract requires a status and a priority to be assignable by default
    # (WorkPackages::SetAttributesService#set_default_status/#set_default_priority); neither is
    # seeded automatically for a fresh example, so create the "is_default" ones explicitly.
    let!(:default_status) { create(:default_status) }
    let!(:default_priority) { create(:default_priority) }

    it "renders the preview and creates no work packages" do
      expect do
        post :preview, params: { project_id: project.id, source: "# Task: Rework the sequence\n" }
      end.not_to change(WorkPackage, :count)

      expect(response).to render_template(:new)
      expect(assigns(:rows).first.errors).to be_empty
    end
  end

  describe "POST #create" do
    let(:user) do
      create(:user, member_with_permissions: {
               project => %i[view_work_packages add_work_packages
                             manage_subtasks assign_versions import_work_packages]
             })
    end

    it "creates an ImportRun, enqueues the job, and redirects to show" do
      expect do
        post :create, params: { project_id: project.id, source: "# Task: Rework the sequence\n" }
      end.to have_enqueued_job(WorkPackages::Import::CreateJob)

      run = WorkPackages::ImportRun.last
      expect(run.project).to eq(project)
      expect(run.user).to eq(user)
      expect(response).to redirect_to(project_work_packages_import_path(project, run))
    end
  end

  describe "GET #show" do
    render_views

    let(:user) do
      create(:user, member_with_permissions: {
               project => %i[view_work_packages add_work_packages
                             manage_subtasks assign_versions import_work_packages]
             })
    end
    let(:import_run) { create(:work_packages_import_run, project:, user:) }

    it "renders the run's status" do
      get :show, params: { project_id: project.id, id: import_run.id }

      expect(response).to have_http_status(:ok)
      expect(assigns(:import_run)).to eq(import_run)
    end

    it "is not found for a run from another project" do
      other_run = create(:work_packages_import_run, project: create(:project), user:)

      # ApplicationController has a top-level `rescue_from ActiveRecord::RecordNotFound { render_404 }`
      # (app/controllers/application_controller.rb:144) that is always active, even in tests, so the
      # exception never propagates to the spec -- it is rendered as a 404 response instead.
      get :show, params: { project_id: project.id, id: other_run.id }

      expect(response).to have_http_status(:not_found)
    end

    context "when the run succeeded" do
      let(:created_work_package) { create(:work_package, project:) }
      let(:import_run) do
        create(:work_packages_import_run, project:, user:, status: "succeeded",
                                          created_work_package_ids: [created_work_package.id])
      end

      it "shows the undo link only with delete_work_packages" do
        get :show, params: { project_id: project.id, id: import_run.id }
        expect(response.body).not_to include("undo")

        user_with_delete = create(:user, member_with_permissions: {
                                    project => %i[view_work_packages add_work_packages
                                                  manage_subtasks assign_versions
                                                  import_work_packages delete_work_packages]
                                  })
        allow(User).to receive(:current).and_return(user_with_delete)
        allow(controller).to receive(:current_user).and_return(user_with_delete)
        get :show, params: { project_id: project.id, id: import_run.id }
        expect(response.body).to include(I18n.t("work_packages.import.show.undo"))
      end
    end
  end
end
