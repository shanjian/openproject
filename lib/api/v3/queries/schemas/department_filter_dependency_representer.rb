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

module API
  module V3
    module Queries
      module Schemas
        # Allowed values for a `department` custom field filter
        # (Queries::Filters::Shared::CustomFields::Department), whose values are
        # Group.organizational_units.
        #
        # Deliberately not a subclass of GroupFilterDependencyRepresenter: that one narrows the
        # collection to groups that are members of the filter's project, and a department is an
        # organisational unit rather than a project member, so it would answer an empty list.
        class DepartmentFilterDependencyRepresenter <
          PrincipalFilterDependencyRepresenter
          # Not the inherited "[]User". The frontend treats any type containing "User" as a user
          # resource and prepends a "Me" option
          # (filter-searchable-multiselect-value.component.ts#isUserResource), which can never
          # match a department. Both types fall through to the same searchable multiselect in
          # query-filter.component.html, so this only removes that bogus option.
          def type
            "[]Department"
          end

          private

          # Restricted to organisational units, not merely to groups: a group that is not a
          # department can never match, since the filter resolves its values through
          # Group.organizational_units, so offering one in the autocompleter is a dead end.
          def filter_query
            [{ type: { operator: "=", values: ["Group"] } },
             { organizationalUnit: { operator: "=",
                                     values: [OpenProject::Database::DB_VALUE_TRUE] } }]
          end
        end
      end
    end
  end
end
