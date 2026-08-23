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

RSpec.describe "API::V3::WorkPackages::AvailableAssigneesAPI" do
  include API::V3::Utilities::PathHelper

  it_behaves_like "available principals", :assignees, work_package_scope: true do
    let(:base_permissions) { %i[edit_work_packages view_work_packages] }
    let(:href) { api_v3_paths.available_assignees_in_work_package(work_package.id) }
  end

  describe "ordering" do
    current_user { create(:user, member_with_roles: { project => role }) }

    let(:role) { create(:project_role, permissions: %i[edit_work_packages view_work_packages]) }
    let(:assignable_role) { create(:project_role, permissions: %i[work_package_assigned]) }
    let(:project) { create(:project) }
    let(:work_package) { create(:work_package, project:) }
    let(:href) { api_v3_paths.available_assignees_in_work_package(work_package.id) }

    let!(:charlie) do
      create(:user, firstname: "Charlie", lastname: "Zulu", member_with_roles: { project => assignable_role })
    end
    let!(:alice) do
      create(:user, firstname: "Alice", lastname: "Yankee", member_with_roles: { project => assignable_role })
    end
    let!(:bob) do
      create(:user, firstname: "Bob", lastname: "Xray", member_with_roles: { project => assignable_role })
    end

    before { get href }

    it "returns assignees ordered by name, not by id/creation order" do
      names = JSON.parse(last_response.body)["_embedded"]["elements"].pluck("name")

      expect(names).to eq(["Alice Yankee", "Bob Xray", "Charlie Zulu"])
    end
  end
end
