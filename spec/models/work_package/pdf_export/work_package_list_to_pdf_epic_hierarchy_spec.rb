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

# The exported tree must nest the same way the screen does, so a PDF of an
# epic-filtered view does not silently flatten what the Gantt showed nested.
# See docs/development/epic-hierarchy-display-design.md.
RSpec.describe WorkPackage::PDFExport::WorkPackageListToPdf do
  shared_let(:epic_type) { create(:type, name: "Epic") }
  shared_let(:task_type) { create(:type, name: "Task") }
  shared_let(:project) { create(:project, types: [epic_type, task_type]) }
  shared_let(:user) do
    create(:user, member_with_permissions: { project => %w[view_work_packages export_work_packages] })
  end

  let(:query) { build(:query, project:, user:, show_hierarchies: true) }
  let(:exporter) { described_class.new(query, {}) }

  before { login_as(user) }

  # The exporter's tree builder is the unit under test: it decides which node
  # each row hangs off. Rendering a full PDF would only obscure that.
  def tree(work_packages)
    infos_map, flat_list = exporter.send(:build_meta_infos_map, work_packages)
    {
      parent_of: work_packages.to_h do |wp|
        [wp.id, infos_map[wp.id][:parent]&.dig(:work_package)&.id]
      end,
      order: flat_list.map(&:id),
      levels: work_packages.to_h { |wp| [wp.id, infos_map[wp.id][:level_path].length] }
    }
  end

  shared_let(:epic) { create(:work_package, project:, type: epic_type, subject: "An epic") }

  context "with a parentless linked task and the epic in the export" do
    let!(:task) { create(:work_package, project:, type: task_type, epic:) }

    it "nests the task under the epic" do
      expect(tree([epic, task])[:parent_of]).to eq(epic.id => nil, task.id => epic.id)
    end

    it "puts the epic before its adopted task and one level shallower" do
      result = tree([epic, task])

      expect(result[:order]).to eq([epic.id, task.id])
      expect(result[:levels][task.id]).to be > result[:levels][epic.id]
    end
  end

  context "when the epic is not part of the export" do
    let!(:task) { create(:work_package, project:, type: task_type, epic:) }

    it "leaves the task at root level rather than inventing a row" do
      expect(tree([task])[:parent_of]).to eq(task.id => nil)
    end
  end

  context "when the linked task has a real parent" do
    shared_let(:real_parent) { create(:work_package, project:, type: task_type) }
    let!(:task) { create(:work_package, project:, type: task_type, parent: real_parent, epic:) }

    it "keeps the task under its real parent" do
      expect(tree([epic, real_parent, task])[:parent_of])
        .to eq(epic.id => nil, real_parent.id => nil, task.id => real_parent.id)
    end
  end

  context "without hierarchy mode" do
    let(:query) { build(:query, project:, user:, show_hierarchies: false) }
    let!(:task) { create(:work_package, project:, type: task_type, epic:) }

    it "does not nest anything" do
      expect(tree([epic, task])[:parent_of]).to eq(epic.id => nil, task.id => nil)
    end
  end
end
