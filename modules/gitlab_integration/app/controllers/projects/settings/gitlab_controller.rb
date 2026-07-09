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

  def show
    @gitlab_project_settings = settings_for_project
  end

  def update
    @gitlab_project_settings = settings_for_project
    @gitlab_project_settings.assign_attributes(permitted_params)

    if @gitlab_project_settings.save
      flash[:notice] = I18n.t(:notice_successful_update)
    else
      flash[:error] = @gitlab_project_settings.errors.full_messages.join(", ")
    end

    redirect_to project_settings_gitlab_path(@project)
  end

  private

  def settings_for_project
    GitlabProjectSettings.find_or_initialize_by(project_id: @project.id)
  end

  def permitted_params
    params
      .expect(gitlab_project_settings: %i[gitlab_project_id default_ref])
  end
end
