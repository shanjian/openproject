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

# Adds the "Reviewer" user attribute to work packages, a sibling of assigned_to
# and responsible (Accountable). It lets a work package carry the person who is
# asked to review it, so the assignee no longer has to be switched for every
# review stage. The journal table mirrors the column so changes are tracked, and
# notification_settings gets the matching "reviewer" reason toggle.
class AddReviewerToWorkPackages < ActiveRecord::Migration[8.1]
  def change
    add_column :work_packages, :reviewer_id, :bigint
    add_index :work_packages, :reviewer_id

    add_column :work_package_journals, :reviewer_id, :bigint
    add_index :work_package_journals, :reviewer_id

    add_column :notification_settings, :reviewer, :boolean, default: true, null: false
  end
end
