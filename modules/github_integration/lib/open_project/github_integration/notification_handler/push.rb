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

module OpenProject::GithubIntegration
  module NotificationHandler
    ##
    # Handles GitHub push notifications.
    #
    # Only the pushed branch is of interest: it is persisted (or removed again when
    # it was deleted) so it can be listed on the work packages it references.
    # Tags and other non-branch refs are ignored. Unlike the pull request handler,
    # this does not comment on the referenced work packages.
    #
    # See: https://docs.github.com/en/webhooks/webhook-events-and-payloads#push
    class Push
      include OpenProject::GithubIntegration::NotificationHandler::Helper

      BRANCH_REF_PREFIX = "refs/heads/"

      def process(params)
        payload = wrap_payload(params)
        return unless payload.ref?.to_s.start_with?(BRANCH_REF_PREFIX)

        branch_name = payload.ref.delete_prefix(BRANCH_REF_PREFIX)

        if deleted_branch?(payload)
          existing_branch(payload, branch_name)&.destroy!
        else
          track_branch(payload, branch_name)
        end
      end

      private

      def track_branch(payload, branch_name)
        user = User.find_by(id: payload.open_project_user_id)
        return if user.nil?

        work_packages = find_branch_work_packages(branch_name, user)
        # Branches that reference nothing are of no use here. One that did before
        # (and is kept up to date) is the exception: it stays linked to its work
        # packages.
        return if work_packages.empty? && existing_branch(payload, branch_name).nil?

        OpenProject::GithubIntegration::Services::UpsertBranch.new.call(payload, work_packages:)
      end

      def existing_branch(payload, branch_name)
        GithubBranch.find_by_github_identifiers(
          url: GithubBranch.build_html_url(payload.repository.html_url, branch_name)
        )
      end

      # GitHub flags the deletion of a branch itself; the all-zero `after` sha is
      # what it carries along, and is checked as well to not depend on the flag.
      def deleted_branch?(payload)
        payload.deleted? == true || payload.after?.to_s.match?(/\A0+\z/) || payload.after?.blank?
      end
    end
  end
end
