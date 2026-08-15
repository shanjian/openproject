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

RSpec.describe WorkPackages::Import::PreviewComponent, type: :component do
  let(:node) do
    WorkPackages::Import::OutlineParser::Node.new(level: 1, type_name: "Task", subject: "Do the thing",
                                                  attributes: {}, description: "", source_line: 1, parent_index: nil)
  end

  it "renders each row's subject" do
    row = WorkPackages::Import::Resolver::ResolvedRow.new(node:, work_package: build(:work_package, subject: "Do the thing"),
                                                          attribute_matches: [], errors: [])
    render_inline(described_class.new(rows: [row]))

    expect(page).to have_text("Do the thing")
  end

  describe "#subject_computed?" do
    # Types::ApplyPatterns#apply_patterns (create_service.rb) overwrites `subject` from the
    # type's pattern strictly after save -- the typed heading is real but not what will persist,
    # so the header shows a "computed on creation" marker instead of a misleading value.
    let(:autosubject_type) do
      create(:type, name: "Autosubject", patterns: { subject: { blueprint: "\#{{id}}", enabled: true } })
    end

    it "is true when the row's type has an enabled subject pattern" do
      row = WorkPackages::Import::Resolver::ResolvedRow.new(
        node:, work_package: build(:work_package, type: autosubject_type), attribute_matches: [], errors: []
      )
      expect(described_class.new(rows: [row]).subject_computed?(row)).to be true
    end

    it "is false when the row's type has no subject pattern" do
      row = WorkPackages::Import::Resolver::ResolvedRow.new(
        node:, work_package: build(:work_package), attribute_matches: [], errors: []
      )
      expect(described_class.new(rows: [row]).subject_computed?(row)).to be false
    end

    it "is false for a row with no resolved work_package" do
      row = WorkPackages::Import::Resolver::ResolvedRow.new(node:, work_package: nil, attribute_matches: [], errors: [])
      expect(described_class.new(rows: [row]).subject_computed?(row)).to be false
    end

    it "shows 'computed on creation' in the header instead of the typed subject" do
      row = WorkPackages::Import::Resolver::ResolvedRow.new(
        node:, work_package: build(:work_package, type: autosubject_type), attribute_matches: [], errors: []
      )
      render_inline(described_class.new(rows: [row]))

      row_li = page.find("li.work-package-import-preview--row")
      expect(row_li).to have_no_text("Do the thing")
      expect(row_li).to have_text("Task:")
      expect(row_li).to have_text(I18n.t("work_packages.import.preview.computed_on_creation"))
    end
  end

  it "renders an attribute match" do
    match = { label: "Accountable", formatted: "Jane Doe (jane.doe@example.com)" }
    row = WorkPackages::Import::Resolver::ResolvedRow.new(node:, work_package: build(:work_package),
                                                          attribute_matches: [match],
                                                          errors: [])
    render_inline(described_class.new(rows: [row]))

    expect(page).to have_text("Accountable: Jane Doe (jane.doe@example.com)")
  end

  it "renders an inline error against its source line" do
    row = WorkPackages::Import::Resolver::ResolvedRow.new(node:, work_package: nil, attribute_matches: [],
                                                          errors: [{ source_line: 5, message: "unknown type" }])
    render_inline(described_class.new(rows: [row]))

    expect(page).to have_text("Line 5: unknown type")
  end

  describe "attribute rows" do
    # The preview lists only what the author actually typed (the resolver's attribute_matches).
    # It deliberately does not surface derived_* fields or the scheduling rewrite of a parent
    # row's dates as "computed on creation" rows -- that read as noise, not information.
    let(:parent_node) do
      WorkPackages::Import::OutlineParser::Node.new(level: 1, type_name: "Objective", subject: "Parent row",
                                                    attributes: {}, description: "", source_line: 1,
                                                    parent_index: nil)
    end
    let(:child_node) do
      WorkPackages::Import::OutlineParser::Node.new(level: 2, type_name: "Task", subject: "Child row",
                                                    attributes: {}, description: "", source_line: 2,
                                                    parent_index: 0)
    end
    let(:parent_work_package) { build(:work_package, start_date: Date.new(2026, 1, 1), due_date: Date.new(2026, 1, 31)) }
    let(:child_work_package) { build(:work_package, start_date: Date.new(2026, 1, 5), due_date: Date.new(2026, 1, 10)) }
    let(:parent_row) do
      WorkPackages::Import::Resolver::ResolvedRow.new(
        node: parent_node, work_package: parent_work_package,
        attribute_matches: [{ label: "Start date", formatted: "2026-01-01" },
                            { label: "Finish date", formatted: "2026-01-31" }],
        errors: []
      )
    end
    let(:child_row) do
      WorkPackages::Import::Resolver::ResolvedRow.new(node: child_node, work_package: child_work_package,
                                                      attribute_matches: [], errors: [])
    end

    it "renders no 'computed on creation' rows for derived or date attributes" do
      render_inline(described_class.new(rows: [parent_row, child_row]))

      parent_li = page.find("li", text: "Parent row")
      expect(parent_li).to have_no_text("derived_done_ratio")
      expect(parent_li).to have_no_text("derived_estimated_hours")
      expect(parent_li).to have_no_text("derived_remaining_hours")
      expect(parent_li).to have_no_text("start_date")
      expect(parent_li).to have_no_text("due_date")
    end

    it "renders the author's typed dates as written, even for a row with children" do
      render_inline(described_class.new(rows: [parent_row, child_row]))

      parent_li = page.find("li", text: "Parent row")
      expect(parent_li).to have_text("Start date: 2026-01-01")
      expect(parent_li).to have_text("Finish date: 2026-01-31")
    end
  end

  describe "#any_errors?" do
    it "is true if any row has errors" do
      row = WorkPackages::Import::Resolver::ResolvedRow.new(node:, work_package: nil, attribute_matches: [],
                                                            errors: [{ source_line: 1, message: "x" }])
      expect(described_class.new(rows: [row]).any_errors?).to be true
    end

    it "is false if no row has errors" do
      row = WorkPackages::Import::Resolver::ResolvedRow.new(node:, work_package: build(:work_package), attribute_matches: [],
                                                            errors: [])
      expect(described_class.new(rows: [row]).any_errors?).to be false
    end
  end
end
