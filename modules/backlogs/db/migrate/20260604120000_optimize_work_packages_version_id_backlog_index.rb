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

# The master backlog page loads each sprint/version column with:
#
#   WHERE project_id = ? AND type_id IN (...) AND version_id IN (?)
#   ORDER BY position ASC NULLS LAST, id ASC
#   LIMIT 201
#
# The single-column index on version_id lets Postgres find the column's rows
# but forces an in-memory sort of all of them before the LIMIT applies, so the
# LIMIT saves nothing at the DB layer on large versions.
#
# A composite (version_id, position, id) index lets the planner walk the rows
# already in sort order and stop after ~201 — no sort node. Because version_id
# is the leading column, the composite also serves everything the single-column
# index did (FK checks, plain version_id lookups), so we replace rather than add
# it: no net new index, hence no added write-maintenance cost. Postgres' default
# ASC ordering is NULLS LAST, matching the query's ORDER BY exactly.
class OptimizeWorkPackagesVersionIdBacklogIndex < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  NEW_INDEX = "index_work_packages_on_version_id_position_id"
  OLD_INDEX = "index_work_packages_on_version_id"

  def up
    # Add the composite first so version_id lookups are never left unindexed.
    add_index :work_packages, %i[version_id position id],
              name: NEW_INDEX, algorithm: :concurrently, if_not_exists: true
    remove_index :work_packages, name: OLD_INDEX, algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :work_packages, :version_id,
              name: OLD_INDEX, algorithm: :concurrently, if_not_exists: true
    remove_index :work_packages, name: NEW_INDEX, algorithm: :concurrently, if_exists: true
  end
end
