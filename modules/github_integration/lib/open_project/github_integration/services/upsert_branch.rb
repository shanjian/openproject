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

module OpenProject::GithubIntegration::Services
  ##
  # Takes push data coming from a GitHub webhook and stores the pushed branch as
  # a `GithubBranch`, linked to the given work packages. If the `GithubBranch`
  # already exists, it is updated and keeps the work packages it was linked to.
  #
  # Identity is the branch's web URL (globally unique and stable), so branches
  # sharing a name across different repositories never collapse into one record.
  #
  # Returns the upserted `GithubBranch`.
  #
  # See: https://docs.github.com/en/webhooks/webhook-events-and-payloads#push
  class UpsertBranch
    MAX_ATTEMPTS = 3

    def call(payload, work_packages: [])
      attempts = 0
      branch_name = branch_name(payload)

      begin
        find_or_initialize(payload, branch_name).tap do |branch|
          branch.update!(work_packages: branch.work_packages | work_packages,
                         **extract_params(payload, branch_name))
        end
      rescue ActiveRecord::RecordNotUnique
        # A concurrent delivery of the same event (GitHub redelivers on timeouts)
        # inserted the row first. Re-find and update it instead of failing; the
        # unique index on github_html_url already prevents a duplicate branch.
        raise if (attempts += 1) >= MAX_ATTEMPTS

        retry
      end
    end

    private

    def find_or_initialize(payload, branch_name)
      GithubBranch.find_by_github_identifiers(url: branch_url(payload, branch_name),
                                              initialize: true)
    end

    def extract_params(payload, branch_name)
      tip = tip_commit(payload)

      {
        name: branch_name,
        github_html_url: branch_url(payload, branch_name),
        repository: payload.repository.full_name,
        last_commit_sha: last_commit_sha(payload, tip),
        last_commit_message: subject(tip),
        last_commit_html_url: tip&.fetch("url", nil),
        last_commit_author: tip&.dig("author", "name").presence,
        github_updated_at: tip&.fetch("timestamp", nil).presence || Time.current
      }
    end

    def branch_name(payload)
      payload.ref.delete_prefix(OpenProject::GithubIntegration::NotificationHandler::Push::BRANCH_REF_PREFIX)
    end

    def branch_url(payload, branch_name)
      GithubBranch.build_html_url(payload.repository.html_url, branch_name)
    end

    # The tip of the branch is the `head_commit`. It is present even when the
    # branch was created off an existing ref and no new commits were pushed (in
    # which case `commits` is empty); the payload's commits are only a fallback.
    def tip_commit(payload)
      head_commit = payload.head_commit?&.to_h
      return head_commit if head_commit.present?

      commits = Array(payload.commits?)
      commits.find { |commit| commit["id"] == payload.after } || commits.last
    end

    def last_commit_sha(payload, tip)
      sha = tip&.fetch("id", nil).presence || payload.after

      sha.to_s.match?(/\A0*\z/) ? nil : sha
    end

    # Only the subject line of the commit message. A merge commit carries the
    # merged branch's full description, which does not belong in a branch row.
    def subject(tip)
      tip&.fetch("message", nil).to_s.lines.first&.strip.presence
    end
  end
end
