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
end
