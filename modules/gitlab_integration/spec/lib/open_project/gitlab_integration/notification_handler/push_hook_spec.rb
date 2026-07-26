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

RSpec.describe OpenProject::GitlabIntegration::NotificationHandler::PushHook do
  subject(:process) { handler_instance.process(payload) }

  shared_let(:gitlab_system_user) { create(:admin) }
  shared_let(:work_package) { create(:work_package) }

  let(:handler_instance) { described_class.new }

  let(:commit_title) { "Mentioning OP##{work_package.id}" }
  let(:commit_message) { "Mentioning OP##{work_package.id}\n\nSome commit message\n" }
  let(:payload) do
    {
      "object_kind" => "push",
      "event_name" => "push",
      "before" => "76e703f64c13245bdacf66737d99a52f08f3d727",
      "after" => "a265d6b7bcf836b77ed9e32f824b231585c6a355",
      "ref" => "refs/heads/main",
      "ref_protected" => true,
      "checkout_sha" => "a265d6b7bcf836b77ed9e32f824b231585c6a355",
      "message" => nil,
      "user_id" => 1,
      "user_name" => "Administrator",
      "user_username" => "root",
      "user_email" => nil,
      "user_avatar" => "https://www.gravatar.com/avatar/65a222b844ced567fe0ed2594c0b4abdf62efa1322a385c919c41e7bbc16d4fc?s=80&d=identicon",
      "project_id" => 1,
      "project" =>
        {
          "id" => 1,
          "name" => "Test",
          "description" => nil,
          "web_url" => "http://c7e7cd2d54c3/openprojecttest/test",
          "avatar_url" => nil,
          "git_ssh_url" => "git@c7e7cd2d54c3:openprojecttest/test.git",
          "git_http_url" => "http://c7e7cd2d54c3/openprojecttest/test.git",
          "namespace" => "openprojecttest",
          "visibility_level" => 10,
          "path_with_namespace" => "openprojecttest/test",
          "default_branch" => "main",
          "ci_config_path" => nil,
          "homepage" => "http://c7e7cd2d54c3/openprojecttest/test",
          "url" => "git@c7e7cd2d54c3:openprojecttest/test.git",
          "ssh_url" => "git@c7e7cd2d54c3:openprojecttest/test.git",
          "http_url" => "http://c7e7cd2d54c3/openprojecttest/test.git"
        },
      "commits" => [
        {
          "id" => "a265d6b7bcf836b77ed9e32f824b231585c6a355",
          "message" => commit_message,
          "title" => commit_title,
          "timestamp" => "2024-07-22T11:18:29+02:00",
          "url" => "http://c7e7cd2d54c3/openprojecttest/test/-/commit/a265d6b7bcf836b77ed9e32f824b231585c6a355",
          "author" => { "name" => "Some committer", "email" => "some_committer@example.com" },
          "added" => [],
          "modified" => ["CHANGELOG"],
          "removed" => []
        }
      ],
      "total_commits_count" => 1,
      "push_options" => {},
      "repository" =>
        {
          "name" => "Test",
          "url" => "git@c7e7cd2d54c3:openprojecttest/test.git",
          "description" => nil,
          "homepage" => "http://c7e7cd2d54c3/openprojecttest/test",
          "git_http_url" => "http://c7e7cd2d54c3/openprojecttest/test.git",
          "git_ssh_url" => "git@c7e7cd2d54c3:openprojecttest/test.git",
          "visibility_level" => 10
        },
      "open_project_user_id" => gitlab_system_user.id,
      "gitlab_event" => "push_hook"
    }
  end

  before do
    allow(handler_instance).to receive(:comment_on_referenced_work_packages).and_return(nil)
  end

  context "with a regular push" do
    let(:comment) do
      "**Pushed in refs/heads/main:** [Administrator]" \
        "(https://www.gravatar.com/avatar/65a222b844ced567fe0ed2594c0b4abdf62efa1322a385c919c41e7bbc16d4fc?s=80&d=identicon) " \
        "pushed [a265d6b7](http://c7e7cd2d54c3/openprojecttest/test/-/commit/a265d6b7bcf836b77ed9e32f824b231585c6a355) " \
        "to [Test](http://c7e7cd2d54c3/openprojecttest/test) at 2024-07-22T11:18:29+02:00:" \
        "\nMentioning OP##{work_package.id}\n\nSome commit message\n\n"
    end

    it "adds a comment to the work packages" do
      process
      expect(handler_instance).to have_received(:comment_on_referenced_work_packages).with(
        [work_package],
        gitlab_system_user,
        comment,
        deduplicate: true
      )
    end

    context "when no commit message is given in the payload" do
      before do
        payload["commits"][0]["message"] = nil
      end

      let(:comment) do
        "**Pushed in refs/heads/main:** [Administrator]" \
          "(https://www.gravatar.com/avatar/65a222b844ced567fe0ed2594c0b4abdf62efa1322a385c919c41e7bbc16d4fc?s=80&d=identicon) " \
          "pushed [a265d6b7](http://c7e7cd2d54c3/openprojecttest/test/-/commit/a265d6b7bcf836b77ed9e32f824b231585c6a355) " \
          "to [Test](http://c7e7cd2d54c3/openprojecttest/test) at 2024-07-22T11:18:29+02:00:\nMentioning OP##{work_package.id}\n"
      end

      it "does not raise (Bugfix)" do
        expect { process }.not_to raise_error
        expect(handler_instance).to have_received(:comment_on_referenced_work_packages).with(
          [work_package],
          gitlab_system_user,
          comment,
          deduplicate: true
        )
      end
    end
  end

  describe "branch tracking" do
    shared_let(:branch_type) { create(:type, name: "Bug") }
    shared_let(:branch_work_package) { create(:work_package, type: branch_type) }

    let(:branch_name) { "bug/#{branch_work_package.id}-fix-crash" }
    let(:new_branch) { true }
    let(:branch_url) { "http://c7e7cd2d54c3/openprojecttest/test/-/tree/#{branch_name}" }

    before do
      payload["ref"] = "refs/heads/#{branch_name}"
      payload["before"] = "0" * 40 if new_branch
    end

    context "when a pushed branch references a work package by naming convention" do
      it "persists the branch and links it to the work package" do
        expect { process }.to change(GitlabBranch, :count).by(1)

        branch = GitlabBranch.last
        expect(branch.name).to eq(branch_name)
        expect(branch.gitlab_html_url).to eq(branch_url)
        expect(branch.repository).to eq("Test")
        expect(branch.last_commit_sha).to eq("a265d6b7bcf836b77ed9e32f824b231585c6a355")
        expect(branch.last_commit_author).to eq("Some committer")
        expect(branch.work_packages).to contain_exactly(branch_work_package)
      end
    end

    context "when a pushed branch references a work package by OP# mention" do
      let(:branch_name) { "hotfix-OP##{branch_work_package.id}" }

      it "persists the branch and links it to the work package" do
        expect { process }.to change(GitlabBranch, :count).by(1)
        expect(GitlabBranch.last.work_packages).to contain_exactly(branch_work_package)
      end

      it "escapes the '#' in the stored tree URL so it does not become a fragment" do
        process

        branch = GitlabBranch.last
        expect(branch.name).to eq(branch_name)
        expect(branch.gitlab_html_url)
          .to eq("http://c7e7cd2d54c3/openprojecttest/test/-/tree/hotfix-OP%23#{branch_work_package.id}")
      end
    end

    context "when a pushed branch matches the convention but the type does not" do
      # `release/2024-...` must not link to work package #2024 unless its type
      # actually sanitizes to "release".
      let(:branch_name) { "release/#{branch_work_package.id}-notes" }

      it "does not persist a branch" do
        expect { process }.not_to change(GitlabBranch, :count)
      end
    end

    context "when the pushed branch does not reference any work package" do
      let(:branch_name) { "main" }

      it "does not persist a branch" do
        expect { process }.not_to change(GitlabBranch, :count)
      end
    end

    context "when a branch is created off an existing ref with no new commits" do
      before { payload["commits"] = [] }

      it "still persists the branch using the after sha" do
        expect { process }.to change(GitlabBranch, :count).by(1)

        branch = GitlabBranch.last
        expect(branch.last_commit_sha).to eq(payload["after"])
        expect(branch.last_commit_message).to be_nil
      end
    end

    context "when an existing branch receives a new push" do
      let(:new_branch) { false }

      before do
        create(:gitlab_branch,
               name: branch_name,
               gitlab_html_url: branch_url,
               last_commit_sha: "oldsha",
               work_packages: [branch_work_package])
      end

      it "updates the existing branch instead of creating a new one" do
        expect { process }.not_to change(GitlabBranch, :count)
        expect(GitlabBranch.find_by(gitlab_html_url: branch_url).last_commit_sha)
          .to eq("a265d6b7bcf836b77ed9e32f824b231585c6a355")
      end
    end

    context "when the branch is deleted" do
      let(:new_branch) { false }

      before do
        payload["after"] = "0" * 40
        create(:gitlab_branch,
               name: branch_name,
               gitlab_html_url: branch_url,
               work_packages: [branch_work_package])
      end

      it "removes the branch" do
        expect { process }.to change(GitlabBranch, :count).by(-1)
        expect(GitlabBranch.find_by(gitlab_html_url: branch_url)).to be_nil
      end
    end

    context "when the same branch name is pushed in a different repository" do
      it "keeps the branches as separate records" do
        process

        payload["project"]["web_url"] = "http://c7e7cd2d54c3/openprojecttest/other"
        payload["repository"]["name"] = "Other"
        described_class.new.process(payload)

        expect(GitlabBranch.where(name: branch_name).pluck(:repository))
          .to contain_exactly("Test", "Other")
      end
    end
  end
end
