# frozen_string_literal: true

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
        # Adds `select=customFieldN` support (rendered only when selected, not via `*`).
        include API::V3::WorkPackages::CustomFieldSqlRepresenter

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

        # Epic link for board cards. epic_id is nullable -> null href when unset.
        #
        # Joined from the `visible_work_packages` CTE (see .ctes) rather than
        # work_packages directly, which buys two things:
        #   * the CTE projects only (id, subject), so this self-join can't collide
        #     with the sibling user-link columns (assigned_to_id, author_id, ...) and
        #     500 the whole collection with an ambiguous-column error;
        #   * it is restricted to work packages the current user may see, so an
        #     invisible cross-project epic nulls out (href AND title) exactly like
        #     WorkPackageRepresenter, instead of leaking the subject/id of a work
        #     package the user has no access to.
        # href keys off the joined alias id (exposed as epic_visible_id), not the
        # base epic_id column, so it nulls together with the title when the epic is
        # unset or not visible. The alias must be selected into the projection --
        # the join alias itself is not visible in the outer json_build_object.
        link :epic,
             href: ->(*) {
               <<~SQL.squish
                 CASE WHEN epic_visible_id IS NULL THEN NULL
                 ELSE format('#{api_v3_paths.work_package('%s')}', epic_visible_id)
                 END
               SQL
             },
             title: -> { "epic_subject" },
             join: {
               table: "visible_work_packages",
               alias: :epics,
               condition: "epics.id = work_packages.epic_id",
               select: ["epics.subject epic_subject", "epics.id epic_visible_id"]
             }

        # Version (sprint/release) link for backlog cards. version_id is nullable,
        # so render a null href when unset (mirrors the priority/epic links). The
        # default join alias for a `version` link is `versions` (name.pluralize),
        # which matches the joined table.
        link :version,
             href: ->(*) {
               <<~SQL.squish
                 CASE WHEN version_id IS NULL THEN NULL
                 ELSE format('#{api_v3_paths.version('%s')}', version_id)
                 END
               SQL
             },
             title: -> { "version_name" },
             join: {
               table: :versions,
               condition: "versions.id = work_packages.version_id",
               select: ["versions.name version_name"]
             }

        # Parent link for backlog cards (the client renders the parent as the
        # "Epic" field). parent_id is nullable -> null href when unset. Uses the
        # same `visible_work_packages` CTE join as epic above: the (id, subject)-only
        # projection avoids the ambiguous-column 500 from a bare self-join, and the
        # visibility filter means an invisible cross-project parent nulls out (href
        # AND title) like WorkPackageRepresenter rather than leaking its subject/id.
        # href keys off the selected parent_visible_id alias so it nulls together
        # with the title (the join alias is not visible in the outer projection).
        link :parent,
             href: ->(*) {
               <<~SQL.squish
                 CASE WHEN parent_visible_id IS NULL THEN NULL
                 ELSE format('#{api_v3_paths.work_package('%s')}', parent_visible_id)
                 END
               SQL
             },
             title: -> { "parent_subject" },
             join: {
               table: "visible_work_packages",
               alias: :parents,
               condition: "parents.id = work_packages.parent_id",
               select: ["parents.subject parent_subject", "parents.id parent_visible_id"]
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

        # Optimistic-locking token. The client needs it to PATCH a card (e.g. move
        # it to a sprint) without a stale-lock 409. Bare column, like storyPoints.
        property :lockVersion, column: :lock_version

        # Visible-only work-package set backing the parent/epic self-joins so they
        # never disclose the subject/id of a work package the current user cannot
        # see (e.g. a cross-project ancestor); an invisible target then renders
        # { href: null } like WorkPackageRepresenter. Exposed as a CTE because a
        # join `table:` is a static string evaluated at class load, before
        # User.current exists. Postgres prunes an unreferenced CTE, so a select that
        # touches neither parent nor epic pays nothing for it.
        def self.ctes(_walker_result)
          super.merge(visible_work_packages: WorkPackage.visible.reselect(:id, :subject).to_sql)
        end
      end
    end
  end
end
