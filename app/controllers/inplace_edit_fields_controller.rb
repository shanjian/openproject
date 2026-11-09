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

class InplaceEditFieldsController < ApplicationController
  include OpTurbo::ComponentStream

  # Arguments the controller sets itself. The system arguments are echoed to the client and back as
  # JSON, so they must not be able to override these.
  SERVER_SIDE_ARGUMENTS = %w[attribute model update_registry enforce_edit_mode].freeze

  before_action :find_model
  before_action :set_attribute
  authorization_checked! :edit, :update, :reset

  def edit
    replace_via_turbo_stream(
      component: component(enforce_edit_mode: true),
      status: :ok
    )

    respond_with_turbo_streams
  end

  def update
    handler = update_registry.fetch_handler(@model)

    if handler.present?
      success = handler.call(
        model: @model,
        params: permitted_params,
        user: current_user
      )
    else
      raise ArgumentError, "Missing update handler for #{@model}"
    end

    if success
      render_success_flash_message_via_turbo_stream(
        message: I18n.t(:notice_successful_update)
      )
    end

    replace_via_turbo_stream(
      component: component(enforce_edit_mode: !success),
      status: success ? :ok : :unprocessable_entity
    )

    respond_with_turbo_streams
  rescue ArgumentError
    head :not_found
  end

  def reset
    replace_via_turbo_stream(component:)
    respond_with_turbo_streams
  end

  private

  def find_model
    model_class = resolve_model_class(params[:model])
    @model = model_class.visible.find(params[:id])
  rescue ActiveRecord::RecordNotFound, ArgumentError
    head :not_found
  end

  def resolve_model_class(model_param)
    return nil if model_param.blank?

    model_class =
      update_registry.resolve_model_class(model_param)

    unless model_class &&
           model_class < ApplicationRecord &&
           model_class.respond_to?(:visible)
      raise ArgumentError, "Unsupported model for inplace edit"
    end

    model_class
  end

  # The attribute comes from the URL and is eventually sent to the model with `public_send`,
  # so only attributes that were registered for inplace editing are accepted.
  def set_attribute
    return head :not_found unless OpenProject::InplaceEdit::FieldRegistry.editable?(params[:attribute])

    @attribute = params[:attribute].to_sym
  end

  def permitted_params
    params
      .expect(@model.model_name.param_key => [@attribute])
  end

  def component(enforce_edit_mode: false)
    OpenProject::Common::InplaceEditFieldComponent.new(
      model: @model,
      attribute: @attribute,
      enforce_edit_mode:,
      update_registry:,
      **system_arguments.to_h.symbolize_keys
    )
  end

  def update_registry
    @update_registry ||= OpenProject::InplaceEdit::UpdateRegistry.default
  end

  def system_arguments
    arguments = params[:system_arguments_json].presence || params.to_unsafe_h
                                    .values
                                    .filter_map { |v| v["system_arguments_json"] }
                                    .first

    arguments.nil? ? {} : JSON.parse(arguments).except(*SERVER_SIDE_ARGUMENTS)
  end
end
