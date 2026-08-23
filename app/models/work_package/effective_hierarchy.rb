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

# The hierarchy the work package table *displays*, as opposed to the one stored
# in `work_package_hierarchies`. It is the real parent hierarchy, with one
# addition: a work package that has no parent at all is displayed under the epic
# it links to, so an epic reads as the head of its work instead of as a sibling
# of it.
#
# The rule is deliberately narrow (see
# docs/development/epic-hierarchy-display-design.md):
#
# * a real parent always wins, so no display edge ever contradicts the stored
#   hierarchy, and an invisible-but-existing parent still suppresses adoption;
# * adoption is scoped to a given set of work packages -- a query result page --
#   so an epic that is not on the page adopts nothing;
# * epic edges never chain, which keeps the displayed tree acyclic whatever the
#   data says.
#
# This is the server-side half of the rule; the work package table implements
# the same rule over its rendered rows.
class WorkPackage::EffectiveHierarchy
  def initialize(work_packages)
    @work_packages = work_packages.to_a
    @by_id = @work_packages.index_by(&:id)
  end

  # The id of the work package that should be displayed as this one's parent, or
  # nil when it should be displayed at root level.
  def effective_parent_id(work_package)
    return work_package.parent_id if work_package.parent_id.present?

    adoptable_epic_id(work_package)
  end

  # Whether this work package is displayed under its epic rather than under a
  # real parent.
  def adopted?(work_package)
    work_package.parent_id.blank? && adoptable_epic_id(work_package).present?
  end

  # The work packages in the set that link to the given one as their epic --
  # including those displayed elsewhere in the tree because they have a real
  # parent. This is the epic's *scope*, which is not the same as its subtree.
  def linked_children_of(epic)
    @work_packages.select { |work_package| work_package.epic_id == epic.id }
  end

  private

  def adoptable_epic_id(work_package)
    epic_id = work_package.epic_id
    return if epic_id.blank? || epic_id == work_package.id

    epic = @by_id[epic_id]
    # An epic outside the set cannot adopt, and an epic that links an epic of
    # its own does not either: that keeps epic edges to a single hop, so no
    # cycle can be built out of them.
    return unless epic && epic.epic_id.blank?

    epic_id
  end
end
