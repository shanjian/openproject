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

# Reporter-named types used to have "responsible" (Accountable) stripped from
# their People group and replaced by "author" (Reporter). Any admin who saved a
# customized form configuration for such a type therefore persisted a People
# group like ["assignee", "author"], permanently losing Accountable. The code
# now keeps both, but only injects Reporter at read time -- it cannot tell a
# legacy stripped config apart from a future intentional removal.
#
# This one-time backfill reintroduces "responsible" into the persisted People
# group of reporter-type configs that are missing it, healing historical data
# without overriding admin choices made from here on.
class RestoreAccountableInReporterTypeFormConfigs < ActiveRecord::Migration[8.1]
  # Frozen snapshot of the reporter type names as of this migration, so the
  # backfill stays stable regardless of later changes to the application code.
  REPORTER_TYPE_NAMES = [
    "task",
    "bug",
    "user story",
    "epic",
    "feature",
    "summary task",
    "milestone"
  ].freeze

  def up
    Type.find_each do |type|
      next unless reporter_type?(type)

      groups = type.read_attribute(:attribute_groups)
      next if groups.blank?

      new_groups = restore_accountable(groups)
      next if new_groups == groups

      type.update_column(:attribute_groups, new_groups)
    end
  end

  # Reversing would strip Accountable again and reintroduce the original bug, so
  # the healed data is intentionally left in place.
  def down
    # no-op
  end

  private

  def reporter_type?(type)
    REPORTER_TYPE_NAMES.include?(type.name.to_s.strip.downcase)
  end

  def restore_accountable(groups)
    groups.map do |key, members|
      next [key, members] unless people_group?(key) && members.is_a?(Array)

      normalized = members.map(&:to_s)
      next [key, members] if normalized.include?("responsible")

      [key, insert_responsible(members, normalized)]
    end
  end

  def people_group?(key)
    key.to_s.casecmp("people").zero?
  end

  # Insert "responsible" right after "author" (falling back to after "assignee",
  # then to the end) to match the natural assignee -> author -> responsible order.
  def insert_responsible(members, normalized)
    anchor = normalized.index("author") || normalized.index("assignee")
    insertion_index = anchor ? anchor + 1 : members.length

    members.dup.insert(insertion_index, "responsible")
  end
end
