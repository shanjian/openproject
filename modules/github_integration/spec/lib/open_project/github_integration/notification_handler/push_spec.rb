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

RSpec.describe OpenProject::GithubIntegration::NotificationHandler::Push do
  subject(:process) { handler.process(payload) }

  shared_let(:type) { create(:type, name: "Bug") }
  shared_let(:work_package) { create(:work_package, type:) }

  let(:handler) { described_class.new }
  let(:github_system_user) { create(:admin) }

  let(:branch_name) { "bug/#{work_package.id}-fix-crash" }
  let(:fixture) { "branch_pushed" }
  let(:payload) do
    webhook_payload("push", fixture, branch: branch_name)
      .merge("open_project_user_id" => github_system_user.id)
  end

  describe "a pushed branch" do
    context "when it references a work package by naming convention" do
      it "persists the branch and links it to the work package" do
        expect { process }.to change(GithubBranch, :count).by(1)

        branch = GithubBranch.last
        expect(branch.name).to eq(branch_name)
        expect(branch.github_html_url)
          .to eq("https://github.com/test_user/webhooks_playground/tree/bug/#{work_package.id}-fix-crash")
        expect(branch.repository).to eq("test_user/webhooks_playground")
        expect(branch.last_commit_sha).to eq("a265d6b7bcf836b77ed9e32f824b231585c6a355")
        expect(branch.last_commit_html_url)
          .to eq("https://github.com/test_user/webhooks_playground/commit/a265d6b7bcf836b77ed9e32f824b231585c6a355")
        expect(branch.last_commit_author).to eq("Some Committer")
        expect(branch.github_updated_at).to eq(Time.zone.parse("2021-04-01T10:15:30+02:00"))
        expect(branch.work_packages).to contain_exactly(work_package)
      end

      it "keeps only the subject line of the tip commit message" do
        process

        expect(GithubBranch.last.last_commit_message).to eq("Fix the crash on startup")
      end

      it "does not comment on the work package" do
        expect { process }.not_to change { work_package.reload.journals.count }
      end

      context "when the type name contains characters that are sanitized in branch names" do
        let(:type) { create(:type, name: "User story & more") }
        let(:work_package) { create(:work_package, type:) }
        let(:branch_name) { "user-story-and-more/#{work_package.id}-fix-crash" }

        it "persists the branch and links it to the work package" do
          expect { process }.to change(GithubBranch, :count).by(1)
          expect(GithubBranch.last.work_packages).to contain_exactly(work_package)
        end
      end

      context "when the branch name differs in case" do
        let(:branch_name) { "Bug/#{work_package.id}-Fix-Crash" }

        it "persists the branch and links it to the work package" do
          expect { process }.to change(GithubBranch, :count).by(1)
          expect(GithubBranch.last.work_packages).to contain_exactly(work_package)
        end
      end
    end

    context "when it references a work package by OP# mention" do
      let(:branch_name) { "hotfix-OP##{work_package.id}" }

      it "persists the branch and links it to the work package" do
        expect { process }.to change(GithubBranch, :count).by(1)
        expect(GithubBranch.last.work_packages).to contain_exactly(work_package)
      end

      it "escapes the '#' in the branch url so it is not read as a fragment" do
        process

        branch = GithubBranch.last
        expect(branch.name).to eq(branch_name)
        expect(branch.github_html_url)
          .to eq("https://github.com/test_user/webhooks_playground/tree/hotfix-OP%23#{work_package.id}")
      end
    end

    context "when it references several work packages" do
      let(:other_work_package) { create(:work_package, type:) }
      let(:branch_name) { "bug/#{work_package.id}-and-OP##{other_work_package.id}" }

      it "links all of them" do
        process

        expect(GithubBranch.last.work_packages).to contain_exactly(work_package, other_work_package)
      end
    end

    context "when it matches the convention but the type does not" do
      # A date-like name such as `release/2024-01-15` must not link work package #2024
      let(:branch_name) { "release/#{work_package.id}-notes" }

      it "does not persist a branch" do
        expect { process }.not_to change(GithubBranch, :count)
      end
    end

    context "when it does not reference any work package" do
      let(:branch_name) { "main" }

      it "does not persist a branch" do
        expect { process }.not_to change(GithubBranch, :count)
      end
    end

    context "when the referenced work package does not exist" do
      let(:branch_name) { "bug/999999999-does-not-exist" }

      it "does not persist a branch" do
        expect { process }.not_to change(GithubBranch, :count)
      end
    end

    context "when the system user may not comment on the referenced work package" do
      let(:github_system_user) { create(:user) }

      it "does not persist a branch" do
        expect { process }.not_to change(GithubBranch, :count)
      end
    end

    context "when the system user does not exist any more" do
      before { payload["open_project_user_id"] = User.maximum(:id).to_i + 1000 }

      it "does not persist a branch" do
        expect { process }.not_to change(GithubBranch, :count)
      end
    end

    context "when it is created together with its first commit" do
      let(:fixture) { "branch_created" }

      it "persists the branch with its tip commit" do
        expect { process }.to change(GithubBranch, :count).by(1)

        branch = GithubBranch.last
        expect(branch.last_commit_message).to eq("Start working on it")
        expect(branch.work_packages).to contain_exactly(work_package)
      end
    end

    context "when it is created off an existing ref with no new commits" do
      let(:fixture) { "branch_created_without_new_commits" }

      it "persists the branch using the head commit" do
        expect { process }.to change(GithubBranch, :count).by(1)

        branch = GithubBranch.last
        expect(branch.last_commit_sha).to eq("6113728f27ae82c7b1a177c8d03f9e96e0adf246")
        expect(branch.last_commit_message).to eq("An older commit the branch was created from")
        expect(branch.last_commit_author).to eq("Another Committer")
        expect(branch.github_updated_at).to eq(Time.zone.parse("2021-03-30T08:00:00+00:00"))
      end
    end

    context "when the payload carries neither a head commit nor commits" do
      before do
        payload["head_commit"] = nil
        payload["commits"] = []
      end

      it "persists the branch using the pushed sha and the current time" do
        freeze_time do
          expect { process }.to change(GithubBranch, :count).by(1)

          branch = GithubBranch.last
          expect(branch.last_commit_sha).to eq("a265d6b7bcf836b77ed9e32f824b231585c6a355")
          expect(branch.last_commit_message).to be_nil
          expect(branch.github_updated_at).to eq(Time.current)
        end
      end
    end

    context "when the payload has no head commit but lists commits" do
      before { payload["head_commit"] = nil }

      it "takes the tip from the listed commits" do
        process

        expect(GithubBranch.last.last_commit_message).to eq("Fix the crash on startup")
      end
    end

    context "when the branch is already tracked" do
      let!(:branch) do
        create(:github_branch,
               name: branch_name,
               github_html_url: "https://github.com/test_user/webhooks_playground/tree/#{branch_name}",
               repository: "test_user/webhooks_playground",
               last_commit_sha: "1111111111111111111111111111111111111111",
               last_commit_message: "An earlier commit",
               github_updated_at: 1.year.ago,
               work_packages: [work_package, other_work_package])
      end
      let(:other_work_package) { create(:work_package, type:) }

      it "updates it to the pushed tip instead of adding another one" do
        expect { process }.not_to change(GithubBranch, :count)

        branch.reload
        expect(branch.last_commit_sha).to eq("a265d6b7bcf836b77ed9e32f824b231585c6a355")
        expect(branch.last_commit_message).to eq("Fix the crash on startup")
        expect(branch.github_updated_at).to eq(Time.zone.parse("2021-04-01T10:15:30+02:00"))
      end

      it "keeps the work packages it was already linked to" do
        process

        expect(branch.reload.work_packages).to contain_exactly(work_package, other_work_package)
      end

      context "when it references a work package no more" do
        let(:branch_name) { "task/something-unrelated" }

        it "still updates the tracked branch" do
          expect { process }.not_to change(GithubBranch, :count)

          expect(branch.reload.last_commit_sha).to eq("a265d6b7bcf836b77ed9e32f824b231585c6a355")
        end
      end
    end

    context "when the same event is delivered twice" do
      it "persists the branch only once" do
        expect { 2.times { handler.process(payload) } }.to change(GithubBranch, :count).by(1)
      end
    end

    context "when a branch of the same name exists in another repository" do
      let!(:other_repository_branch) do
        create(:github_branch,
               name: branch_name,
               github_html_url: "https://github.com/other_user/other_repo/tree/#{branch_name}",
               work_packages: [work_package])
      end

      it "tracks the branch separately" do
        expect { process }.to change(GithubBranch, :count).by(1)

        expect(other_repository_branch.reload.last_commit_sha).not_to eq("a265d6b7bcf836b77ed9e32f824b231585c6a355")
        expect(GithubBranch.where(name: branch_name).pluck(:repository))
          .to contain_exactly(other_repository_branch.repository, "test_user/webhooks_playground")
      end
    end
  end

  describe "a deleted branch" do
    let(:fixture) { "branch_deleted" }

    context "when the branch is tracked" do
      let!(:branch) do
        create(:github_branch,
               name: branch_name,
               github_html_url: "https://github.com/test_user/webhooks_playground/tree/#{branch_name}",
               work_packages: [work_package])
      end

      it "removes the branch" do
        expect { process }.to change(GithubBranch, :count).by(-1)

        expect(GithubBranch.find_by(id: branch.id)).to be_nil
      end

      it "leaves the work package alone" do
        process

        expect(WorkPackage.find_by(id: work_package.id)).to be_present
      end

      context "when only the all-zero sha marks the deletion" do
        before { payload["deleted"] = false }

        it "removes the branch" do
          expect { process }.to change(GithubBranch, :count).by(-1)
        end
      end

      context "when only the deleted flag marks the deletion" do
        before { payload["after"] = "a265d6b7bcf836b77ed9e32f824b231585c6a355" }

        it "removes the branch" do
          expect { process }.to change(GithubBranch, :count).by(-1)
        end
      end
    end

    context "when the branch is not tracked" do
      it "does nothing" do
        expect { process }.not_to change(GithubBranch, :count)
      end
    end

    context "when a branch of the same name is tracked in another repository" do
      let!(:other_repository_branch) do
        create(:github_branch,
               name: branch_name,
               github_html_url: "https://github.com/other_user/other_repo/tree/#{branch_name}",
               work_packages: [work_package])
      end

      it "keeps that one" do
        expect { process }.not_to change(GithubBranch, :count)
      end
    end
  end

  describe "a pushed tag" do
    let(:payload) do
      webhook_payload("push", "tag_pushed", tag: "v1.0.0-OP#{work_package.id}")
        .merge("open_project_user_id" => github_system_user.id)
    end

    it "is ignored" do
      expect { process }.not_to change(GithubBranch, :count)
    end
  end

  describe "a payload without a ref" do
    before { payload.delete("ref") }

    it "is ignored" do
      expect { process }.not_to change(GithubBranch, :count)
    end
  end
end
