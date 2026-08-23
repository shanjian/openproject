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

# An epic is not the parent of the work packages that link it, so the table used
# to show an epic's work but never the epic above it. The table displays a work
# package with no parent under the epic it links, which is scoped to the rows on
# the page. See docs/development/epic-hierarchy-display-design.md.
RSpec.describe "Work package table hierarchy with epic links", :js do
  shared_let(:epic_type) { create(:type, name: "Epic") }
  shared_let(:task_type) { create(:type, name: "Task") }
  shared_let(:project) { create(:project, types: [epic_type, task_type]) }
  shared_let(:user) do
    create(:user, member_with_permissions: { project => %i[view_work_packages edit_work_packages] })
  end

  shared_let(:epic) { create(:work_package, project:, type: epic_type, subject: "Social Media KPI Sync") }

  let(:wp_table) { Pages::WorkPackagesTable.new(project) }
  let(:hierarchy) { Components::WorkPackages::Hierarchies.new }

  def hierarchy_query
    build(:query, user:, project:).tap do |query|
      query.column_names = %w[id subject type]
      query.sort_criteria = [%w(id asc)]
      query.show_hierarchies = true
      query.filters.clear
      query.save!
    end
  end

  before { login_as user }

  context "with a parentless linked work package" do
    shared_let(:linked_task) do
      create(:work_package, project:, type: task_type, subject: "Sync twitter channel", epic:)
    end

    it "displays the task under the epic" do
      wp_table.visit_query hierarchy_query
      wp_table.expect_work_package_listed(epic, linked_task)

      # The epic gains a hierarchy indicator: it now heads a group.
      hierarchy.expect_hierarchy_at(epic)
      hierarchy.expect_leaf_at(linked_task)
      wp_table.expect_work_package_order(epic.id, linked_task.id)
    end

    it "collapses and expands the epic's group like any other" do
      wp_table.visit_query hierarchy_query
      wp_table.expect_work_package_listed(epic, linked_task)

      hierarchy.toggle_row(epic)
      hierarchy.expect_hidden(linked_task)

      hierarchy.toggle_row(epic)
      wp_table.expect_work_package_listed(epic, linked_task)
    end

    it "flattens again when hierarchy mode is switched off" do
      wp_table.visit_query hierarchy_query
      wp_table.expect_work_package_listed(epic, linked_task)

      hierarchy.disable_hierarchy
      hierarchy.expect_no_hierarchies
      wp_table.expect_work_package_listed(epic, linked_task)
    end
  end

  context "when the linked work package has a real parent" do
    shared_let(:real_parent) do
      create(:work_package, project:, type: task_type, subject: "A real parent")
    end
    shared_let(:linked_task) do
      create(:work_package, project:, type: task_type, subject: "Parented and linked",
                            parent: real_parent, epic:)
    end

    it "keeps it under its real parent, not under the epic" do
      wp_table.visit_query hierarchy_query
      wp_table.expect_work_package_listed(epic, real_parent, linked_task)

      hierarchy.expect_hierarchy_at(real_parent)
      hierarchy.expect_leaf_at(linked_task)
      # The epic heads nothing, so it stays a leaf row.
      hierarchy.expect_leaf_at(epic)
    end
  end

  context "when the linked work package's real parent is invisible to the user" do
    shared_let(:other_project) { create(:project, types: [task_type]) }
    shared_let(:invisible_parent) do
      create(:work_package, project: other_project, type: task_type, subject: "Hidden parent")
    end
    shared_let(:linked_task) do
      create(:work_package, project:, type: task_type, subject: "Child of a hidden parent",
                            parent: invisible_parent, epic:)
    end

    # The parent link is empty for an invisible parent exactly as it is for no
    # parent. Adopting here would assert a hierarchy that does not exist.
    it "leaves it at root level rather than adopting it into the epic" do
      wp_table.visit_query hierarchy_query
      wp_table.expect_work_package_listed(epic, linked_task)

      hierarchy.expect_leaf_at(epic, linked_task)
    end
  end

  context "when pagination separates the epic from its linked work package" do
    shared_let(:linked_task) do
      create(:work_package, project:, type: task_type, subject: "On another page", epic:)
    end

    before { allow(Setting).to receive(:per_page_options).and_return "1, 20, 100" }

    # Nesting is page-local: the filter guarantees the epic is in the result set,
    # not that it lands on the same page.
    it "renders the epic flat on its own page, and nested once both share one" do
      query = hierarchy_query

      wp_table.visit_with_params("query_id=#{query.id}&query_props=#{{ pp: 1, pa: 1 }.to_json}")
      wp_table.expect_work_package_listed(epic)
      hierarchy.expect_leaf_at(epic)

      wp_table.visit_with_params("query_id=#{query.id}&query_props=#{{ pp: 20, pa: 1 }.to_json}")
      wp_table.expect_work_package_listed(epic, linked_task)
      hierarchy.expect_hierarchy_at(epic)
    end
  end

  context "with an epic and ordinary work packages that link nothing" do
    shared_let(:unrelated) do
      create(:work_package, project:, type: task_type, subject: "Unrelated work")
    end

    it "changes nothing about the ordinary rows" do
      wp_table.visit_query hierarchy_query
      wp_table.expect_work_package_listed(epic, unrelated)

      hierarchy.expect_leaf_at(epic, unrelated)
    end
  end
end
