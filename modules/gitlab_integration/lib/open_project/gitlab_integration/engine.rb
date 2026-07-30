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

require "open_project/plugins"

require_relative "patches/api/work_package_representer"
require_relative "notification_handlers"
require_relative "hook_handler"
require_relative "services"

module OpenProject::GitlabIntegration
  class Engine < ::Rails::Engine
    engine_name :openproject_gitlab_integration

    include OpenProject::Plugins::ActsAsOpEngine

    # Global (instance-wide) settings for the GitLab integration.
    # `gitlab_base_url` is the single GitLab instance every outbound request is
    # allowed to target. Keeping the host here (and NOT in per-project or
    # per-user config) bounds the SSRF surface: requests can only ever hit this
    # host. See GITLAB_CREATE_BRANCH_DESIGN.md §2.1.
    def self.settings
      {
        default: {
          "gitlab_base_url" => nil
        },
        partial: "settings/gitlab_integration"
      }
    end

    register(
      "openproject-gitlab_integration",
      author_url: "https://github.com/btey/openproject",
      bundled: true,
      settings:
    ) do
      project_module(:gitlab, dependencies: :work_package_tracking) do
        permission(:show_gitlab_content,
                   {},
                   permissible_on: %i[work_package project])
      end

      menu :work_package_split_view,
           :gitlab,
           { tab: :gitlab },
           if: ->(project) {
             User.current.allowed_in_project?(:show_gitlab_content, project)
           },
           skip_permissions_check: true,
           badge: ->(work_package:, **) {
             work_package.gitlab_merge_requests.count +
               work_package.gitlab_issues.count +
               work_package.gitlab_branches.count
           },
           before: :watchers,
           caption: :project_module_github

      # Shown under Project settings for project admins (the `edit_project`
      # permission, same gate as the other settings pages), when the GitLab
      # module is enabled. We deliberately reuse `edit_project` rather than a
      # bespoke permission, which no role would hold by default.
      #
      # skip_permissions_check: the page isn't mapped to a permission in
      # AccessControl (the controller authorizes `edit_project` explicitly), so
      # the menu can't derive one from the URL — visibility is governed by the
      # `if:` below, and access is enforced by the controller.
      menu :project_menu,
           :settings_gitlab,
           { controller: "/projects/settings/gitlab", action: :show },
           caption: :"gitlab_integration.settings.menu",
           parent: :settings,
           skip_permissions_check: true,
           if: ->(project) {
             project.module_enabled?(:gitlab) &&
               User.current.allowed_in_project?(:edit_project, project)
           }

      # Per-user GitLab Personal Access Token, kept in a self-contained "My
      # account" page (mirrors the avatars module) to minimise coupling to the
      # upstream access-tokens page. See GITLAB_CREATE_BRANCH_DESIGN.md §2.3.
      add_menu_item :my_menu,
                    :gitlab_token,
                    { controller: "/gitlab_integration/my_gitlab_token", action: :show },
                    caption: :"gitlab_integration.my_token.menu",
                    icon: "git-branch"
    end

    patches %w[WorkPackage Project]

    initializer "gitlab.register_hook" do
      ::OpenProject::Webhooks.register_hook "gitlab" do |hook, environment, params, user|
        HookHandler.new.process(hook, environment, params, user)
      end
    end

    initializer "gitlab.subscribe_to_notifications" do
      ::OpenProject::Notifications.subscribe("gitlab.merge_request_hook",
                                             &NotificationHandlers.method(:merge_request_hook))
      ::OpenProject::Notifications.subscribe("gitlab.note_hook",
                                             &NotificationHandlers.method(:note_hook))
      ::OpenProject::Notifications.subscribe("gitlab.issue_hook",
                                             &NotificationHandlers.method(:issue_hook))
      ::OpenProject::Notifications.subscribe("gitlab.push_hook",
                                             &NotificationHandlers.method(:push_hook))
      ::OpenProject::Notifications.subscribe("gitlab.pipeline_hook",
                                             &NotificationHandlers.method(:pipeline_hook))
      ::OpenProject::Notifications.subscribe("gitlab.system_hook",
                                             &NotificationHandlers.method(:system_hook))
    end

    extend_api_response(:v3, :work_packages, :work_package,
                        &::OpenProject::GitlabIntegration::Patches::API::WorkPackageRepresenter.extension)

    add_api_path :gitlab_merge_requests_by_work_package do |id|
      "#{work_package(id)}/gitlab_merge_requests"
    end

    add_api_path :gitlab_issues_by_work_package do |id|
      "#{work_package(id)}/gitlab_issues"
    end

    add_api_path :gitlab_branches_by_work_package do |id|
      "#{work_package(id)}/gitlab/branches"
    end

    add_api_path :gitlab_user do |id|
      "gitlab_users/#{id}"
    end

    add_api_path :gitlab_pipeline do |id|
      "gitlab_pipeline/#{id}"
    end

    add_api_endpoint "API::V3::WorkPackages::WorkPackagesAPI", :id do
      mount ::API::V3::GitlabMergeRequests::GitlabMergeRequestsByWorkPackageAPI
    end

    add_api_endpoint "API::V3::WorkPackages::WorkPackagesAPI", :id do
      mount ::API::V3::GitlabIssues::GitlabIssuesByWorkPackageAPI
    end

    add_api_endpoint "API::V3::WorkPackages::WorkPackagesAPI", :id do
      mount ::API::V3::GitlabBranches::GitlabBranchesByWorkPackageAPI
    end

    add_cron_jobs do
      {
        "Cron::ClearOldMergeRequestsJob": {
          cron: "25 1 * * *", # runs at 1:25 nightly
          class: ::Cron::ClearOldMergeRequestsJob.name
        }
      }
    end
  end
end
