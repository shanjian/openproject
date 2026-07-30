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

# The comments GitLab webhooks post are tagged with the event family that caused
# them. That tag is what lets a project switch an event family off, and what
# keeps the comments out of the activity tab's comments-only view.
RSpec.describe "GitLab activity settings" do # rubocop:disable RSpec/DescribeClass
  shared_let(:gitlab_system_user) { create(:admin) }
  shared_let(:project) { create(:project) }
  shared_let(:work_package) { create(:work_package, project:) }

  let(:sha) { "a265d6b7bcf836b77ed9e32f824b231585c6a355" }

  def push_payload
    {
      "object_kind" => "push",
      "event_name" => "push",
      "before" => "0" * 40,
      "after" => sha,
      "ref" => "refs/heads/main",
      "user_name" => "Administrator",
      "user_avatar" => "https://example.com/avatar.png",
      "project" => { "web_url" => "http://gitlab.example/group/repo" },
      "commits" => [
        {
          "id" => sha,
          "message" => "Mentioning OP##{work_package.id}\n",
          "title" => "Mentioning OP##{work_package.id}",
          "timestamp" => "2024-07-22T11:18:29+02:00",
          "url" => "http://gitlab.example/group/repo/-/commit/#{sha[0, 8]}",
          "author" => { "name" => "Jane Dev", "email" => "jane@example.com" }
        }
      ],
      "repository" => { "name" => "repo", "homepage" => "http://gitlab.example/group/repo" },
      "open_project_user_id" => gitlab_system_user.id
    }
  end

  def process_push
    OpenProject::GitlabIntegration::NotificationHandler::PushHook.new.process(push_payload)
  end

  describe "project defaults" do
    # Mirror events, not conversations: what happened in GitLab is recorded,
    # the discussion itself is left where it already lives.
    it "records events" do
      expect(project.gitlab_comments_on?(:push)).to be(true)
      expect(project.gitlab_comments_on?(:merge_request)).to be(true)
      expect(project.gitlab_comments_on?(:issue)).to be(true)
    end

    it "does not copy GitLab discussion in" do
      expect(project.gitlab_comments_on?(:note)).to be(false)
    end
  end

  describe "posting a comment" do
    it "tags the journal with the GitLab event that caused it" do
      expect { process_push }.to change { work_package.journals.count }.by(1)

      journal = work_package.journals.last
      expect(journal.notes).to include("**Pushed in refs/heads/main:**")
      expect(journal.cause).to eq("type" => "gitlab_event", "event" => "push")
    end

    it "renders no 'caused changes' detail for the marker" do
      process_push

      expect(work_package.journals.last.details).to be_empty
    end

    it "keeps the journal out of the comments-only view" do
      process_push

      expect(work_package.journals.user_comments).to be_empty
    end

    it "leaves a comment a person wrote in the comments-only view" do
      work_package.add_journal(user: gitlab_system_user, notes: "A human comment")
      work_package.save!
      process_push

      expect(work_package.journals.user_comments.pluck(:notes)).to contain_exactly("A human comment")
    end
  end

  describe "a comment on a merge request" do
    def note_payload
      {
        "object_kind" => "note",
        "user" => { "name" => "jira_git_bot", "avatar_url" => "https://example.com/bot.png" },
        "object_attributes" => {
          "note" => "Blocking: this changes the notFound-driving post fetch. " * 20,
          "noteable_type" => "MergeRequest",
          "url" => "http://gitlab.example/group/repo/-/merge_requests/3180#note_1"
        },
        "merge_request" => { "iid" => 3180, "title" => "Mentioning OP##{work_package.id}" },
        "repository" => { "name" => "repo", "homepage" => "http://gitlab.example/group/repo" },
        "open_project_user_id" => gitlab_system_user.id
      }
    end

    def process_note
      OpenProject::GitlabIntegration::NotificationHandler::NoteHook.new.process(note_payload)
    end

    it "is not copied into the activity by default" do
      expect { process_note }.not_to change { work_package.journals.count }
    end

    context "when the project asks for it" do
      before do
        project.update!(gitlab_comment_on_note: true)
      end

      it "is copied in as a link plus a short excerpt, not the whole thread" do
        expect { process_note }.to change { work_package.journals.count }.by(1)

        journal = work_package.journals.last
        expect(journal.notes).to include("**Commented in MR:**", "3180")
        expect(journal.notes.length).to be < 600
        expect(journal.cause).to eq("type" => "gitlab_event", "event" => "note")
      end
    end
  end

  describe "when the project switched the event family off" do
    before do
      project.update!(gitlab_comment_on_push: false)
    end

    it "posts no comment" do
      expect { process_push }.not_to change { work_package.journals.count }
    end

    it "still tracks the branch, so the GitLab tab keeps working" do
      expect(project.gitlab_comments_on?(:push)).to be(false)
      expect { process_push }.not_to raise_error
    end

    it "does not affect the other event families" do
      expect(project.gitlab_comments_on?(:merge_request)).to be(true)
    end
  end
end
