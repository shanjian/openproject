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
require_module_spec_helper

RSpec.describe GitlabIntegration::CreateBranchService do
  shared_let(:user) { create(:user) }
  shared_let(:project) { create(:project) }
  shared_let(:type) { create(:type, name: "Feature") }
  shared_let(:work_package) { create(:work_package, project:, type:, subject: "My cool WP") }

  subject(:result) { described_class.new(user:, work_package:, mapping:).call }

  let(:mapping) do
    GitlabProjectMapping.create!(project:, name: "Backend", gitlab_project_id: "42", default_ref: "main")
  end
  let(:api_client) { instance_double(GitlabIntegration::APIClient) }
  let(:expected_branch) { "feature/#{work_package.id}-my-cool-wp" }

  def response(status: nil, body: nil, network_error: nil)
    GitlabIntegration::APIClient::Response.new(status:, body:, network_error:)
  end

  before do
    allow(GitlabIntegration::APIClient).to receive(:new).and_return(api_client)
  end

  context "when no mapping is given" do
    let(:mapping) { nil }

    it "fails" do
      expect(result).to be_failure
    end
  end

  context "when a mapping is given but the user has no token" do
    it "fails" do
      expect(result).to be_failure
    end
  end

  context "when mapping and token are configured" do
    before { GitlabUserToken.create!(user:, token: "glpat-secret") }

    it "creates the branch and returns its details on 201" do
      allow(api_client)
        .to receive(:create_branch)
        .with(gitlab_project_id: "42", branch: expected_branch, ref: "main")
        .and_return(response(status: 201, body: { "web_url" => "https://gitlab.example.com/x/-/tree/#{expected_branch}" }))

      expect(result).to be_success
      expect(result.result[:branch]).to eq(expected_branch)
      expect(result.result[:web_url]).to eq("https://gitlab.example.com/x/-/tree/#{expected_branch}")
      expect(result.result[:already_existed]).to be(false)
      expect(result.result[:repository]).to eq("Backend")
      expect(result.result[:mapping_id]).to eq(mapping.id)
    end

    it "treats a 400 'already exists' as a success" do
      allow(api_client)
        .to receive(:create_branch)
        .and_return(response(status: 400, body: { "message" => "Branch already exists" }))

      expect(result).to be_success
      expect(result.result[:already_existed]).to be(true)
    end

    it "fails on 401/403" do
      allow(api_client).to receive(:create_branch).and_return(response(status: 401))

      expect(result).to be_failure
    end

    it "fails on 404" do
      allow(api_client).to receive(:create_branch).and_return(response(status: 404))

      expect(result).to be_failure
    end

    it "fails on a network error" do
      allow(api_client).to receive(:create_branch).and_return(response(network_error: "timeout"))

      expect(result).to be_failure
    end

    context "when the mapping has no default_ref" do
      let(:mapping) do
        GitlabProjectMapping.create!(project:, gitlab_project_id: "42", default_ref: nil)
      end

      it "resolves the GitLab project's default_branch" do
        allow(api_client)
          .to receive(:project)
          .with(gitlab_project_id: "42")
          .and_return(response(status: 200, body: { "default_branch" => "develop" }))
        allow(api_client)
          .to receive(:create_branch)
          .with(gitlab_project_id: "42", branch: expected_branch, ref: "develop")
          .and_return(response(status: 201, body: {}))

        expect(result).to be_success
      end
    end
  end
end
