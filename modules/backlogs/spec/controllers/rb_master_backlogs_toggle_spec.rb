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

require "rails_helper"

RSpec.describe RbMasterBacklogsController, "#toggle_include_closed" do
  shared_let(:type_feature) { create(:type_feature) }
  shared_let(:type_task) { create(:type_task) }
  shared_let(:role) { create(:project_role, permissions: %i[view_sprints view_work_packages]) }
  shared_let(:user) { create(:user) }
  current_user { user }

  let(:project) { create(:project, types: [type_feature]) }

  before do
    allow(Setting)
      .to receive(:plugin_openproject_backlogs)
      .and_return("story_types" => [type_feature.id.to_s], "task_type" => type_task.id.to_s)

    create(:member, project:, principal: user, roles: [role])
  end

  def toggle(params)
    put :toggle_include_closed, params: params.merge(project_id: project.id), format: :turbo_stream
  end

  it "persists the inbox preference and re-renders only the inbox column" do
    toggle(list_type: "inbox", include_closed: "true")

    expect(response).to have_http_status(:ok)
    expect(user.reload.backlogs_include_closed?(:inbox)).to be(true)
    expect(response).to have_turbo_stream action: "replace", target: "backlogs-inbox-component-inbox"
  end

  it "can turn the inbox preference back off" do
    user.set_backlogs_include_closed(:inbox, nil, true)

    toggle(list_type: "inbox", include_closed: "false")

    expect(response).to have_http_status(:ok)
    expect(user.reload.backlogs_include_closed?(:inbox)).to be(false)
  end

  it "persists a per-column override for a version/backlog column" do
    version = create(:version, project:)

    toggle(list_type: "backlog", column_id: version.id, include_closed: "true")

    expect(response).to have_http_status(:ok)
    expect(user.reload.backlogs_include_closed?(:backlog, version.id)).to be(true)
  end

  it "rejects an unknown list type" do
    toggle(list_type: "bogus")

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "rejects a non-inbox toggle without a column id" do
    toggle(list_type: "sprint", include_closed: "true")

    expect(response).to have_http_status(:unprocessable_entity)
  end
end
