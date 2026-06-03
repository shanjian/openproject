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

        # Epic link for board cards. epic_id is nullable, so render a null href when
        # there is no epic (mirrors the optional priority/assignee links above).
        #
        # The epic's subject is joined from a DERIVED TABLE that exposes only
        # (id, subject) rather than joining work_packages to itself directly. A bare
        # self-join would add a second full work_packages instance, making every
        # UNqualified work_packages column in the sibling user links (assigned_to_id,
        # author_id, responsible_id, ...) ambiguous and 500-ing the whole collection.
        # Restricting the join target to (id, subject) keeps it a single indexed
        # primary-key join (epic_id -> id) with no overlapping column names, and it
        # only runs when the client selects `epic`, so the SQL fast-path stays cheap.
        #
        # NOTE: unlike WorkPackageRepresenter this does not filter on epic
        # visibility - acceptable because boards only render this for work packages
        # the user can already see, and epic links are project-scoped.
        link :epic,
             href: ->(*) {
               <<~SQL.squish
                 CASE WHEN epic_id IS NULL THEN NULL
                 ELSE format('#{api_v3_paths.work_package('%s')}', epic_id)
                 END
               SQL
             },
             title: -> { "epic_subject" },
             join: {
               table: "(SELECT id, subject FROM work_packages)",
               alias: :epics,
               condition: "epics.id = work_packages.epic_id",
               select: ["epics.subject epic_subject"]
             }

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

        # Board card metadata. Both are bare columns on work_packages (no join), so
        # they only widen the projection by two columns and only when selected.
        property :storyPoints, column: :story_points

        property :estimatedHours, column: :estimated_hours
      end
    end
  end
end
