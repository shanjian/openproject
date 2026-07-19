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
module OpenProject
  module GitlabIntegration
    module Services
      # Creates or updates the GitlabBranch that a push webhook describes and
      # links it to the referencing work packages. Identity is the branch's web
      # URL (globally unique and stable), so branches sharing a name across
      # different repositories never collapse into one record.
      class UpsertBranch
        def call(payload, work_packages: [])
          branch_name = branch_name(payload)

          find_or_initialize(payload, branch_name).tap do |branch|
            branch.update!(work_packages: branch.work_packages | work_packages,
                           **extract_params(payload, branch_name))
          end
        end

        private

        def find_or_initialize(payload, branch_name)
          GitlabBranch.find_by_gitlab_identifiers(url: branch_url(payload, branch_name),
                                                  initialize: true)
        end

        def extract_params(payload, branch_name)
          last_commit = tip_commit(payload)

          {
            name: branch_name,
            gitlab_html_url: branch_url(payload, branch_name),
            repository: payload.repository.name,
            last_commit_sha: last_commit_sha(payload, last_commit),
            last_commit_message: last_commit_message(last_commit),
            last_commit_html_url: last_commit&.fetch("url", nil),
            last_commit_author: last_commit_author(last_commit),
            gitlab_updated_at: last_commit_timestamp(last_commit)
          }
        end

        def branch_name(payload)
          payload.ref.sub("refs/heads/", "")
        end

        def branch_url(payload, branch_name)
          GitlabBranch.build_html_url(payload.project.web_url, branch_name)
        end

        # The tip of the branch is the commit matching `after`; fall back to the
        # newest commit in the payload. Both may be absent when a branch is
        # created off an existing ref (no new commits are pushed).
        def tip_commit(payload)
          commits = Array(payload.commits?)
          commits.find { |commit| commit["id"] == payload.after } || commits.last
        end

        def last_commit_sha(payload, last_commit)
          sha = last_commit&.fetch("id", nil) || payload.after
          blank_sha?(sha) ? nil : sha
        end

        def last_commit_message(last_commit)
          return if last_commit.nil?

          (last_commit["title"].presence || last_commit["message"].presence)&.strip
        end

        def last_commit_author(last_commit)
          last_commit&.dig("author", "name").presence
        end

        def last_commit_timestamp(last_commit)
          last_commit&.fetch("timestamp", nil).presence || Time.current
        end

        def blank_sha?(sha)
          sha.blank? || sha.match?(/\A0+\z/)
        end
      end
    end
  end
end
