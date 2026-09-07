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
module CustomOptions
  module ProjectLabels
    class UpdateService < BaseService
      def call(option:, value:)
        reason = guard || ownership_failure(option)
        return guard_failure(reason) if reason

        with_field_lock do
          # Only the value is writable. project_id and custom_field_id are pinned: a
          # permitted-parameter slip letting either through would turn "edit my label" into
          # "move this option into another project, or onto another field", which no other
          # validation would catch - the option would be perfectly valid in its new home.
          option.value = value
          raise ActiveRecord::Rollback unless option.save
        end

        option.errors.empty? ? ServiceResult.success(result: option) : ServiceResult.failure(errors: option.errors)
      end

      private

      def ownership_failure(option)
        :not_owned unless option.project_id == project.id
      end
    end
  end
end
