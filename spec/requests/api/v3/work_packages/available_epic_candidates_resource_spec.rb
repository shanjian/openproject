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

RSpec.describe API::V3::WorkPackages::AvailableEpicCandidatesAPI do
  shared_let(:project1) { create(:project) }
  shared_let(:project2) { create(:project) }

  shared_let(:task_type) { create(:type_task, projects: [project1, project2]) }
  shared_let(:epic_type) { create(:type_epic, projects: [project1, project2]) }

  shared_let(:epic_in_project1) do
    create(:work_package, project: project1, type: epic_type, subject: "Epic Alpha")
  end
  shared_let(:epic_in_project2) do
    create(:work_package, project: project2, type: epic_type, subject: "Epic Beta")
  end
  shared_let(:non_epic) do
    create(:work_package, project: project1, type: task_type, subject: "Task Alpha")
  end

  shared_let(:user) { create(:admin) }

  let(:href) { "/api/v3/work_packages/available_epic_candidates" }
  let(:request) { get href }
  let(:result) do
    request
    JSON.parse last_response.body
  end
  let(:ids) { result["_embedded"]["elements"].pluck("id") }

  current_user { user }

  it "does not require a source work package id in the path" do
    request

    expect(last_response).to have_http_status(:ok)
  end

  it "returns only visible epic-target-type work packages across projects" do
    expect(ids).to contain_exactly(epic_in_project1.id, epic_in_project2.id)
  end

  it "excludes non-epic work packages" do
    expect(ids).not_to include(non_epic.id)
  end

  describe "typeahead query" do
    context "when matching by subject" do
      let(:href) { "/api/v3/work_packages/available_epic_candidates?query=Alpha" }

      it "returns only the matching epic" do
        expect(ids).to contain_exactly(epic_in_project1.id)
      end
    end

    context "when matching by id" do
      let(:href) { "/api/v3/work_packages/available_epic_candidates?query=#{epic_in_project2.id}" }

      it "returns the epic matching that id" do
        expect(ids).to include(epic_in_project2.id)
      end
    end

    context "with an undefined query value" do
      let(:href) { "/api/v3/work_packages/available_epic_candidates?query=undefined" }

      it "returns an empty collection instead of crashing" do
        request

        expect(last_response).to have_http_status(:ok)
        expect(result.dig("_embedded", "elements")).to eq([])
      end
    end
  end

  context "when no epic types exist" do
    before do
      epic_type.update_column(:name, "Renamed")
    end

    it "returns an empty collection" do
      expect(result.dig("_embedded", "elements")).to eq([])
    end
  end

  context "when the user may not add work packages in any project" do
    let(:user) { create(:user) }

    it "is forbidden" do
      request

      expect(last_response).to have_http_status(:forbidden)
    end
  end

  context "when the user may add work packages in only one project" do
    let(:user) do
      create(:user,
             member_with_permissions: { project2 => %i[view_work_packages add_work_packages] })
    end

    it "only returns epics visible to that user" do
      expect(ids).to contain_exactly(epic_in_project2.id)
    end
  end
end
