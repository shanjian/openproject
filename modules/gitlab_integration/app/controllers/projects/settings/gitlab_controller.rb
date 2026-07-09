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

class Projects::Settings::GitlabController < Projects::SettingsController
  menu_item :settings_gitlab

  before_action :find_mapping, only: %i[update destroy]

  def show
    @mappings = project_mappings.to_a
    @new_mapping = GitlabProjectMapping.new
  end

  def create
    mapping = project_mappings.new(permitted_params)

    if mapping.save
      flash[:notice] = I18n.t(:notice_successful_create)
    else
      flash[:error] = mapping.errors.full_messages.join(", ")
    end

    redirect_to project_settings_gitlab_path(@project)
  end

  def update
    if @mapping.update(permitted_params)
      flash[:notice] = I18n.t(:notice_successful_update)
    else
      flash[:error] = @mapping.errors.full_messages.join(", ")
    end

    redirect_to project_settings_gitlab_path(@project)
  end

  def destroy
    @mapping.destroy!
    flash[:notice] = I18n.t(:notice_successful_delete)

    redirect_to project_settings_gitlab_path(@project)
  end

  private

  # This page is not mapped to a permission in AccessControl, so authorize it
  # explicitly against `edit_project` — the same permission that gates the other
  # project settings pages, which every project admin already holds.
  def authorize
    do_authorize(:edit_project)
  end

  def project_mappings
    GitlabProjectMapping.where(project_id: @project.id).order(:id)
  end

  def find_mapping
    @mapping = project_mappings.find(params[:id])
  end

  def permitted_params
    params
      .expect(gitlab_project_mapping: %i[name gitlab_project_id default_ref])
  end
end
