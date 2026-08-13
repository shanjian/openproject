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

class Queries::Principals::PrincipalQuery
  include Queries::BaseQuery
  include Queries::UnpersistedQuery

  def self.model
    Principal
  end

  def default_scope
    scope = Principal.visible(User.current)

    # Department custom fields intentionally expose every organisational unit as an assignable
    # value regardless of the viewer's permissions (CustomField#possible_department_values has no
    # visibility check), so widen past the ordinary Principal visibility restriction when a query
    # specifically asks for organisational units -- otherwise a user without view_all_principals
    # or manage_members would never see departments outside their own visible projects/groups.
    if (filter = find_active_filter(:organizational_unit)) && filter.wants_organizational_units?
      scope = scope.or(Principal.where(id: Group.organizational_units.select(:id)))
    end

    scope.not_builtin
  end
end
