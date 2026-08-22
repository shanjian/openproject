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

class Queries::WorkPackages::Filter::EpicFilter <
  Queries::WorkPackages::Filter::WorkPackageFilter
  include ::Queries::WorkPackages::Filter::FilterForWpMixin

  # Matches the epics themselves in addition to the work packages linked to them.
  # The epic link is not a hierarchy relation, so an epic is never pulled in as an
  # ancestor row the way a parent is; without this the Gantt/timeline would show an
  # epic's children but never the epic itself. See #cross_project? below for the
  # project-scope half of the same feature.
  def where
    table = self.class.model.table_name
    linked_children = operator_strategy.sql_for_field(no_templated_values, table, :epic_id)
    epics_themselves = operator_strategy.sql_for_field(no_templated_values, table, :id)

    if negated_operator?
      # Excluding an epic has to exclude its children *and* the epic itself.
      "((#{linked_children}) AND (#{epics_themselves}))"
    else
      "((#{linked_children}) OR (#{epics_themselves}))"
    end
  end

  # When the operator is the cross-project variant, the query should ignore its
  # project scope so work packages whose epic_id matches in *any* visible project
  # show up. Query#project_filter_set? keys on this.
  def cross_project?
    operator.to_s == ::Queries::Operators::EpicCrossProject.symbol
  end

  private

  def negated_operator?
    operator.to_s == ::Queries::Operators::NotEquals.symbol
  end

  # Epic links may be cross-project (see docs/development/epic-link-implementation-tasks.md),
  # so the selectable epic must not be restricted to the current project's subtree the way
  # ParentFilter is. Otherwise selecting an epic that lives outside the current project
  # marks the filter as invalid and the whole query short-circuits to no results.
  def visible_scope
    WorkPackage.visible
  end

  # Use a strategy that adds the cross_project= operator on top of the standard
  # huge-list operators and defaults to it, so new epic filters span projects.
  def type_strategy
    @type_strategy ||= ::Queries::Filters::Strategies::EpicHugeList.new(self)
  end
end
