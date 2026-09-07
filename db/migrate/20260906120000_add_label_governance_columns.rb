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

# Phase 1 of two-tier label governance (docs/development/label-governance-design.md).
#
# Adds ownership to custom options and a label prefix to projects, plus the two custom field
# settings that gate the feature. Everything ships dark: allow_project_values defaults to
# false, so every option stays system-level and every existing code path behaves as before.
#
# Deliberately absent: the partial unique indexes on custom_options. There is no uniqueness
# constraint on that table today, so existing installations may hold duplicate or
# case-variant values and the migration would fail on them. Uniqueness is enforced by model
# validation from here on; the indexes follow in a later migration, after the duplicate
# report has been acted on.
#
# The unique index on projects.label_prefix IS safe here: the column is new and entirely
# NULL, and Postgres does not treat NULLs as equal.
class AddLabelGovernanceColumns < ActiveRecord::Migration[8.1]
  def change
    add_reference :custom_options, :project, foreign_key: true, null: true, index: false
    add_index :custom_options, %i[custom_field_id project_id]

    change_table :custom_fields, bulk: true do |t|
      t.boolean :allow_project_values, default: false, null: false
      t.string :option_pattern
      t.string :option_pattern_description
    end

    add_column :projects, :label_prefix, :string
    add_index :projects, :label_prefix, unique: true
  end
end
