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

module GitlabIntegration
  # Creates a branch in the GitLab project mapped to a work package's project,
  # named after the work package, using the acting user's Personal Access Token.
  # See GITLAB_CREATE_BRANCH_DESIGN.md §3.
  class CreateBranchService
    # Matches the shape GitActionsService#branchName / #sanitizeBranchString
    # produce on the frontend: lowercase word segments joined by single dashes
    # or slashes, optionally ending in a `-MMDD-HHmm` timestamp suffix.
    BRANCH_NAME_PATTERN = %r{\A[a-z0-9][a-z0-9\-/]{0,199}\z}

    def initialize(user:, work_package:, mapping:, branch_name: nil)
      @user = user
      @work_package = work_package
      @mapping = mapping
      @client_branch_name = branch_name.presence
    end

    def call
      return failure(:not_configured) if @mapping.nil?
      return failure(:invalid_branch_name) if @client_branch_name && !valid_client_branch_name?

      pat = GitlabUserToken.find_by(user_id: @user.id)&.token
      return failure(:missing_token) if pat.blank?

      client = APIClient.new(token: pat)
      create_branch_in(client)
    rescue APIClient::ConfigurationError
      failure(:base_url_missing)
    end

    # The branch name actually used to create the branch: the caller-supplied
    # name (the one shown/copied in the git-actions panel, so what's displayed
    # matches what's created) when given and valid, otherwise a name computed
    # the same way GitActionsService#branchName does without a timestamp
    # suffix. Any change to the default here must be mirrored in
    # git-actions.service.ts.
    def branch_name
      @client_branch_name || default_branch_name
    end

    private

    def default_branch_name
      type = sanitize(@work_package.type&.name)
      title = sanitize(@work_package.subject)
      "#{type}/#{@work_package.id}-#{title}".downcase
    end

    # Guards against arbitrary/malicious ref names being created via this
    # user's Personal Access Token, and keeps the branch matching the
    # `<type>/<id>-<slug>` convention that
    # NotificationHandler::Helper#branch_follows_convention? relies on to link
    # branches back to work packages (a trailing timestamp suffix doesn't
    # affect that prefix-based match).
    def valid_client_branch_name?
      @client_branch_name.match?(BRANCH_NAME_PATTERN) &&
        @client_branch_name.match?(%r{(?:\A|/)#{Regexp.escape(@work_package.id.to_s)}-})
    end

    def create_branch_in(client)
      ref = @mapping.default_ref.presence || resolve_default_branch(client)
      return failure(:no_ref) if ref.blank?

      branch = branch_name
      response = client.create_branch(gitlab_project_id: @mapping.gitlab_project_id,
                                      branch:,
                                      ref:)
      interpret(response, branch)
    end

    def resolve_default_branch(client)
      response = client.project(gitlab_project_id: @mapping.gitlab_project_id)
      response.success? ? response.body&.fetch("default_branch", nil) : nil
    end

    def interpret(response, branch)
      return failure(:network_error) if response.network_error?

      case response.status
      when 201 then success(branch, response.body)
      when 400 then interpret_bad_request(response, branch)
      when 401, 403 then failure(:unauthorized)
      when 404 then failure(:not_found)
      else failure(:unexpected, detail: gitlab_message(response))
      end
    end

    # GitLab returns 400 with "Branch already exists" — treat as informational.
    def interpret_bad_request(response, branch)
      if response.body.to_s.include?("already exists")
        success(branch, response.body, already_existed: true)
      else
        failure(:bad_request, detail: gitlab_message(response))
      end
    end

    def success(branch, body, already_existed: false)
      ServiceResult.success(
        result: {
          branch:,
          web_url: body.is_a?(Hash) ? body["web_url"] : nil,
          already_existed:,
          mapping_id: @mapping.id,
          repository: @mapping.display_name
        }
      )
    end

    def failure(reason, detail: nil)
      message = I18n.t("gitlab_integration.create_branch.errors.#{reason}")
      message = "#{message} #{detail}" if detail.present?
      ServiceResult.failure(message:, message_type: :error)
    end

    def gitlab_message(response)
      body = response.body
      return nil unless body.is_a?(Hash)

      body["message"] || body["error"]
    end

    def sanitize(str)
      str.to_s
         .gsub("&", "and ")
         .gsub(/\W+/, "-").delete_prefix("-").delete_suffix("-")
         .strip
    end
  end
end
