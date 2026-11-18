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

RSpec.describe "API v3 github branches by work package resource", content_type: :json do
  include API::V3::Utilities::PathHelper

  shared_let(:project) { create(:project) }
  shared_let(:work_package) { create(:work_package, project:) }

  let(:permissions) { %i[view_work_packages show_github_content] }
  let(:current_user) { create(:user, member_with_roles: { project => create(:project_role, permissions:) }) }

  let(:older_branch) do
    create(:github_branch,
           name: "task/#{work_package.id}-older",
           github_updated_at: 3.days.ago,
           work_packages: [work_package])
  end
  let(:newer_branch) do
    create(:github_branch,
           name: "task/#{work_package.id}-newer",
           github_updated_at: 1.hour.ago,
           work_packages: [work_package])
  end
  let(:unrelated_branch) { create(:github_branch, work_packages: [create(:work_package, project:)]) }

  before do
    older_branch
    newer_branch
    unrelated_branch
    allow(User).to receive(:current).and_return(current_user)
  end

  describe "GET /api/v3/work_packages/:id/github_branches" do
    let(:path) { api_v3_paths.github_branches_by_work_package(work_package.id) }

    before { get path }

    it "responds with 200" do
      expect(last_response).to have_http_status(:ok)
    end

    it "lists only the branches of the work package, most recently updated first" do
      body = JSON.parse(last_response.body)

      expect(body["_type"]).to eq("Collection")
      expect(body["total"]).to eq(2)
      expect(body.dig("_embedded", "elements").pluck("name"))
        .to eq([newer_branch.name, older_branch.name])
    end

    it "renders the branches" do
      element = JSON.parse(last_response.body).dig("_embedded", "elements", 0)

      expect(element).to include("_type" => "GithubBranch",
                                 "id" => newer_branch.id,
                                 "htmlUrl" => newer_branch.github_html_url,
                                 "repository" => newer_branch.repository,
                                 "lastCommitSha" => newer_branch.last_commit_sha)
    end

    it "links to itself" do
      expect(JSON.parse(last_response.body).dig("_links", "self", "href")).to eq(path)
    end

    context "without any branch" do
      let(:path) { api_v3_paths.github_branches_by_work_package(create(:work_package, project:).id) }

      it "responds with an empty collection" do
        body = JSON.parse(last_response.body)

        expect(last_response).to have_http_status(:ok)
        expect(body["total"]).to eq(0)
        expect(body.dig("_embedded", "elements")).to eq([])
      end
    end

    context "without the show_github_content permission" do
      let(:permissions) { %i[view_work_packages] }

      it "responds with 403" do
        expect(last_response).to have_http_status(:forbidden)
      end
    end

    context "without the permission to see the work package" do
      let(:permissions) { %i[show_github_content] }

      it "responds with 404" do
        expect(last_response).to have_http_status(:not_found)
      end
    end
  end

  describe "the work package" do
    before { get api_v3_paths.work_package(work_package.id) }

    it "links to its github branches" do
      expect(JSON.parse(last_response.body).dig("_links", "github_branches", "href"))
        .to eq(api_v3_paths.github_branches_by_work_package(work_package.id))
    end
  end
end
