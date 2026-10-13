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

RSpec.describe McpTools::ListPriorities, with_flag: { mcp_server: true } do
  subject do
    header "Authorization", "Bearer #{access_token.plaintext_token}"
    header "Content-Type", "application/json"
    post "/mcp", request_body.to_json
  end

  let(:access_token) { create(:oauth_access_token, scopes: "mcp", resource_owner: user) }
  let(:user) { create(:user) }
  let(:permissions) { %i[view_work_packages] }
  let(:request_body) do
    {
      jsonrpc: "2.0",
      id: "Test-Request",
      method: "tools/call",
      params: { name: "list_priorities", arguments: {} }
    }
  end
  let(:parsed_results) { JSON.parse(last_response.body).fetch("result") }

  let!(:priority_low) { create(:priority, name: "Low", position: 1) }
  let!(:priority_high) { create(:priority, name: "High", position: 2, active: false) }

  let(:server_config) { create(:mcp_configuration, identifier: "mcp_server") }
  let(:tool_config) { create(:mcp_configuration, identifier: described_class.qualified_name) }

  before do
    create(:member, user:, roles: [create(:project_role, permissions:)])
    server_config.save!
    tool_config.save!
  end

  context "when the mcp_server enterprise feature is enabled", with_ee: %i[mcp_server] do
    it_behaves_like "MCP text tool"

    it "lists the priorities in order, including inactive ones, which say so" do
      subject

      elements = parsed_results.dig("structuredContent", "_embedded", "elements")
      expect(elements.pluck("name")).to eq(%w[Low High])
      expect(elements.pluck("isActive")).to eq([true, false])
    end

    it "responds with a properly formatted collection" do
      subject

      expect(parsed_results.fetch("structuredContent").to_json).to match_json_schema.from_docs("priority_collection_model")
    end

    it "is annotated read-only" do
      expect(described_class.read_annotations).to include(read_only_hint: true, destructive_hint: false)
    end

    context "when the user cannot see any work package" do
      let(:permissions) { [] }

      it "lists nothing, as the API would refuse" do
        subject

        expect(parsed_results.dig("structuredContent", "_embedded", "elements")).to be_empty
      end
    end
  end

  context "without an Enterprise token" do
    it "still responds successfully" do
      subject

      expect(last_response).to have_http_status(200)
    end
  end
end
