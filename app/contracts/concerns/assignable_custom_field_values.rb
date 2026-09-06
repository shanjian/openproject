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

module AssignableCustomFieldValues
  extend ActiveSupport::Concern

  included do
    def assignable_custom_field_values(custom_field)
      case custom_field.field_format
      when "list"
        assignable_list_custom_field_values(custom_field)
      when "version"
        assignable_version_custom_field_values(custom_field)
      when "department"
        custom_field.possible_department_values
      end
    end

    private

    # Narrows ONLY for project-aware list fields, and only where a project can be resolved.
    #
    # This concern is shared: WorkPackages::BaseContract, Projects::BaseContract and
    # Users::BaseContract all include it. Scoping every list field would change project
    # attributes and user attributes too, and Users::BaseContract has no project at all, so
    # the scoping would have nothing to scope by and would empty every list-format user
    # field. Gating on allow_project_values - false for every field that exists today -
    # makes the default exactly the current behaviour.
    def assignable_list_custom_field_values(custom_field)
      project = custom_field_customized_project
      return custom_field.possible_values unless custom_field.allow_project_values? && project

      applicable = custom_field.custom_options.applicable_in(project)

      # Options already stored on the record stay selectable even when the project can no
      # longer apply them - a work package that moved projects keeps its labels, and editing
      # anything else about it must not silently drop them. Mirrors the version branch below.
      retained = assigned_list_custom_field_values(custom_field)
      return applicable.to_a if retained.empty?

      (applicable.to_a + retained).uniq
    end

    def assigned_list_custom_field_values(custom_field)
      customized = version_custom_field_customized
      return [] unless customized

      ids = customized
              .custom_values_for_custom_field(custom_field)
              .filter_map { |custom_value| custom_value.value.presence }
      return [] if ids.empty?

      CustomOption.where(id: ids).to_a
    end

    def custom_field_customized_project
      customized = version_custom_field_customized
      customized.project if customized.respond_to?(:project)
    end

    def assignable_version_custom_field_values(custom_field)
      assignable = assignable_versions(only_open: !custom_field.allow_non_open_versions?,
                                       kind: custom_field.version_kind)

      # Versions already stored on the custom field stay selectable even when they
      # are no longer offered (e.g. a closed version while only open ones are
      # assignable). Otherwise editing a multi-value version field would silently
      # drop those values. Mirrors WorkPackage#retained_assignable_version, which
      # does the same for the native version_id field.
      retained = assigned_version_custom_field_values(custom_field)
      return assignable if retained.empty?

      (assignable.to_a + retained).uniq
    end

    def assigned_version_custom_field_values(custom_field)
      customized = version_custom_field_customized
      return [] unless customized

      ids = customized
              .custom_values_for_custom_field(custom_field)
              .filter_map { |custom_value| custom_value.value.presence }
      return [] if ids.empty?

      scope = Version.where(id: ids)
      # Keep retained versions within the field's kind so a stale mismatched value
      # (e.g. a Sprint left over on a Release field) is not re-exposed as allowed.
      scope = scope.where(kind: custom_field.version_kind) if custom_field.version_kind.present?
      scope.to_a
    end

    def version_custom_field_customized
      if defined?(@object) && @object.respond_to?(:custom_values_for_custom_field)
        @object
      elsif respond_to?(:model) && model.respond_to?(:custom_values_for_custom_field)
        model
      end
    end
  end
end
