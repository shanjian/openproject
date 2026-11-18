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

require_relative "../../../../spec_helper"

RSpec.describe OpenProject::GithubIntegration::Services::UpsertBranch do
  subject(:upsert) { described_class.new.call(payload, work_packages:) }

  let(:work_packages) { create_list(:work_package, 2) }
  let(:branch_name) { "bug/42-fix-crash" }
  let(:payload) { wrap_payload(webhook_payload("push", "branch_pushed", branch: branch_name)) }
  let(:branch_url) { "https://github.com/test_user/webhooks_playground/tree/#{branch_name}" }

  def wrap_payload(hash)
    OpenProject::GithubIntegration::NotificationHandler::Helper::Payload.new(hash)
  end

  context "when the branch is not known yet" do
    it "creates it and links the work packages" do
      expect { upsert }.to change(GithubBranch, :count).by(1)

      expect(upsert).to have_attributes(name: branch_name,
                                        github_html_url: branch_url,
                                        repository: "test_user/webhooks_playground",
                                        last_commit_sha: "a265d6b7bcf836b77ed9e32f824b231585c6a355",
                                        last_commit_message: "Fix the crash on startup",
                                        last_commit_author: "Some Committer")
      expect(upsert.work_packages).to match_array(work_packages)
    end

    it "returns the persisted branch" do
      expect(upsert).to be_persisted
    end
  end

  context "when the branch is known already" do
    let!(:branch) do
      create(:github_branch,
             name: branch_name,
             github_html_url: branch_url,
             work_packages: [existing_work_package])
    end
    let(:existing_work_package) { create(:work_package) }

    it "updates it" do
      expect { upsert }.not_to change(GithubBranch, :count)

      expect(branch.reload.last_commit_message).to eq("Fix the crash on startup")
    end

    it "adds the work packages to those it is linked to" do
      upsert

      expect(branch.reload.work_packages).to match_array(work_packages + [existing_work_package])
    end

    context "when one of the work packages is linked already" do
      let(:work_packages) { [existing_work_package] }

      it "links it only once" do
        upsert

        expect(branch.reload.work_packages).to contain_exactly(existing_work_package)
      end
    end
  end

  context "when no work packages are given" do
    let(:work_packages) { [] }

    it "still stores the branch" do
      expect { upsert }.to change(GithubBranch, :count).by(1)
    end
  end

  context "when a concurrent delivery stored the branch first" do
    let!(:branch) do
      create(:github_branch, name: branch_name, github_html_url: branch_url, work_packages: [])
    end

    before do
      lookups = 0
      allow(GithubBranch).to receive(:find_by_github_identifiers).and_wrap_original do |original, **args|
        # The first lookup does not see the row yet (it is committed meanwhile).
        (lookups += 1) == 1 ? GithubBranch.new(github_html_url: args[:url]) : original.call(**args)
      end
    end

    it "retries and updates the stored branch instead of failing" do
      expect { upsert }.not_to raise_error

      expect(GithubBranch.where(github_html_url: branch_url).count).to eq(1)
      expect(branch.reload.work_packages).to match_array(work_packages)
    end
  end

  context "when the uniqueness error does not go away" do
    before do
      allow(GithubBranch).to receive(:find_by_github_identifiers) do |url:, **|
        GithubBranch.new(github_html_url: url)
      end
      create(:github_branch, name: branch_name, github_html_url: branch_url)
    end

    it "gives up after a few attempts" do
      expect { upsert }.to raise_error(ActiveRecord::RecordNotUnique)
      expect(GithubBranch).to have_received(:find_by_github_identifiers).exactly(described_class::MAX_ATTEMPTS).times
    end
  end
end
