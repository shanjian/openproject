#  OpenProject is an open source project management software.
#  Copyright (C) the OpenProject GmbH
#
#  This program is free software; you can redistribute it and/or
#  modify it under the terms of the GNU General Public License version 3.
#
#  OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
#  Copyright (C) 2006-2013 Jean-Philippe Lang
#  Copyright (C) 2010-2013 the ChiliProject Team
#
#  This program is free software; you can redistribute it and/or
#  modify it under the terms of the GNU General Public License
#  as published by the Free Software Foundation; either version 2
#  of the License, or (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
#  See COPYRIGHT and LICENSE files for more details.

module API
  module V3
    module WorkPackages
      class WorkPackageSqlRepresenter
        include API::Decorators::Sql::Hal
        include API::Decorators::Sql::HalAssociatedResource

        link :self,
             path: { api: :work_package, params: %w(id) },
             column: -> { :id },
             title: -> { "subject" }

        link :project,
             path: { api: :project, params: %w(id) },
             column: -> { :project_id },
             title: -> { "project_name" },
             join: { table: :projects,
                     condition: "projects.id = work_packages.project_id",
                     select: ["projects.name project_name"] }

        link :status,
             path: { api: :status, params: %w(id) },
             column: -> { :status_id },
             title: -> { "status_name" },
             join: {
               table: :statuses,
               condition: "statuses.id = work_packages.status_id",
               select: ["statuses.name status_name"]
             }

        link :type,
             path: { api: :type, params: %w(id) },
             column: -> { :type_id },
             title: -> { "type_name" },
             join: {
               table: :types,
               condition: "types.id = work_packages.type_id",
               select: ["types.name type_name"]
             }

        # priority_id is nullable, so render a null href when there is no priority
        # (mirrors how the optional assignee/responsible links behave). A plain
        # `path:`/`column:` link would emit "/api/v3/priorities/" for a null id.
        link :priority,
             href: ->(*) {
               <<~SQL.squish
                 CASE WHEN priority_id IS NULL THEN NULL
                 ELSE format('#{api_v3_paths.priority('%s')}', priority_id)
                 END
               SQL
             },
             title: -> { "priority_name" },
             join: {
               # The enumerations table is aliased to the pluralized link name ("priorities").
               # Filter by STI type as well: enumerations holds several kinds (priorities,
               # activities, ...). priority_id only ever points at an IssuePriority, so this
               # is defensive, but it keeps the join honest if a row is ever mis-referenced.
               table: :enumerations,
               condition: "priorities.id = work_packages.priority_id AND priorities.type = 'IssuePriority'",
               select: ["priorities.name priority_name"]
             }

        associated_user_link :author

        associated_user_link :assignee,
                             column_name: :assigned_to_id

        associated_user_link :responsible

        property :_type,
                 representation: ->(*) { "'WorkPackage'" }

        property :id

        property :subject

        property :startDate, column: :start_date,
                             render_if: ->(*) { "is_milestone != true" },
                             join: { table: :types,
                                     condition: "types.id = work_packages.type_id",
                                     select: "types.is_milestone is_milestone",
                                     alias: :types }

        property :dueDate, column: :due_date,
                           render_if: ->(*) { "is_milestone != true" },
                           join: { table: :types,
                                   condition: "types.id = work_packages.type_id",
                                   select: "types.is_milestone is_milestone",
                                   alias: :types }

        property :date, column: :start_date,
                        render_if: ->(*) { "is_milestone = true" },
                        join: { table: :types,
                                condition: "types.id = work_packages.type_id",
                                select: "types.is_milestone is_milestone",
                                alias: :types }
      end
    end
  end
end
