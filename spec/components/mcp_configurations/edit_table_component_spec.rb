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
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

require "spec_helper"

RSpec.describe McpConfigurations::EditTableComponent, type: :component do
  def row_for(identifier)
    create(:mcp_configuration, identifier:, title: identifier.split("/").last.humanize)
  end

  def render_rows(*identifiers)
    render_inline(described_class.new(rows: identifiers.map { |identifier| row_for(identifier) }))
  end

  %w[create_work_package update_work_package create_work_package_comment].each do |tool|
    it "marks #{tool} as modifying data" do
      render_rows("tools/#{tool}")

      expect(page).to have_test_selector("mcp-configuration--modifies-data-badge", text: "Modifies data", count: 1)
    end
  end

  it "does not mark a tool that only reads" do
    render_rows("tools/search_work_packages", "tools/list_priorities", "tools/current_user")

    expect(page).to have_no_test_selector("mcp-configuration--modifies-data-badge")
  end

  it "does not mark a resource" do
    render_rows("resources/work_package")

    expect(page).to have_no_test_selector("mcp-configuration--modifies-data-badge")
  end

  it "does not mark a row whose tool is no longer registered, rather than guessing" do
    render_rows("tools/a_tool_that_was_removed")

    expect(page).to have_no_test_selector("mcp-configuration--modifies-data-badge")
  end

  it "marks only the rows that write when they are listed together" do
    render_rows("tools/search_work_packages", "tools/create_work_package", "tools/update_work_package")

    expect(page).to have_test_selector("mcp-configuration--modifies-data-badge", count: 2)
  end

  it "leaves the name of every row as it was, one per row, which the admin page's own spec counts" do
    render_rows("tools/search_work_packages", "tools/create_work_package")

    expect(page).to have_test_selector("mcp-configuration--config-row-name", count: 2)
    expect(page).to have_test_selector("mcp-configuration--config-row-name", text: "create_work_package")
  end

  it "says what the badge means, for someone who hovers over it" do
    render_rows("tools/create_work_package")

    badge = page.find("[data-test-selector='mcp-configuration--modifies-data-badge']")
    expect(badge[:title]).to include("create or change")
  end
end
