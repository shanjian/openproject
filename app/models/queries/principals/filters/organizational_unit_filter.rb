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

# Narrows principals to the groups flagged as organisational units, i.e. departments.
#
# Matching by id via a subquery rather than joining group_details, because the scope here is
# Principal: a join would silently drop every user and placeholder user, which is wrong for the
# negated case.
class Queries::Principals::Filters::OrganizationalUnitFilter <
  Queries::Principals::Filters::PrincipalFilter
  include Queries::Filters::Shared::BooleanFilter

  def self.key
    :organizational_unit
  end

  def human_name
    I18n.t(:label_department)
  end

  # Deliberately does not call super: Queries::Filters::Base#apply_to would add
  # `where(users.organizational_unit => ...)`, and there is no such column -- the flag lives on
  # group_details. The sibling principals filters bypass it the same way.
  def apply_to(query_scope)
    if wants_organizational_units?
      query_scope.where(id: organizational_unit_ids)
    else
      query_scope.where.not(id: organizational_unit_ids)
    end
  end

  # Public so PrincipalQuery#default_scope can widen past the ordinary visibility restriction
  # when this filter is asking for organisational units specifically: departments are metadata
  # a department custom field intentionally exposes to everyone (CustomField#possible_department_values
  # has no visibility check of its own), not project members, so restricting them to visible
  # projects/groups would silently drop valid filter values for ordinary users.
  def wants_organizational_units?
    (values.first == OpenProject::Database::DB_VALUE_TRUE &&
      operator_strategy == Queries::Operators::BooleanEquals) ||
      (values.first == OpenProject::Database::DB_VALUE_FALSE &&
        operator_strategy == Queries::Operators::BooleanNotEquals)
  end

  private

  def organizational_unit_ids
    Group.organizational_units.select(:id)
  end
end
