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
        payload.commits.each do |commit|
          text = [commit["title"], commit["message"]]
            .select(&:present?)
            .join(" - ")
          work_packages = find_mentioned_work_packages(text, user)
          notes = generate_notes(commit, payload)
          comment_on_referenced_work_packages(work_packages, user, notes)
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

      def generate_notes(commit, payload)
        commit_id = commit["id"]
        I18n.t("gitlab_integration.push_single_commit_comment_with_ref",
               reference: payload.ref,
               commit_number: commit_id[0, 8],
               commit_note: commit["message"].presence || commit["title"],
               commit_url: commit["url"],
               commit_timestamp: commit["timestamp"],
               repository: payload.repository.name,
               repository_url: payload.repository.homepage,
               gitlab_user: payload.user_name,
               gitlab_user_url: payload.user_avatar)
      end
    end
  end
end
