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
require "rack/test"

RSpec.describe "API v3 gitlab branches by work package resource", content_type: :json do
  include Rack::Test::Methods
  include API::V3::Utilities::PathHelper

  shared_let(:project) { create(:project) }
  shared_let(:type) { create(:type, name: "Feature") }
  shared_let(:work_package) { create(:work_package, project:, type:, subject: "My cool WP") }

  let(:permissions) { %i[view_work_packages show_gitlab_content] }
  let(:current_user) { create(:user, member_with_roles: { project => create(:project_role, permissions:) }) }

  let(:mapping) do
    GitlabProjectMapping.create!(project:, name: "Backend", gitlab_project_id: "42", default_ref: "main")
  end

  let(:api_client) { instance_double(GitlabIntegration::APIClient) }
  let(:default_branch) { "feature/#{work_package.id}-my-cool-wp" }

  before do
    allow(User).to receive(:current).and_return(current_user)
    mapping
    GitlabUserToken.create!(user: current_user, token: "glpat-secret")
    allow(GitlabIntegration::APIClient).to receive(:new).and_return(api_client)
  end

  describe "#post" do
    let(:post_path) { api_v3_paths.gitlab_branches_by_work_package(work_package.id) }

    def post_branch(body)
      header "Content-Type", "application/json"
      post post_path, body.to_json
      last_response
    end

    context "with no branchName param" do
      it "creates the branch under the server-computed default name" do
        allow(api_client)
          .to receive(:create_branch)
          .with(gitlab_project_id: "42", branch: default_branch, ref: "main")
          .and_return(GitlabIntegration::APIClient::Response.new(status: 201, body: {}))

        response = post_branch({ mappingId: mapping.id })

        expect(response.status).to eq(201)
        expect(JSON.parse(response.body)["branch"]).to eq(default_branch)
      end
    end

    context "with a valid branchName param" do
      let(:client_branch_name) { "feature/#{work_package.id}-my-cool-wp-0809-1430" }

      it "creates the branch under the exact client-supplied name" do
        allow(api_client)
          .to receive(:create_branch)
          .with(gitlab_project_id: "42", branch: client_branch_name, ref: "main")
          .and_return(GitlabIntegration::APIClient::Response.new(status: 201, body: {}))

        response = post_branch({ mappingId: mapping.id, branchName: client_branch_name })

        expect(response.status).to eq(201)
        expect(JSON.parse(response.body)["branch"]).to eq(client_branch_name)
      end
    end

    context "with an invalid branchName param" do
      let(:client_branch_name) { "feature/#{work_package.id}-../../etc/passwd" }

      it "responds with 422 and does not contact GitLab" do
        allow(api_client).to receive(:create_branch)

        response = post_branch({ mappingId: mapping.id, branchName: client_branch_name })

        expect(response.status).to eq(422)
        expect(api_client).not_to have_received(:create_branch)
      end
    end

    context "without the show_gitlab_content permission" do
      let(:permissions) { %i[view_work_packages] }

      it "responds with 403" do
        response = post_branch({ mappingId: mapping.id })

        expect(response.status).to eq(403)
      end
    end
  end
end
