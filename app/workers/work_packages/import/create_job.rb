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

module WorkPackages
  module Import
    class CreateJob < ApplicationJob
      queue_with_priority :above_normal

      class CreationFailed < StandardError
        attr_accessor :source_line

        def self.from_error(error)
          new(error[:message]).tap { |e| e.source_line = error[:source_line] }
        end
      end

      def perform(import_run:) # rubocop:disable Metrics/AbcSize
        self.import_run = import_run
        import_run.update!(status: :running)

        # `upsert_status` (see JobStatus::ApplicationJobWithStatus) records the JobStatus::Status
        # under `User.current`, and JobStatusesController#validate_job later looks that record up
        # scoped to the *viewing* user's id -- so it must be the importing user, not whatever
        # `User.current` happens to be in this worker thread. `WorkPackages::CreateService` below
        # is already given `user: import_run.user` explicitly and is unaffected by this; only the
        # `upsert_status` calls actually depend on it. Matches the same `User.execute_as` wrapping
        # `Exports::ExportJob` uses around its own `upsert_status` calls.
        User.execute_as(import_run.user) do
          WorkPackage.transaction do
            created_ids = create_tree!
            import_run.update!(status: :succeeded, created_work_package_ids: created_ids)
            upsert_status(status: :success)
          end
        rescue CreationFailed => e
          import_run.update!(status: :failed, failure: { source_line: e.source_line, message: e.message })
          upsert_status(status: :failure, message: e.message)
        rescue StandardError => e
          # An unexpected error (a bug, a DB blip -- anything not one of the four enumerated
          # CreationFailed kinds) still rolls back the transaction (any exception does), but
          # without this rescue `import_run.status` would never be touched: the run would stay
          # "running" forever and the feature's own `show` page would tell the user their import
          # is still in progress indefinitely, with no record of what actually went wrong. Record
          # what's known and re-raise -- this must not look like a normal, expected failure to
          # whatever's monitoring the job (GoodJob's own retry/error handling, JobStatus's
          # exception listener), only to `import_run`'s own status.
          import_run.update!(status: :failed, failure: { source_line: nil, message: e.message })
          upsert_status(status: :failure, message: e.message)
          raise
        end
      end

      def status_reference
        arguments.first[:import_run]
      end

      def updates_own_status?
        true
      end

      private

      attr_accessor :import_run

      def create_tree! # rubocop:disable Metrics/AbcSize
        document_result = WorkPackages::Import::OutlineParser.call(import_run.source)
        raise CreationFailed.from_error(document_result.errors.first) if document_result.failure?

        resolution = WorkPackages::Import::Resolver.new(project: import_run.project, user: import_run.user)
                                                    .call(document_result.result)
        raise CreationFailed.from_error(resolution.errors.first) if resolution.failure?

        rows = resolution.result
        first_row_error = rows.flat_map(&:errors).first
        raise CreationFailed.from_error(first_row_error) if first_row_error

        created_ids = []

        rows.each_with_index do |row, index|
          parent_id = row.node.parent_index && created_ids[row.node.parent_index]

          result = WorkPackages::CreateService
            .new(user: import_run.user)
            .call(work_package: row.work_package, parent_id:, send_notifications: false)

          if result.failure?
            raise CreationFailed.from_error({ source_line: row.node.source_line,
                                              message: result.errors.full_messages.join(", ") })
          end

          created_ids[index] = result.result.id
        end

        created_ids
      end
    end
  end
end
