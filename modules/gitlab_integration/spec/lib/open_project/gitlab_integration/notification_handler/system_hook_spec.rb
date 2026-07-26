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

RSpec.describe OpenProject::GitlabIntegration::NotificationHandler::SystemHook do
  subject(:process) { described_class.new.process(payload) }

  shared_let(:gitlab_system_user) { create(:admin) }

  let(:push_hook) { OpenProject::GitlabIntegration::NotificationHandler::PushHook }
  let(:merge_request_hook) { OpenProject::GitlabIntegration::NotificationHandler::MergeRequestHook }

  describe "a push system hook" do
    shared_let(:branch_type) { create(:type, name: "Task") }
    shared_let(:branch_work_package) { create(:work_package, type: branch_type) }

    let(:branch_name) { "task/#{branch_work_package.id}-refactor" }

    # A system-hook push identifies itself with `event_name` and carries NO
    # `object_kind`, unlike a per-repo push webhook. The commit text intentionally
    # references no work package so no journal comments are attempted here.
    let(:payload) do
      {
        "event_name" => "push",
        "before" => "0" * 40,
        "after" => "a265d6b7bcf836b77ed9e32f824b231585c6a355",
        "ref" => "refs/heads/#{branch_name}",
        "user_name" => "Administrator",
        "user_avatar" => "https://example.com/avatar.png",
        "project" => { "web_url" => "http://gitlab.example/group/repo" },
        "commits" => [
          {
            "id" => "a265d6b7bcf836b77ed9e32f824b231585c6a355",
            "message" => "Refactor the thing\n",
            "timestamp" => "2024-07-22T11:18:29+02:00",
            "url" => "http://gitlab.example/group/repo/-/commit/a265d6b7",
            "author" => { "name" => "Jane Dev", "email" => "jane@example.com" }
          }
        ],
        "repository" => {
          "name" => "repo",
          "homepage" => "http://gitlab.example/group/repo"
        },
        "open_project_user_id" => gitlab_system_user.id,
        "gitlab_event" => "system_hook"
      }
    end

    it "dispatches to the push handler and tracks the branch (despite the missing object_kind)" do
      expect { process }.to change(GitlabBranch, :count).by(1)

      branch = GitlabBranch.last
      expect(branch.name).to eq(branch_name)
      expect(branch.gitlab_html_url).to eq("http://gitlab.example/group/repo/-/tree/#{branch_name}")
      expect(branch.repository).to eq("repo")
      expect(branch.work_packages).to contain_exactly(branch_work_package)
    end

    it "forwards the payload to PushHook stamped with object_kind so its guard passes" do
      delegate = instance_double(push_hook, process: nil)
      allow(push_hook).to receive(:new).and_return(delegate)

      process

      expect(delegate).to have_received(:process)
        .with(hash_including("object_kind" => "push", "event_name" => "push"))
    end
  end

  describe "a merge request system hook" do
    shared_let(:work_package) { create(:work_package) }

    # A system-hook merge request carries `object_kind`, exactly like a per-repo
    # merge-request webhook, so it is forwarded unchanged.
    let(:payload) do
      {
        "object_kind" => "merge_request",
        "event_type" => "merge_request",
        "user" => {
          "id" => 1,
          "name" => "Administrator",
          "username" => "root",
          "avatar_url" => "https://example.com/avatar.png",
          "email" => "[REDACTED]"
        },
        "object_attributes" => {
          "action" => "open",
          "state" => "opened",
          "title" => "A MR title",
          "description" => "Mentioning OP##{work_package.id}",
          "draft" => false,
          "work_in_progress" => false,
          "id" => 4,
          "iid" => 4,
          "url" => "http://gitlab.example/group/repo/-/merge_requests/4",
          "updated_at" => "2024-07-22T11:18:29+02:00",
          "source_branch" => "feature/no-work-package-reference"
        },
        "labels" => [],
        "repository" => {
          "name" => "repo",
          "url" => "git@gitlab.example:group/repo.git"
        },
        "open_project_user_id" => gitlab_system_user.id,
        "gitlab_event" => "system_hook"
      }
    end

    before do
      # Suppress the journal comment so the test focuses on MR tracking.
      delegate = merge_request_hook.new
      allow(delegate).to receive(:comment_on_referenced_work_packages)
      allow(merge_request_hook).to receive(:new).and_return(delegate)
    end

    it "dispatches to the merge request handler and records the MR" do
      expect { process }.to change(GitlabMergeRequest, :count).by(1)

      mr = GitlabMergeRequest.find_by_gitlab_identifiers(id: 4)
      expect(mr.gitlab_html_url).to eq("http://gitlab.example/group/repo/-/merge_requests/4")
      expect(mr.repository).to eq("repo")
      expect(mr.work_packages).to contain_exactly(work_package)
    end

    it "forwards the payload unchanged to MergeRequestHook" do
      delegate = instance_double(merge_request_hook, process: nil)
      allow(merge_request_hook).to receive(:new).and_return(delegate)

      process

      expect(delegate).to have_received(:process).with(payload)
    end
  end

  describe "an unsupported system hook (e.g. project_create)" do
    let(:payload) do
      {
        "event_name" => "project_create",
        "name" => "repo",
        "path_with_namespace" => "group/repo",
        "open_project_user_id" => gitlab_system_user.id,
        "gitlab_event" => "system_hook"
      }
    end

    it "is ignored without error or side effects" do
      allow(push_hook).to receive(:new)
      allow(merge_request_hook).to receive(:new)

      expect { process }.not_to raise_error
      expect(process).to be_nil
      expect(push_hook).not_to have_received(:new)
      expect(merge_request_hook).not_to have_received(:new)
    end
  end
end
