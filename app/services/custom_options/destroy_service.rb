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
# Layer 1: removes an option and its stored values in one transaction. Tier-agnostic and
# unauthorised by design - both the system-admin path and the project-admin path call it,
# and they share the cleanup, not the authorisation.
#
# CustomOption has no dependent cleanup of its own, and the existing admin path deletes
# values only AFTER destroy succeeds, with nothing wrapping the two. A failure between them
# leaves work packages holding values that point at a row which no longer exists.
#
# Uses destroy, not delete_all: a deliberate single deletion should respect
# assure_at_least_one_option. Only the cascade from project deletion bypasses it, because a
# field-level invariant must not block deleting a project.
module CustomOptions
  class DestroyService
    def initialize(option:)
      @option = option
    end

    def call
      deleted_values = 0

      CustomOption.transaction do
        deleted_values = delete_custom_values
        raise ActiveRecord::Rollback unless @option.destroy
      end

      if @option.destroyed?
        ServiceResult.success(result: deleted_values)
      else
        ServiceResult.failure(errors: @option.errors)
      end
    end

    private

    # custom_values.value holds the option id as text on a column shared by every field
    # format, so the field and the value must stay paired.
    def delete_custom_values
      CustomValue
        .where(custom_field_id: @option.custom_field_id, value: @option.id.to_s)
        .delete_all
    end
  end
end
