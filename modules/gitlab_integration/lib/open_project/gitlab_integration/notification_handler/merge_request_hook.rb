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
    # Handles Gitlab merge request notifications.
    class MergeRequestHook
      include OpenProject::GitlabIntegration::NotificationHandler::Helper

      def process(payload_params) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
        update_status_on_new_mr = false # true if you only reference one merge by work_package, else false.
        update_status_on_merged = false # true if you only reference one merge by work_package, else false.
        wp_status_id_on_new_mr = 7 # the id of the status.
        wp_status_id_on_merged = 8 # the id of the status.

        accepted_actions = %w[open update reopen]
        accepted_actions_for_comments = %w[open reopen]
        accepted_states = %w[closed merged]

        @payload = wrap_payload(payload_params)
        return unless (accepted_actions.include? payload.object_attributes.action) || (accepted_states.include? payload.object_attributes.state)

        user = User.find_by_id(payload.open_project_user_id)
        text = [payload.object_attributes.title, payload.object_attributes.description]
          .select(&:present?)
          .join(" - ")
        work_packages = find_mentioned_work_packages(text, user)
        notes = generate_notes(payload)

        if (accepted_actions_for_comments.include? payload.object_attributes.action) || (accepted_states.include? payload.object_attributes.state)
          comment_on_referenced_work_packages(work_packages, user, notes, deduplicate: true)
          if payload.object_attributes.state == "opened" && update_status_on_new_mr
            status_on_referenced_work_packages(work_packages, user, wp_status_id_on_new_mr)
          elsif payload.object_attributes.state == "merged" && update_status_on_merged
            status_on_referenced_work_packages(work_packages, user, wp_status_id_on_merged)
          end
        end
        merge_request = upsert_merge_request(work_packages)
        track_source_branch(user)
        merge_request
      end

      private

      attr_reader :payload

      # An open merge request carries its source branch and that branch's last
      # commit, so record the branch here too. This surfaces branches that were
      # pushed before branch tracking existed (their push webhook is never
      # replayed) as soon as any merge request event fires for them. The branch
      # is linked to the work packages its *name* references, matching the push
      # hook, rather than to whatever the merge request mentions.
      def track_source_branch(user)
        return unless payload.object_attributes.state == "opened"

        source_branch = payload.object_attributes.source_branch?
        return if source_branch.blank?

        branch_payload = source_branch_payload(source_branch)
        work_packages = find_branch_work_packages(source_branch, user)
        return if branch_payload.nil? || work_packages.empty?

        OpenProject::GitlabIntegration::Services::UpsertBranch.new.call(branch_payload, work_packages:)
      end

      # Reshapes the merge request's source into the push-shaped payload that
      # UpsertBranch consumes, so both capture paths share one code path.
      # Returns nil when the payload lacks the source project or last commit.
      def source_branch_payload(source_branch)
        source = payload.object_attributes.source?&.to_h
        commit = payload.object_attributes.last_commit?&.to_h
        return if source.blank? || commit.blank?

        wrap_payload(
          "ref" => "refs/heads/#{source_branch}",
          "after" => commit["id"],
          "project" => { "web_url" => source["web_url"] },
          "repository" => { "name" => source["name"] },
          "commits" => [commit]
        )
      end

      def generate_notes(payload)
        key = {
          "opened" => "opened",
          "reopened" => "reopened",
          "closed" => "closed",
          "merged" => "merged",
          "edited" => "referenced",
          "referenced" => "referenced"
        }[payload.object_attributes.state]

        key_action = {
          "reopen" => "reopened"
        }[payload.object_attributes.action]

        return nil unless key

        I18n.t("gitlab_integration.merge_request_#{key_action || key}_comment",
               mr_number: payload.object_attributes.iid,
               mr_title: payload.object_attributes.title,
               mr_url: payload.object_attributes.url,
               repository: payload.repository.name,
               repository_url: payload.repository.url,
               gitlab_user: payload.user.name,
               gitlab_user_url: payload.user.avatar_url)
      end

      def merge_request
        @merge_request ||= GitlabMergeRequest.find_by_gitlab_identifiers(
          id: payload.object_attributes.iid,
          url: payload.object_attributes.url
        )
      end

      def upsert_merge_request(work_packages)
        return if work_packages.empty? && merge_request.nil?

        OpenProject::GitlabIntegration::Services::UpsertMergeRequest.new.call(payload,
                                                                              work_packages:)
      end
    end
  end
end
