#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) 2023 Ben Tey
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
# Copyright (C) the OpenProject GmbH
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
# See docs/COPYRIGHT.rdoc for more details.
#++

module OpenProject::GitlabIntegration
  module NotificationHandler
    ##
    # Handles Gitlab commit notifications.
    class PushHook
      include OpenProject::GitlabIntegration::NotificationHandler::Helper

      def process(payload_params)
        @payload = wrap_payload(payload_params)
        return nil unless payload.object_kind == "push"

        user = User.find_by(id: payload.open_project_user_id)
        comment_on_commits(user)
        track_branch(user)
      end

      private

      attr_reader :payload

      def comment_on_commits(user)
        commits_by_work_package(user).each do |work_package, commits|
          comment_on_referenced_work_packages([work_package], user, generate_notes(commits),
                                              event: :push, deduplicate: true)
        end
      end

      # Groups the pushed commits by the work packages they reference, so that a
      # push of several commits mentioning the same work package yields one
      # activity entry rather than one per commit. Work packages compare by id,
      # so the same one found through different commits collapses into one key.
      def commits_by_work_package(user)
        payload.commits.each_with_object({}) do |commit, grouped|
          text = [commit["title"], commit["message"]]
            .select(&:present?)
            .join(" - ")

          find_mentioned_work_packages(text, user).each do |work_package|
            (grouped[work_package] ||= []) << commit
          end
        end
      end

      # Persists (or removes) the pushed branch so it can be listed on the work
      # packages it references. Tags and other non-branch refs are ignored.
      def track_branch(user)
        return unless payload.ref.to_s.start_with?("refs/heads/")

        branch_name = payload.ref.sub("refs/heads/", "")

        if deleted_branch?
          existing_branch(branch_name)&.destroy!
        else
          upsert_branch(branch_name, user)
        end
      end

      def upsert_branch(branch_name, user)
        work_packages = find_branch_work_packages(branch_name, user)
        return if work_packages.empty? && existing_branch(branch_name).nil?

        OpenProject::GitlabIntegration::Services::UpsertBranch.new.call(payload, work_packages:)
      end

      def existing_branch(branch_name)
        GitlabBranch.find_by(gitlab_html_url: GitlabBranch.build_html_url(payload.project.web_url, branch_name))
      end

      def deleted_branch?
        payload.after.blank? || payload.after.match?(/\A0+\z/)
      end

      def generate_notes(commits)
        return single_commit_notes(commits.first) if commits.one?

        I18n.t("gitlab_integration.push_commits_comment_with_ref",
               commit_count: commits.size,
               commit_list: commit_list(commits),
               **push_attributes)
      end

      def single_commit_notes(commit)
        I18n.t("gitlab_integration.push_single_commit_comment_with_ref",
               commit_number: commit["id"][0, 8],
               commit_note: commit_subject(commit),
               commit_url: commit["url"],
               commit_timestamp: commit["timestamp"],
               **push_attributes)
      end

      # The parts of a note that describe the push rather than a single commit.
      def push_attributes
        {
          reference: payload.ref,
          repository: payload.repository.name,
          repository_url: payload.repository.homepage,
          gitlab_user: payload.user_name,
          gitlab_user_url: payload.user_avatar
        }
      end

      def commit_list(commits)
        commits
          .map { |commit| "- [#{commit['id'][0, 8]}](#{commit['url']}) #{commit_subject(commit)}" }
          .join("\n")
      end

      # Only the subject line of the commit message. A merge commit carries the
      # merged branch's full description, which would otherwise be pasted into
      # the activity in its entirety.
      def commit_subject(commit)
        message = commit["message"].presence || commit["title"].to_s
        message.split("\n").first.to_s.strip
      end
    end
  end
end
