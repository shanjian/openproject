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

# Route path helpers, confirmed via `bin/rails routes | grep "work_packages/imports"` after adding
# `resources :imports, only: %i[new create show] do collection { post :preview } end` inside the
# project-scoped `namespace :work_packages do ... end` block in config/routes.rb (matches the
# brief's guessed names exactly):
#
#   new_project_work_packages_import_path(@project)      GET  /projects/:project_id/work_packages/imports/new
#   project_work_packages_imports_path(@project)         POST /projects/:project_id/work_packages/imports
#   preview_project_work_packages_imports_path(@project) POST /projects/:project_id/work_packages/imports/preview
#   project_work_packages_import_path(@project, id)      GET  /projects/:project_id/work_packages/imports/:id
module WorkPackages
  class ImportsController < ApplicationController
    before_action :find_project_by_project_id
    before_action :authorize

    def new
      @rows = []
      @source = ""
      @parse_errors = []
    end

    def preview # rubocop:disable Metrics/AbcSize
      @source = params[:source].to_s
      document_result = WorkPackages::Import::OutlineParser.call(@source)

      if document_result.failure?
        @rows = []
        @parse_errors = document_result.errors
      else
        resolution = WorkPackages::Import::Resolver.new(project: @project, user: current_user).call(document_result.result)

        if resolution.failure?
          @rows = []
          @parse_errors = resolution.errors
        else
          @rows = resolution.result
          @parse_errors = []
        end
      end

      render :new
    end
  end
end
