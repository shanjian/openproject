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
    def initialize(user:, work_package:)
      @user = user
      @work_package = work_package
    end

    def call
      settings = GitlabProjectSettings.find_by(project_id: @work_package.project_id)
      return failure(:not_configured) if settings.nil?

      pat = GitlabUserToken.find_by(user_id: @user.id)&.token
      return failure(:missing_token) if pat.blank?

      client = APIClient.new(token: pat)
      create(client, settings)
    rescue APIClient::ConfigurationError
      failure(:base_url_missing)
    end

    # Server-side branch name, kept identical to the frontend
    # GitActionsService#branchName so both places agree. See
    # git-actions.service.ts. Any change here must be mirrored there.
    def branch_name
      type = sanitize(@work_package.type&.name)
      title = sanitize(@work_package.subject)
      "#{type}/#{@work_package.id}-#{title}".downcase
    end

    private

    def create(client, settings)
      ref = settings.default_ref.presence || resolve_default_branch(client, settings)
      return failure(:no_ref) if ref.blank?

      branch = branch_name
      response = client.create_branch(gitlab_project_id: settings.gitlab_project_id,
                                      branch:,
                                      ref:)
      interpret(response, branch)
    end

    def resolve_default_branch(client, settings)
      response = client.project(gitlab_project_id: settings.gitlab_project_id)
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
          already_existed:
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
