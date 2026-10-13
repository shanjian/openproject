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

RSpec.describe McpTools::CreateWorkPackageComment, with_flag: { mcp_server: true } do
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
  let(:project) { create(:project, enabled_internal_comments: true) }
  let(:permissions) { %i[view_work_packages add_work_package_comments] }
  let!(:work_package) { create(:work_package, project:, author: user) }

  let(:request_body) do
    {
      jsonrpc: "2.0",
      id: "Test-Request",
      method: "tools/call",
      params: { name: "create_work_package_comment", arguments: call_args }
    }
  end
  let(:comment) { "A comment an assistant wrote." }
  let(:wp_id) { work_package.id }
  let(:call_args) { { work_package_id: wp_id, comment: } }
  let(:parsed_results) { JSON.parse(last_response.body).fetch("result") }
  let(:error_text) { parsed_results.fetch("content").first.fetch("text") }

  let(:server_config) { create(:mcp_configuration, identifier: "mcp_server") }
  let(:tool_config) { create(:mcp_configuration, identifier: described_class.qualified_name) }

  def journals = Journal.where(journable: work_package).order(:version)
  def commented = journals.where.not(notes: "").last

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

    it "adds the comment, written by the token's user" do
      mcp_request

      expect(commented).to have_attributes(notes: comment, user:, internal: false)
    end

    it "marks the comment as the assistant's" do
      mcp_request

      expect(commented.cause).to eq("type" => "mcp", "tool" => "create_work_package_comment")
    end

    it "answers with the comment, without rendered HTML or its change details" do
      mcp_request

      result = parsed_results.fetch("structuredContent")
      expect(result.dig("comment", "raw")).to eq(comment)
      expect(result.dig("comment", "html")).to be_nil
      expect(result.fetch("details")).to eq([])
    end

    it "accepts the id as a string" do
      call_args[:work_package_id] = work_package.id.to_s
      mcp_request

      expect(commented.notes).to eq(comment)
    end

    it "keeps the comment marked when the person edits the work package right afterwards" do
      mcp_request
      User.execute_as(user) do
        WorkPackages::UpdateService.new(user: create(:admin), model: WorkPackage.find(work_package.id)).call(subject: "Edited")
      end

      expect(commented.cause).to eq("type" => "mcp", "tool" => "create_work_package_comment")
    end

    context "with a watcher" do
      let(:watcher) { create(:user, member_with_permissions: { project => %i[view_work_packages] }) }

      before { create(:watcher, watchable: work_package, user: watcher) }

      it "notifies them, as commenting in the UI would; the assistant cannot suppress it" do
        perform_enqueued_jobs { mcp_request }

        expect(Notification.where(recipient: watcher, resource: work_package)).to exist
      end
    end

    context "with only the permission to edit work packages" do
      # The UI's comment action needs add_work_package_comments. The contract also accepts edit_work_packages,
      # so calling the service directly would let MCP comment where the UI cannot.
      let(:permissions) { %i[view_work_packages edit_work_packages] }

      it_behaves_like "MCP tool execution error response"

      it "refuses, as the UI does, and writes nothing" do
        mcp_request

        expect(error_text).to include("not allowed")
        expect(journals.where.not(notes: "")).to be_empty
      end
    end

    context "with a work package the user cannot see" do
      let(:permissions) { [] }

      it_behaves_like "MCP tool execution error response"

      it "says it could not be found" do
        mcp_request

        expect(error_text).to include("could not be found")
      end
    end

    context "with an id that does not exist" do
      let(:wp_id) { 0 }

      it_behaves_like "MCP tool execution error response"
    end

    context "with a blank comment" do
      let(:comment) { "   " }

      it_behaves_like "MCP tool execution error response"

      it "writes nothing" do
        mcp_request

        expect(journals.where.not(notes: "")).to be_empty
      end
    end

    context "with an internal comment" do
      let(:call_args) { { work_package_id: wp_id, comment:, internal: true } }
      let(:permissions) { %i[view_work_packages add_work_package_comments view_internal_comments add_internal_comments] }

      context "when the internal_comments feature is available", with_ee: %i[mcp_server internal_comments] do
        it "adds it as an internal comment" do
          mcp_request

          expect(commented).to have_attributes(notes: comment, internal: true)
        end

        it "still marks it as the assistant's" do
          mcp_request

          expect(commented.cause).to include("type" => "mcp")
        end

        context "when it mentions someone who cannot read internal comments" do
          let(:outsider) do
            create(:user, firstname: "Olivia", lastname: "Outsider",
                          member_with_permissions: { project => %i[view_work_packages] })
          end
          let(:comment) do
            mention = %(<mention class="mention" data-id="#{outsider.id}" data-type="user" data-text="@Olivia Outsider">)
            "Please look, #{mention}@Olivia Outsider</mention>."
          end

          it "turns the mention into plain text, as the UI does, so they are not pulled into it" do
            mcp_request

            expect(commented.notes).not_to include("<mention")
            expect(commented.notes).to include("@Olivia Outsider")
          end
        end

        context "without the permission to add internal comments" do
          let(:permissions) { %i[view_work_packages add_work_package_comments view_internal_comments] }

          it_behaves_like "MCP tool execution error response"

          it "writes nothing" do
            mcp_request

            expect(journals.where.not(notes: "")).to be_empty
          end
        end
      end

      context "when the internal_comments feature is not available" do
        it_behaves_like "MCP tool execution error response"

        it "writes nothing" do
          mcp_request

          expect(journals.where.not(notes: "")).to be_empty
        end
      end
    end

    context "with a public comment that mentions someone" do
      let(:other) { create(:user, member_with_permissions: { project => %i[view_work_packages] }) }
      let(:comment) do
        %(<mention class="mention" data-id="#{other.id}" data-type="user" data-text="@#{other.name}">@#{other.name}</mention> hi)
      end

      it "leaves the mention alone; only internal comments are sanitized" do
        mcp_request

        expect(commented.notes).to include("<mention")
      end
    end
  end

  context "without an Enterprise token" do
    it "still responds successfully" do
      mcp_request

      expect(last_response).to have_http_status(200)
    end
  end
end
