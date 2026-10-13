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

RSpec.describe McpTools::UpdateWorkPackage, with_flag: { mcp_server: true } do
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
  let(:permissions) { %i[view_work_packages edit_work_packages] }
  let!(:work_package) { create(:work_package, project:, type:, author: user, subject: "Original subject") }

  let(:request_body) do
    {
      jsonrpc: "2.0",
      id: "Test-Request",
      method: "tools/call",
      params: { name: "update_work_package", arguments: call_args }
    }
  end
  let(:lock_version) { work_package.reload.lock_version }
  let(:data) { { lockVersion: lock_version, subject: "Changed by an assistant" } }
  let(:wp_id) { work_package.id }
  let(:call_args) { { id: wp_id, data: } }
  let(:parsed_results) { JSON.parse(last_response.body).fetch("result") }
  let(:error_text) { parsed_results.fetch("content").first.fetch("text") }

  let(:server_config) { create(:mcp_configuration, identifier: "mcp_server") }
  let(:tool_config) { create(:mcp_configuration, identifier: described_class.qualified_name) }

  def journals = Journal.where(journable: work_package).order(:version)

  before do
    create(:default_status)
    create(:default_priority)
    create(:member, project:, user:, roles: [create(:project_role, permissions:)])
    server_config.save!
    tool_config.save!
  end

  context "when the mcp_server enterprise feature is enabled", with_ee: %i[mcp_server] do
    it_behaves_like "MCP text tool"

    it "is annotated as writing, idempotent, and as a destructive update" do
      expect(described_class.read_annotations)
        .to include(read_only_hint: false, idempotent_hint: true, destructive_hint: true)
    end

    it "changes the work package and answers with it" do
      mcp_request

      expect(work_package.reload.subject).to eq("Changed by an assistant")
      expect(parsed_results.dig("structuredContent", "subject")).to eq("Changed by an assistant")
      expect(parsed_results.dig("structuredContent", "lockVersion")).to eq(work_package.lock_version)
    end

    it "accepts the id as a string" do
      call_args[:id] = work_package.id.to_s
      mcp_request

      expect(work_package.reload.subject).to eq("Changed by an assistant")
    end

    it "marks the journal as the assistant's, and does not merge it into the person's creation journal" do
      mcp_request

      expect(journals.map(&:cause)).to eq([{}, { "type" => "mcp", "tool" => "update_work_package" }])
      expect(journals.last.user).to eq(user)
    end

    context "when nothing changes" do
      let(:data) { { lockVersion: lock_version, subject: "Original subject" } }

      it "writes no journal, so repeating an update is a no-op" do
        expect { mcp_request }.not_to change(journals, :count)
      end

      it "still answers with the work package" do
        mcp_request

        expect(parsed_results.dig("structuredContent", "subject")).to eq("Original subject")
      end
    end

    context "with a stale lockVersion" do
      let(:data) { { lockVersion: lock_version - 1, subject: "Changed by an assistant" } }

      it_behaves_like "MCP tool execution error response"

      it "writes nothing, and tells the assistant to read it again" do
        mcp_request

        expect(work_package.reload.subject).to eq("Original subject")
        expect(error_text).to match(/changed|read|lock/i)
      end
    end

    context "without a lockVersion" do
      let(:data) { { subject: "Changed by an assistant" } }

      it_behaves_like "MCP tool execution error response"

      it "writes nothing, and asks for it" do
        mcp_request

        expect(work_package.reload.subject).to eq("Original subject")
        expect(error_text).to include("lockVersion")
      end
    end

    context "with an attachments link that would replace the existing attachments" do
      let!(:attachment) { create(:attachment, container: work_package, author: user) }
      let(:data) { { lockVersion: lock_version, _links: { attachments: [] } } }

      it_behaves_like "MCP tool execution error response"

      it "refuses it, and the existing attachment is still there" do
        mcp_request

        expect(error_text).to include("_links.attachments")
        expect(Attachment.exists?(attachment.id)).to be(true)
        expect(work_package.reload.attachments).to contain_exactly(attachment)
      end
    end

    context "with a project change" do
      let(:other_project) { create(:project, types: [type]) }
      let!(:child) { create(:work_package, project:, type:, author: user, parent: work_package) }
      let(:data) { { lockVersion: lock_version, _links: { project: { href: api_v3_paths.project(other_project.id) } } } }

      before do
        move_permissions = %i[view_work_packages edit_work_packages add_work_packages move_work_packages]
        create(:member, project: other_project, user:, roles: [create(:project_role, permissions: move_permissions)])
      end

      it_behaves_like "MCP tool execution error response"

      it "refuses it: the work package, its descendants and its relations stay where they are" do
        mcp_request

        expect(error_text).to include("_links.project")
        expect(work_package.reload.project).to eq(project)
        expect(child.reload.project).to eq(project)
      end
    end

    {
      "a watchers link" => { _links: { watchers: [] } },
      "a file links link" => { _links: { fileLinks: [] } },
      "an author link" => { _links: { author: { href: "/api/v3/users/1" } } },
      "createdAt" => { createdAt: "2020-01-01T00:00:00Z" },
      "meta" => { meta: { validateCustomFields: false } },
      "a typo" => { subjcet: "typo" }
    }.each do |label, extra|
      context "with #{label}" do
        let(:data) { { lockVersion: lock_version, subject: "Changed by an assistant" }.deep_merge(extra) }

        it_behaves_like "MCP tool execution error response"

        it "writes nothing, not even the supported part" do
          mcp_request

          expect(work_package.reload.subject).to eq("Original subject")
        end
      end
    end

    {
      type: ["type", "list_types"],
      status: ["status", "list_statuses"],
      priority: ["priority", "list_priorities"]
    }.each do |link, (noun, list_tool)|
      context "with a #{noun} that does not exist" do
        let(:data) do
          path = { type: api_v3_paths.type(999_999), status: api_v3_paths.status(999_999),
                   priority: api_v3_paths.priority(999_999) }.fetch(link)
          { lockVersion: lock_version, _links: { link => { href: path } } }
        end

        it_behaves_like "MCP tool execution error response"

        it "refuses it, points to #{list_tool}, and changes nothing" do
          expect { mcp_request }.not_to(change { work_package.reload.attributes })
          expect(error_text).to include("999999", list_tool)
        end
      end
    end

    context "without the permission to edit work packages" do
      let(:permissions) { %i[view_work_packages] }

      it_behaves_like "MCP tool execution error response"

      it "changes nothing" do
        mcp_request

        expect(work_package.reload.subject).to eq("Original subject")
      end
    end

    context "with a work package the user cannot see" do
      let(:permissions) { [] }

      it_behaves_like "MCP tool execution error response"

      it "says it could not be found, rather than that it exists" do
        mcp_request

        expect(error_text).to include("could not be found")
      end
    end

    context "with an id that does not exist" do
      let(:wp_id) { 0 }

      it_behaves_like "MCP tool execution error response"
    end

    context "when a parent rolls up a change to its child's dates" do
      let!(:parent) do
        create(:work_package, project:, type:, author: user, schedule_manually: false,
                              start_date: Time.zone.today, due_date: Time.zone.today + 2)
      end
      let!(:child) do
        create(:work_package, project:, type:, author: user, parent:,
                              start_date: Time.zone.today, due_date: Time.zone.today + 3)
      end
      let(:wp_id) { child.id }
      let(:lock_version) { child.reload.lock_version }
      let(:data) { { lockVersion: lock_version, dueDate: (Time.zone.today + 10).iso8601 } }

      before { Journal.where(journable: [parent, child]).update_all(user_id: create(:user).id) }

      it "marks the child's journal, and leaves the parent's own cause, which names the child" do
        mcp_request

        expect(Journal.where(journable: child).order(:version).last.cause).to eq("type" => "mcp", "tool" => "update_work_package")
        expect(Journal.where(journable: parent).order(:version).last.cause)
          .to eq("type" => "work_package_related_changed_times", "work_package_id" => child.id)
      end
    end

    context "with an assignee who can be notified" do
      let(:assignee) do
        create(:user, member_with_permissions: { project => %i[view_work_packages work_package_assigned] })
      end
      let(:data) { { lockVersion: lock_version, _links: { assignee: { href: api_v3_paths.user(assignee.id) } } } }

      it "notifies them, as editing in the UI would" do
        perform_enqueued_jobs { mcp_request }

        expect(Notification.where(recipient: assignee, resource: work_package)).to exist
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
