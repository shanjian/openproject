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

module API
  module V3
    module GitlabBranches
      class GitlabBranchesByWorkPackageAPI < ::API::OpenProjectAPI
        namespace :gitlab do
          after_validation do
            authorize_in_work_package(:show_gitlab_content, work_package: @work_package)
          end

          helpers do
            def gitlab_project_mappings
              GitlabProjectMapping.where(project_id: @work_package.project_id).order(:id)
            end
          end

          resources :branch_targets do
            desc "List the GitLab projects a branch can be created in for this work package"
            get do
              {
                targets: gitlab_project_mappings.map do |mapping|
                  { id: mapping.id, name: mapping.display_name, gitlabProjectId: mapping.gitlab_project_id }
                end
              }
            end
          end

          resources :branches do
            desc "Create a branch in a mapped GitLab project for this work package"
            params do
              optional :mappingId, type: Integer, desc: "Which GitLab project mapping to create the branch in"
            end
            post do
              mappings = gitlab_project_mappings
              mapping =
                if params[:mappingId].present?
                  mappings.find_by(id: params[:mappingId]) || raise(::API::Errors::NotFound.new)
                elsif mappings.one?
                  mappings.first
                end

              result = ::GitlabIntegration::CreateBranchService
                         .new(user: current_user, work_package: @work_package, mapping:)
                         .call

              unless result.success?
                raise ::API::Errors::UnprocessableContent.new(result.message)
              end

              status 201
              {
                branch: result.result[:branch],
                webUrl: result.result[:web_url],
                alreadyExisted: result.result[:already_existed],
                repository: result.result[:repository]
              }
            end
          end
        end
      end
    end
  end
end
