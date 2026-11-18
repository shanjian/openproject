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

class CreateGithubBranches < ActiveRecord::Migration[8.0]
  def change
    create_table :github_branches do |t|
      t.string :name, null: false
      t.string :github_html_url, null: false
      t.string :repository, null: false
      t.string :last_commit_sha
      t.text :last_commit_message
      t.string :last_commit_html_url
      t.string :last_commit_author
      t.datetime :github_updated_at, precision: nil

      t.timestamps precision: nil

      t.index :github_html_url, unique: true
    end

    create_join_table :github_branches, :work_packages do |t|
      # The composite index serves lookups by branch; work packages list their
      # branches, which needs an index of its own on the other side.
      t.index %i[github_branch_id work_package_id],
              unique: true,
              name: "unique_index_gh_branches_wps_on_gh_branch_id_and_wp_id"
      t.index :work_package_id, name: "github_branches_wp_work_package_id"
    end
  end
end
