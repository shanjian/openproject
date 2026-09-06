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

# Sets each project's label prefix — the code every label that project owns must carry.
#
# System-admin only, deliberately. label_prefix is absent from PermittedParams#project and
# #new_project so that no project-scoped path can reach it: a project admin who could set
# their own prefix could grant themselves any namespace, and the governance would be
# decorative.
#
# Candidates are computed here and never persisted. A written value is by definition
# confirmed — it is what every validation reads — so there is nowhere to keep an unconfirmed
# suggestion. That also makes this screen idempotent: there is no state to re-apply.
module Admin::Settings
  class LabelPrefixesController < ::Admin::SettingsController
    menu_item :label_prefixes_settings

    def show
      @projects = Project.order(:name)
      @candidates = candidates_for(@projects)
    end

    def update
      updated = assign_prefixes

      if updated.all?(&:valid?)
        flash[:notice] = I18n.t(:notice_successful_update)
        redirect_to action: :show
      else
        @projects = Project.order(:name)
        @candidates = candidates_for(@projects)
        @failed = updated.reject(&:valid?)
        flash.now[:error] = failure_message(@failed)
        render :show, status: :unprocessable_entity
      end
    end

    private

    # One transaction: a partial save would leave an admin guessing which rows took.
    def assign_prefixes
      updated = []

      Project.transaction do
        prefix_params.each do |project_id, attributes|
          project = Project.find_by(id: project_id)
          next if project.nil?

          project.label_prefix = attributes[:label_prefix]
          next if project.label_prefix == project.label_prefix_was

          updated << project
          raise ActiveRecord::Rollback unless project.save
        end
      end

      updated
    end

    def prefix_params
      params.permit(projects: {})
            .fetch(:projects, {})
            .to_h
            .transform_values(&:symbolize_keys)
    end

    # Derived from the identifier, and only offered when it already satisfies the prefix
    # rule. An identifier such as 台北報社設備 normalises to nothing, and a blank candidate is
    # correct: the project cannot own labels until an admin picks one by hand.
    def candidates_for(projects)
      taken = Project.where.not(label_prefix: nil).pluck(:label_prefix).to_set

      projects.each_with_object({}) do |project, candidates|
        next if project.label_prefix.present?

        candidate = project.identifier.to_s.delete("-_").upcase
        next unless LabelNaming::PREFIX_FORMAT.match?(candidate)
        next if taken.include?(candidate)

        candidates[project.id] = candidate
      end
    end

    def failure_message(failed)
      failed
        .map { |project| "#{project.name}: #{project.errors.full_messages.join(', ')}" }
        .join("; ")
    end
  end
end
