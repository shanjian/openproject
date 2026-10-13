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

RSpec.describe Journal::CausedByMcp do
  described_class::TOOLS.each do |tool|
    it "stores #{tool} as an origin cause" do
      cause = described_class.new(tool:)

      expect(cause.to_hash).to eq("type" => "mcp", "tool" => tool)
      expect(Journal.origin_cause?(cause)).to be(true)
    end
  end

  it "accepts the tool name as a symbol" do
    expect(described_class.new(tool: :update_work_package).to_hash).to include("tool" => "update_work_package")
  end

  it "refuses a tool that does not write, since the name is stored and used to pick a translation" do
    expect { described_class.new(tool: "search_work_packages") }.to raise_error(ArgumentError, /Unknown MCP tool/)
  end

  it "is not blank, so it is recorded" do
    expect(described_class.new(tool: "create_work_package")).not_to be_blank
  end

  it "names every tool the MCP server registers for writing" do
    # Keep the closed list in step with the registered write tools (see config/initializers/mcp.rb).
    registered = McpTools.all.reject { |tool| tool.read_annotations[:read_only_hint] }.map(&:name)

    expect(described_class::TOOLS).to match_array(registered)
  end
end
