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
