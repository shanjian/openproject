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

# Grants manage_project_labels to every role that already holds edit_project.
#
# Role permissions are seeded only on a fresh install - BasicData::ModelSeeder#applicable?
# is `model_class.none?` - so a new permission never reaches an existing installation.
# Without this, the project settings screen ships and no role can open it.
#
# edit_project is the chosen boundary: the people who already administer a project. Written
# as raw inserts rather than through the model so it does not depend on RolePermission's
# current shape.
class GrantManageProjectLabels < ActiveRecord::Migration[8.1]
  PERMISSION = "manage_project_labels"
  SOURCE = "edit_project"

  def up
    execute <<~SQL.squish
      INSERT INTO role_permissions (role_id, permission, created_at, updated_at)
      SELECT DISTINCT source.role_id, '#{PERMISSION}', NOW(), NOW()
      FROM role_permissions source
      WHERE source.permission = '#{SOURCE}'
        AND NOT EXISTS (
          SELECT 1 FROM role_permissions existing
          WHERE existing.role_id = source.role_id
            AND existing.permission = '#{PERMISSION}'
        )
    SQL
  end

  def down
    execute "DELETE FROM role_permissions WHERE permission = '#{PERMISSION}'"
  end
end
