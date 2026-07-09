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
  # Thin wrapper around the GitLab REST API (v4) for the outbound calls this
  # integration needs. The base URL is the single instance-wide host configured
  # in the plugin settings (see GITLAB_CREATE_BRANCH_DESIGN.md §2.1), never a
  # caller-supplied value, which bounds the SSRF surface.
  class APIClient
    # Normalized response so callers don't depend on HTTPX internals.
    # `network_error` is set only when the request never reached GitLab.
    Response = Struct.new(:status, :body, :network_error) do
      def success? = status && status >= 200 && status < 300
      def network_error? = !network_error.nil?
    end

    class ConfigurationError < StandardError; end

    def self.configured_base_url
      Hash(Setting.plugin_openproject_gitlab_integration)
        .with_indifferent_access["gitlab_base_url"]
    end

    def initialize(token:, base_url: self.class.configured_base_url)
      raise ConfigurationError, "GitLab base URL is not configured" if base_url.blank?

      @base_url = base_url.to_s.chomp("/")
      @token = token
    end

    # POST /projects/:id/repository/branches
    def create_branch(gitlab_project_id:, branch:, ref:)
      post("/projects/#{encode(gitlab_project_id)}/repository/branches",
           params: { branch:, ref: })
    end

    # GET /projects/:id -> used to resolve default_branch when no ref is configured.
    def project(gitlab_project_id:)
      get("/projects/#{encode(gitlab_project_id)}")
    end

    private

    def get(path)
      perform { authenticated.get(url(path)) }
    end

    def post(path, params:)
      perform { authenticated.post(url(path), params:) }
    end

    def perform
      res = yield
      if res.is_a?(HTTPX::ErrorResponse)
        Response.new(network_error: res.error.to_s)
      else
        Response.new(status: res.status, body: parse_body(res))
      end
    end

    def parse_body(res)
      raw = res.body.to_s
      raw.blank? ? nil : JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end

    def authenticated
      OpenProject.httpx.with(headers: { "PRIVATE-TOKEN" => @token })
    end

    def url(path)
      "#{@base_url}/api/v4#{path}"
    end

    # GitLab's :id accepts either the numeric project id or the URL-encoded
    # "namespace/project" path; CGI.escape leaves a numeric id untouched.
    def encode(gitlab_project_id)
      CGI.escape(gitlab_project_id.to_s)
    end
  end
end
