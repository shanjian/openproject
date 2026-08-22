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

RSpec.describe Query::Results, "Epic filter integration" do
  shared_let(:epic_type) { create(:type, name: "Epic") }
  shared_let(:task_type) { create(:type, name: "Task") }

  shared_let(:project) { create(:project, types: [epic_type, task_type]) }
  shared_let(:other_project) { create(:project, types: [epic_type, task_type]) }

  shared_let(:user) do
    create(:user,
           member_with_permissions: {
             project => [:view_work_packages],
             other_project => [:view_work_packages]
           })
  end

  shared_let(:epic) { create(:work_package, project:, type: epic_type, subject: "Social Media KPI Sync") }
  shared_let(:linked_task) { create(:work_package, project:, type: task_type, epic: epic) }
  shared_let(:unrelated_task) { create(:work_package, project:, type: task_type) }
  shared_let(:other_epic) { create(:work_package, project:, type: epic_type, subject: "Other epic") }

  let(:query) do
    build(:query, user:, project:).tap do |q|
      q.filters.clear
      q.add_filter("epic", operator, [epic.id.to_s])
    end
  end
  let(:query_results) { described_class.new(query) }

  before { login_as user }

  context "with the equals operator" do
    let(:operator) { "=" }

    it "returns the epic itself alongside its linked children" do
      expect(query_results.work_packages).to contain_exactly(epic, linked_task)
    end
  end

  context "with the cross-project operator" do
    let(:operator) { "cross_project=" }

    shared_let(:cross_project_task) do
      create(:work_package, project: other_project, type: task_type, epic: epic)
    end

    it "returns the epic itself alongside its linked children from every visible project" do
      expect(query_results.work_packages).to contain_exactly(epic, linked_task, cross_project_task)
    end
  end

  context "with the not-equals operator" do
    let(:operator) { "!" }

    it "excludes both the epic itself and its linked children" do
      expect(query_results.work_packages).to contain_exactly(unrelated_task, other_epic)
    end
  end

  context "when the epic lives outside the query's project" do
    let(:operator) { "cross_project=" }
    let(:query) do
      build(:query, user:, project: other_project).tap do |q|
        q.filters.clear
        q.add_filter("epic", operator, [epic.id.to_s])
      end
    end

    it "still returns the epic itself so it can anchor the timeline" do
      expect(query_results.work_packages).to contain_exactly(epic, linked_task)
    end
  end
end
