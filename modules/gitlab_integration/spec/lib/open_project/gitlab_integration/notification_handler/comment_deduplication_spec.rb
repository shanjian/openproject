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

# Running an instance-wide system hook alongside the per-repository webhooks
# delivers every push and merge-request event to OpenProject twice. Record
# upserts are keyed by URL and stay idempotent, but comments are not -- so the
# push and merge-request handlers opt into de-duplication to keep the work
# package activity free of identical comments.
RSpec.describe "GitLab notification comment de-duplication" do # rubocop:disable RSpec/DescribeClass
  shared_let(:gitlab_system_user) { create(:admin) }
  shared_let(:work_package) { create(:work_package) }

  def note_journal_count
    work_package.journals.where.not(notes: [nil, ""]).count
  end

  describe "push events" do
    let(:sha) { "a265d6b7bcf836b77ed9e32f824b231585c6a355" }
    let(:commit_message) { "Mentioning OP##{work_package.id}\n" }

    def push_payload(commit_sha: sha, message: commit_message, system_hook: false)
      payload = {
        "event_name" => "push",
        "before" => "0" * 40,
        "after" => commit_sha,
        "ref" => "refs/heads/main",
        "user_name" => "Administrator",
        "user_avatar" => "https://example.com/avatar.png",
        "project" => { "web_url" => "http://gitlab.example/group/repo" },
        "commits" => [
          {
            "id" => commit_sha,
            "message" => message,
            "title" => message.lines.first.to_s.strip,
            "timestamp" => "2024-07-22T11:18:29+02:00",
            "url" => "http://gitlab.example/group/repo/-/commit/#{commit_sha[0, 8]}",
            "author" => { "name" => "Jane Dev", "email" => "jane@example.com" }
          }
        ],
        "repository" => { "name" => "repo", "homepage" => "http://gitlab.example/group/repo" },
        "open_project_user_id" => gitlab_system_user.id
      }
      # A per-repo push webhook carries object_kind; a system hook does not.
      payload["object_kind"] = "push" unless system_hook
      payload
    end

    def process_push(payload)
      OpenProject::GitlabIntegration::NotificationHandler::PushHook.new.process(payload)
    end

    def process_system_hook(payload)
      OpenProject::GitlabIntegration::NotificationHandler::SystemHook.new.process(payload)
    end

    it "comments once when the same commit arrives from a webhook and a system hook" do
      process_push(push_payload)
      expect(note_journal_count).to eq(1)

      # Same commit, now delivered by the system hook (no object_kind).
      process_system_hook(push_payload(system_hook: true))
      expect(note_journal_count).to eq(1)
    end

    it "comments once when the identical push is delivered twice" do
      process_push(push_payload)
      process_push(push_payload)

      expect(note_journal_count).to eq(1)
    end

    it "still comments for a genuinely different commit" do
      process_push(push_payload)
      process_push(push_payload(commit_sha: "b" * 40, message: "Also OP##{work_package.id}\n"))

      expect(note_journal_count).to eq(2)
    end
  end

  describe "merge request events" do
    let(:mr_state) { "opened" }
    let(:mr_action) { "open" }

    def mr_payload(action: mr_action, state: mr_state)
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
          "action" => action,
          "state" => state,
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
        "repository" => { "name" => "repo", "url" => "git@gitlab.example:group/repo.git" },
        "open_project_user_id" => gitlab_system_user.id
      }
    end

    def process_mr(payload)
      OpenProject::GitlabIntegration::NotificationHandler::MergeRequestHook.new.process(payload)
    end

    def process_system_hook(payload)
      OpenProject::GitlabIntegration::NotificationHandler::SystemHook.new.process(payload)
    end

    it "comments once when the same MR event arrives from a webhook and a system hook" do
      process_mr(mr_payload)
      expect(note_journal_count).to eq(1)

      # System hooks forward merge requests unchanged, so the payload is identical.
      process_system_hook(mr_payload)
      expect(note_journal_count).to eq(1)
    end

    it "still comments for a different MR state (opened then merged)" do
      process_mr(mr_payload)
      process_mr(mr_payload(action: "merge", state: "merged"))

      expect(note_journal_count).to eq(2)
    end
  end
end
