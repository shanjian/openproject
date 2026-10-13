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

RSpec.describe McpTools::CreateWorkPackage, with_flag: { mcp_server: true } do
  include API::V3::Utilities::PathHelper

  subject(:mcp_request) do
    header "Authorization", "Bearer #{access_token.plaintext_token}"
    header "Content-Type", "application/json"
    post "/mcp", request_body.to_json
  end

  let(:access_token) do
    # avoid owner for application, so that we don't have additional users created
    create(:oauth_access_token, scopes: "mcp", resource_owner: user, application: create(:oauth_application, owner: nil))
  end
  let(:user) { create(:user) }
  let(:type) { create(:type) }
  let(:project) { create(:project, types: [type]) }
  let(:permissions) { %i[view_work_packages add_work_packages] }

  let(:request_body) do
    {
      jsonrpc: "2.0",
      id: "Test-Request",
      method: "tools/call",
      params: { name: "create_work_package", arguments: call_args }
    }
  end
  let(:data) do
    {
      subject: "Created by an assistant",
      _links: {
        project: { href: api_v3_paths.project(project.id) },
        type: { href: api_v3_paths.type(type.id) }
      }
    }
  end
  let(:call_args) { { data: } }
  let(:parsed_results) { JSON.parse(last_response.body).fetch("result") }
  let(:created) { WorkPackage.find_by(subject: "Created by an assistant") }

  let(:server_config) { create(:mcp_configuration, identifier: "mcp_server") }
  let(:tool_config) { create(:mcp_configuration, identifier: described_class.qualified_name) }

  before do
    create(:default_status)
    create(:default_priority)
    create(:member, project:, user:, roles: [create(:project_role, permissions:)])
    server_config.save!
    tool_config.save!
  end

  context "when the mcp_server enterprise feature is enabled", with_ee: %i[mcp_server] do
    it_behaves_like "MCP text tool"

    it "is annotated as writing, without being idempotent or destructive" do
      expect(described_class.read_annotations)
        .to include(read_only_hint: false, idempotent_hint: false, destructive_hint: false)
    end

    it "creates the work package in the project, authored by the token's user" do
      mcp_request

      expect(created).to have_attributes(project:, type:, author: user)
    end

    it "answers with the created work package, without rendered HTML or links it cannot act on" do
      mcp_request

      result = parsed_results.fetch("structuredContent")
      expect(result).to include("id" => created.id, "subject" => "Created by an assistant")
      expect(result.dig("description", "html")).to be_nil
      expect(result.fetch("_links").keys).not_to include("update", "delete")
    end

    it "marks the journal as the assistant's, written by the token's user" do
      mcp_request

      journal = created.journals.first
      expect(journal.user).to eq(user)
      expect(journal.cause).to eq("type" => "mcp", "tool" => "create_work_package")
    end

    it "subscribes the creator as a watcher, as the UI does" do
      mcp_request

      expect(created.watchers.map(&:user)).to eq([user])
    end

    context "with an assignee who can be notified" do
      let(:assignee) do
        create(:user, member_with_permissions: { project => %i[view_work_packages work_package_assigned] })
      end
      let(:data) do
        super().deep_merge(_links: { assignee: { href: api_v3_paths.user(assignee.id) } })
      end

      it "notifies them, as creating in the UI would; the assistant cannot suppress it" do
        perform_enqueued_jobs { mcp_request }

        expect(Notification.where(recipient: assignee, resource: created)).to exist
      end
    end

    context "with a payload an assistant often sends back after reading a work package" do
      let(:data) do
        super().merge(_type: "WorkPackage", id: 5, createdAt: "2020-01-01T00:00:00Z")
              .deep_merge(_links: { self: { href: "/api/v3/work_packages/5" } })
      end

      it_behaves_like "MCP tool execution error response"

      it "names the keys that are not supported, and writes nothing" do
        mcp_request

        text = parsed_results.fetch("content").first.fetch("text")
        expect(text).to include("_type", "id", "createdAt", "_links.self", "Supported:")
        expect(WorkPackage.where(subject: "Created by an assistant")).to be_empty
      end
    end

    {
      "an attachments link" => { _links: { attachments: [] } },
      "a file links link" => { _links: { fileLinks: [] } },
      "a watchers link" => { _links: { watchers: [] } },
      "an author link" => { _links: { author: { href: "/api/v3/users/1" } } },
      "meta" => { meta: { validateCustomFields: false } },
      "a typo" => { subjcet: "typo" }
    }.each do |label, extra|
      context "with #{label}" do
        let(:data) { super().deep_merge(extra) }

        it_behaves_like "MCP tool execution error response"

        it "writes nothing" do
          mcp_request

          expect(WorkPackage.where(subject: "Created by an assistant")).to be_empty
        end
      end
    end

    context "without the permission to add work packages" do
      let(:permissions) { %i[view_work_packages] }

      it_behaves_like "MCP tool execution error response"

      it "writes nothing, and says why" do
        mcp_request

        expect(WorkPackage.where(subject: "Created by an assistant")).to be_empty
        expect(parsed_results.fetch("content").first.fetch("text")).to be_present
      end
    end

    context "when the contract rejects the work package" do
      let(:data) { super().merge(startDate: "2026-11-10", dueDate: "2026-11-01", scheduleManually: true) }

      it_behaves_like "MCP tool execution error response"

      it "carries the contract's message, so the assistant can correct itself" do
        mcp_request

        expect(parsed_results.fetch("content").first.fetch("text")).to match(/date/i)
      end
    end

    context "with a link the parser cannot read" do
      let(:data) { super().deep_merge(_links: { type: { href: "not-a-link" } }) }

      it_behaves_like "MCP tool execution error response"

      it "writes nothing" do
        mcp_request

        expect(WorkPackage.where(subject: "Created by an assistant")).to be_empty
      end
    end

    {
      type: ["type", "list_types"],
      status: ["status", "list_statuses"],
      priority: ["priority", "list_priorities"]
    }.each do |link, (noun, list_tool)|
      # The core fills these in when they are empty, so an ID that does not exist would otherwise look absent:
      # the work package is created with the default and the call reports success.
      context "with a #{noun} that does not exist" do
        let(:data) do
          path = { type: api_v3_paths.type(999_999), status: api_v3_paths.status(999_999),
                   priority: api_v3_paths.priority(999_999) }.fetch(link)
          super().deep_merge(_links: { link => { href: path } })
        end

        it_behaves_like "MCP tool execution error response"

        it "refuses it instead of quietly using the default, and points to #{list_tool}" do
          mcp_request

          expect(parsed_results.fetch("content").first.fetch("text")).to include("999999", list_tool)
          expect(WorkPackage.where(subject: "Created by an assistant")).to be_empty
        end
      end
    end

    context "without a type, status or priority" do
      let(:data) { super().tap { |d| d[:_links].delete(:type) } }

      it "still gets the defaults, because leaving them out is a deliberate request for them" do
        mcp_request

        expect(created).to have_attributes(type:, status: Status.default, priority: IssuePriority.default)
      end
    end

    context "without a project" do
      let(:data) { super().tap { |d| d[:_links].delete(:project) } }

      it_behaves_like "MCP tool execution error response"
    end
  end

  context "without an Enterprise token" do
    it "still responds successfully" do
      mcp_request

      expect(last_response).to have_http_status(200)
    end
  end
end
