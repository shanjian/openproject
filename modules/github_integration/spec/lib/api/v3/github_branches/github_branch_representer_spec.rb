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

RSpec.describe API::V3::GithubBranches::GithubBranchRepresenter do
  include API::V3::Utilities::PathHelper

  subject(:generated) { representer.to_json }

  let(:branch) { build_stubbed(:github_branch) }
  let(:representer) { described_class.create(branch, current_user: user) }
  let(:user) { build_stubbed(:admin) }

  it { is_expected.to include_json("GithubBranch".to_json).at_path("_type") }

  describe "properties" do
    it_behaves_like "property", :_type do
      let(:value) { "GithubBranch" }
    end

    it_behaves_like "property", :id do
      let(:value) { branch.id }
    end

    it_behaves_like "property", :name do
      let(:value) { branch.name }
    end

    it_behaves_like "property", :htmlUrl do
      let(:value) { branch.github_html_url }
    end

    it_behaves_like "property", :repository do
      let(:value) { branch.repository }
    end

    it_behaves_like "property", :lastCommitSha do
      let(:value) { branch.last_commit_sha }
    end

    it_behaves_like "property", :lastCommitMessage do
      let(:value) { branch.last_commit_message }
    end

    it_behaves_like "property", :lastCommitHtmlUrl do
      let(:value) { branch.last_commit_html_url }
    end

    it_behaves_like "property", :lastCommitAuthor do
      let(:value) { branch.last_commit_author }
    end

    it_behaves_like "has UTC ISO 8601 date and time" do
      let(:date) { branch.github_updated_at }
      let(:json_path) { "githubUpdatedAt" }
    end

    it_behaves_like "has UTC ISO 8601 date and time" do
      let(:date) { branch.created_at }
      let(:json_path) { "createdAt" }
    end

    it_behaves_like "has UTC ISO 8601 date and time" do
      let(:date) { branch.updated_at }
      let(:json_path) { "updatedAt" }
    end

    context "when the tip commit is unknown" do
      let(:branch) do
        build_stubbed(:github_branch,
                      last_commit_sha: nil,
                      last_commit_message: nil,
                      last_commit_html_url: nil,
                      last_commit_author: nil)
      end

      it "renders the commit properties as null" do
        expect(generated).to be_json_eql(nil.to_json).at_path("lastCommitSha")
        expect(generated).to be_json_eql(nil.to_json).at_path("lastCommitMessage")
        expect(generated).to be_json_eql(nil.to_json).at_path("lastCommitHtmlUrl")
        expect(generated).to be_json_eql(nil.to_json).at_path("lastCommitAuthor")
      end
    end
  end
end
