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
# Layer 2: the project-admin path.
#
# Deliberately separate from CustomFields::BaseContract, whose RequiresAdminGuard must stay
# intact - that contract governs field format, is_required, is_for_all, regexp and section,
# so loosening it to let a project admin add one value would hand them the field itself,
# across every project it is enabled in.
module CustomOptions
  module ProjectLabels
    class BaseService
      ADVISORY_LOCK_NAMESPACE = 8_314_201

      def initialize(user:, project:, custom_field:)
        @user = user
        @project = project
        @custom_field = custom_field
      end

      private

      attr_reader :user, :project, :custom_field

      # Every one of these is enforced here because nothing else on this path enforces it.
      def guard
        return :unauthorised unless user.allowed_in_project?(:manage_project_labels, project)
        return :field_not_open unless custom_field.allow_project_values?
        return :no_prefix if project.label_prefix.blank?

        nil
      end

      def guard_failure(reason)
        ServiceResult.failure(message: I18n.t("custom_options.project_labels.errors.#{reason}"))
      end

      # Serialises creation per field. The shadowing rule is a model validation with no
      # database backstop - the two partial unique indexes cover system-vs-system and
      # project-vs-project, and the cross-tier case spans both, which no single index can
      # express without also forbidding two projects owning same-named labels. Model
      # validations are not atomic, so without this two concurrent writes both pass.
      def with_field_lock(&)
        CustomOption.transaction do
          CustomOption.connection.execute(
            "SELECT pg_advisory_xact_lock(#{ADVISORY_LOCK_NAMESPACE}, #{custom_field.id.to_i})"
          )
          yield
        end
      end
    end
  end
end
