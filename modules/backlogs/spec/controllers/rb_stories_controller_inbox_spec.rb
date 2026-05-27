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

RSpec.describe RbStoriesController, "inbox drag-drop" do
  let(:project) do
    create(:project, enabled_module_names: %w[work_package_tracking backlogs])
  end
  let(:status) { create(:default_status) }
  let(:type_feature) { create(:type_feature) }
  let(:priority) { create(:priority) }
  let(:version) { create(:version, project:) }
  let(:user) do
    create(:user).tap do |u|
      create(:member,
             user: u,
             project:,
             roles: [create(:project_role,
                            permissions: %i[view_master_backlog edit_work_packages
                                            assign_versions view_work_packages])])
    end
  end

  before do
    allow(Setting).to receive(:plugin_openproject_backlogs)
      .and_return({ "story_types" => [type_feature.id.to_s], "task_type" => "0" })
    project.types << type_feature unless project.types.include?(type_feature)
    login_as user
  end

  describe "PUT #update via inbox route" do
    let(:story) do
      create(:story, project:, status:, type: type_feature, priority:, version:)
    end

    it "clears the version when version_id is blank" do
      put :update, params: { project_id: project.identifier, id: story.id, version_id: "" }

      expect(response).to have_http_status(:ok)
      expect(story.reload.version_id).to be_nil
    end

    it "sets the version when moving from inbox into a sprint" do
      story_in_inbox = create(:story, project:, status:, type: type_feature, priority:, version: nil)

      put :update,
          params: { project_id: project.identifier, id: story_in_inbox.id, version_id: version.id }

      expect(response).to have_http_status(:ok)
      expect(story_in_inbox.reload.version_id).to eq(version.id)
    end
  end
end
