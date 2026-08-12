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
    # type's pattern strictly after save -- the typed heading is exactly as unreliable as
    # start_date/due_date are for a row with children, and for the same reason.
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

  describe "#computed_attribute_names" do
    # Per the design's documented "computed on creation" categories: a row with at least one
    # child never keeps the start_date/due_date resolved into its `work_package`, because
    # WorkPackages::Import::CreateJob creates rows top-down and each child's creation runs
    # `multi_update_ancestors`/`reschedule_related`, silently rewriting the parent's dates once
    # the child actually exists -- regardless of what date the row was previewed with.
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
      WorkPackages::Import::Resolver::ResolvedRow.new(node: parent_node, work_package: parent_work_package,
                                                      attribute_matches: [], errors: [])
    end
    let(:child_row) do
      WorkPackages::Import::Resolver::ResolvedRow.new(node: child_node, work_package: child_work_package,
                                                      attribute_matches: [], errors: [])
    end
    let(:component) { described_class.new(rows: [parent_row, child_row]) }

    it "marks start_date and due_date as computed for a row that has a child, even with real dates set" do
      expect(component.computed_attribute_names(parent_row, 0)).to include("start_date", "due_date")
    end

    it "does not mark start_date/due_date as computed for a leaf row" do
      expect(component.computed_attribute_names(child_row, 1)).not_to include("start_date", "due_date")
    end

    it "renders the parent row's dates as computed on creation but the leaf row's as not" do
      render_inline(component)

      parent_li = page.find("li", text: "Parent row")
      expect(parent_li).to have_text("start_date: #{I18n.t('work_packages.import.preview.computed_on_creation')}")
      expect(parent_li).to have_text("due_date: #{I18n.t('work_packages.import.preview.computed_on_creation')}")

      child_li = page.find("li", text: "Child row")
      expect(child_li).to have_no_text("start_date")
      expect(child_li).to have_no_text("due_date")
    end

    it "does not also show the author's typed Start date/Finish date as exact when the row has a child" do
      # A parent row whose author explicitly wrote "Start date: ..." / "Finish date: ..." bullets
      # gets those in `attribute_matches` (the resolver's record of what it matched), in addition
      # to start_date/due_date landing in `computed_attribute_names` because the row has a child.
      # Showing both is contradictory: one line says "2026-01-01", the next says "computed on
      # creation" for the same field.
      parent_row_with_typed_dates = WorkPackages::Import::Resolver::ResolvedRow.new(
        node: parent_node, work_package: parent_work_package,
        attribute_matches: [{ label: "Start date", formatted: "2026-01-01" },
                            { label: "Finish date", formatted: "2026-01-31" }],
        errors: []
      )
      render_inline(described_class.new(rows: [parent_row_with_typed_dates, child_row]))

      parent_li = page.find("li", text: "Parent row")
      expect(parent_li).to have_no_text("Start date: 2026-01-01")
      expect(parent_li).to have_no_text("Finish date: 2026-01-31")
      expect(parent_li).to have_text("start_date: #{I18n.t('work_packages.import.preview.computed_on_creation')}")
      expect(parent_li).to have_text("due_date: #{I18n.t('work_packages.import.preview.computed_on_creation')}")
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
