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

# Types without a saved form configuration pick the new "reviewer" attribute up
# from the default groups. Types whose form configuration an admin has saved keep
# exactly the attributes they listed, so Reviewer would only show up in the
# "inactive" column and every type would need touching by hand.
#
# This puts "reviewer" into the persisted People group of those types, right
# after Accountable (falling back to after Assignee, then to the end). Types that
# have no People group are left alone, and admins stay free to remove it again.
class AddReviewerToPeopleFormConfigs < ActiveRecord::Migration[8.1]
  class MigrationType < ApplicationRecord
    self.table_name = "types"
    self.inheritance_column = nil
    serialize :attribute_groups, type: Array
  end

  def up
    MigrationType.find_each do |type|
      groups = type.attribute_groups
      next if groups.blank?

      new_groups = add_reviewer(groups)
      next if new_groups == groups

      type.update_column(:attribute_groups, new_groups)
    end
  end

  def down
    MigrationType.find_each do |type|
      groups = type.attribute_groups
      next if groups.blank?

      new_groups = remove_reviewer(groups)
      next if new_groups == groups

      type.update_column(:attribute_groups, new_groups)
    end
  end

  private

  def add_reviewer(groups)
    groups.map do |key, members|
      next [key, members] unless people_group?(key) && members.is_a?(Array)

      normalized = members.map(&:to_s)
      next [key, members] if normalized.include?("reviewer")

      anchor = normalized.index("responsible") || normalized.index("assignee")
      insertion_index = anchor ? anchor + 1 : members.length

      [key, members.dup.insert(insertion_index, "reviewer")]
    end
  end

  def remove_reviewer(groups)
    groups.map do |key, members|
      next [key, members] unless members.is_a?(Array)

      [key, members.reject { |member| member.to_s == "reviewer" }]
    end
  end

  def people_group?(key)
    key.to_s.casecmp("people").zero?
  end
end
