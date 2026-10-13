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
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

module McpTools
  # Priorities are the one attribute of a work package that an assistant could not look up before, so it
  # could only ever accept the default when creating or editing.
  class ListPriorities < Base
    include API::V3::Utilities::PathHelper

    default_title "List priorities"
    default_description "Lists all work package priorities available on this OpenProject instance, in order, " \
                        "with whether each is active. Use the IDs when setting a work package's priority."

    name "list_priorities"
    annotations read_only: true, idempotent: true, destructive: false

    def call
      # Like APIv3: priorities are only listed to someone who can see work packages at all.
      priorities = current_user.allowed_in_any_work_package?(:view_work_packages) ? IssuePriority.all : IssuePriority.none

      API::V3::Priorities::PriorityCollectionRepresenter.new(priorities, self_link: api_v3_paths.priorities, current_user:)
    end
  end
end
