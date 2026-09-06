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
# The project-admin screen for labels this project owns.
#
# Authorisation is the standard project one - the manage_project_labels permission is mapped
# to these actions - and the services enforce the tier and prefix rules again, because the
# API and any future caller must not depend on this controller having checked.
class Projects::Settings::LabelsController < Projects::SettingsController
  menu_item :settings_labels

  before_action :find_label_fields
  before_action :require_label_field, only: %i[create update destroy]
  before_action :find_option, only: %i[update destroy]

  def index
    @labels_by_field = @label_fields.index_with { |field| owned_labels(field) }
    @system_labels_by_field = @label_fields.index_with { |field| field.custom_options.system_level.order(:value) }
  end

  def create
    call = CustomOptions::ProjectLabels::CreateService
             .new(user: current_user, project: @project, custom_field: @label_field)
             .call(value: label_params[:value])

    respond_with(call, :notice_successful_create)
  end

  def update
    call = CustomOptions::ProjectLabels::UpdateService
             .new(user: current_user, project: @project, custom_field: @label_field)
             .call(option: @option, value: label_params[:value])

    respond_with(call, :notice_successful_update)
  end

  def destroy
    call = CustomOptions::ProjectLabels::DeleteService
             .new(user: current_user, project: @project, custom_field: @label_field)
             .call(option: @option)

    respond_with(call, :notice_successful_delete)
  end

  private

  def respond_with(call, success_key)
    if call.success?
      flash[:notice] = I18n.t(success_key)
    else
      flash[:error] = call.message.presence || call.errors.full_messages.join(", ")
    end

    redirect_to project_settings_labels_path(@project)
  end

  # Every project-aware list field, not just the first. The admin form can enable the flag
  # on any work package list field, and picking one alphabetically would leave the others'
  # labels unmanageable.
  def find_label_fields
    @label_fields = WorkPackageCustomField
                      .where(field_format: "list", allow_project_values: true)
                      .order(:name)
                      .to_a
  end

  # The mutating actions resolve their field from the submitted option or parameter. Without
  # this they passed nil into the service, whose guard dereferences it - a 500 rather than a
  # message, on an instance where nobody has enabled the feature yet.
  def require_label_field
    @label_field = @label_fields.find { |field| field.id == submitted_field_id } || @label_fields.first
    return if @label_field

    flash[:error] = I18n.t("project_labels.not_enabled")
    redirect_to project_settings_labels_path(@project)
  end

  def submitted_field_id
    return params[:custom_field_id].to_i if params[:custom_field_id].present?

    CustomOption.where(id: params[:id]).pick(:custom_field_id)
  end

  def find_option
    @option = @label_field.custom_options.find_by(id: params[:id])
    render_404 if @option.nil?
  end

  def owned_labels(field)
    field.custom_options.where(project_id: @project.id).order(:value)
  end

  def label_params
    params.expect(custom_option: [:value])
  end
end
