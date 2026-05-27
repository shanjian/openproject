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
require_relative "../support/pages/backlogs"

RSpec.describe "Inbox column in master backlog", :js, :selenium do
  let!(:story_type) { create(:type_feature) }
  let!(:bug_type) { create(:type_bug) }
  let!(:task_type) { create(:type_task) }
  let!(:project) do
    create(:project,
           types: [story_type, bug_type, task_type],
           enabled_module_names: %w[work_package_tracking backlogs])
  end
  let!(:priority) { create(:default_priority) }
  let!(:default_status) { create(:status, is_default: true) }
  let!(:sprint) do
    create(:version,
           project:,
           version_settings_attributes: [{ project:, display: VersionSetting::DISPLAY_LEFT }])
  end
  let(:role) do
    create(:project_role,
           permissions: %i[view_master_backlog view_work_packages edit_work_packages assign_versions])
  end
  let!(:current_user) do
    create(:user, member_with_roles: { project => role })
  end
  let!(:unassigned_story) do
    create(:work_package, project:, type: story_type, status: default_status, version: nil, subject: "Unassigned story")
  end
  let!(:unassigned_bug) do
    create(:work_package, project:, type: bug_type, status: default_status, version: nil, subject: "Unassigned bug")
  end
  let!(:sprint_story) do
    create(:work_package, project:, type: story_type, status: default_status, version: sprint, subject: "Sprint story")
  end
  let(:backlogs_page) { Pages::Backlogs.new(project) }

  before do
    allow(Setting).to receive(:plugin_openproject_backlogs)
      .and_return("story_types" => [story_type.id.to_s], "task_type" => task_type.id.to_s)
    login_as current_user
  end

  it "shows work packages without a version in the inbox, regardless of type" do
    backlogs_page.visit!

    expect(page).to have_css("#backlog_inbox")

    within "#backlog_inbox" do
      expect(page).to have_css("#story_#{unassigned_story.id}")
      expect(page).to have_css("#story_#{unassigned_bug.id}")
      expect(page).to have_no_css("#story_#{sprint_story.id}")
    end
  end

  it "is rendered before the sprint and owner backlog columns" do
    backlogs_page.visit!

    container_ids = page.all("#backlogs_container > div", visible: :all).pluck(:id)
    expect(container_ids).to eq(%w[inbox_container owner_backlogs_container sprint_backlogs_container])
  end

  it "shows an empty-state message when nothing is unassigned" do
    unassigned_story.update_columns(version_id: sprint.id)
    unassigned_bug.update_columns(version_id: sprint.id)

    backlogs_page.visit!

    within "#backlog_inbox" do
      expect(page).to have_content(I18n.t("backlogs.inbox.empty"))
    end
  end
end
