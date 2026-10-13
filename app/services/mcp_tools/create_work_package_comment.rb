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
  class CreateWorkPackageComment < Base
    default_title "Create work package comment"
    default_description "Add a comment to a work package, as the authenticated user. The comment is shown to " \
                        "everyone who can see the work package, unless `internal` is true. People who watch the " \
                        "work package, are assigned to it, or are mentioned are notified, as in the UI. A comment " \
                        "cannot be edited or deleted afterwards. Never copy text from an internal comment into a " \
                        "public one."

    name "create_work_package_comment"
    annotations read_only: false, idempotent: false, destructive: false

    input_schema(
      additionalProperties: false,
      required: %i[work_package_id comment],
      properties: {
        work_package_id: {
          type: %w[string number],
          description: "The ID of the work package to comment on."
        },
        comment: {
          type: "string",
          description: "The text of the comment."
        },
        internal: {
          type: "boolean",
          description: "Whether only users who may read internal comments see this one. Default: false. Needs the " \
                       "internal comments feature, enabled for the project, and the permission to add them."
        }
      }
    )

    output_filter McpOutputFilters::RemoveActivityDetails.new
    output_filter McpOutputFilters::RemoveFormattableHtml.new
    output_filter McpOutputFilters::RemoveLinks.new(%w[update addAttachment])

    def call(work_package_id:, comment:, internal: false)
      work_package = WorkPackage.visible(current_user).find_by(id: work_package_id)
      return failure("The given work package could not be found.") if work_package.nil?

      # The contract also accepts edit_work_packages. The UI does not: it needs this permission. Match the UI.
      unless current_user.allowed_in_work_package?(:add_work_package_comments, work_package)
        return failure("You are not allowed to comment on this work package.")
      end

      comment = without_unmentionable_mentions(work_package, comment) if internal

      add_comment(work_package, comment, internal)
    end

    private

    def add_comment(work_package, comment, internal)
      # Base.name is the tool's name, e.g. "create_work_package_comment"
      cause = Journal::CausedByMcp.new(tool: self.class.name)
      result = AddWorkPackageNoteService.new(user: current_user, work_package:).call(comment, internal:, cause:)

      result.failure? ? failure(error_text(result)) : API::V3::Activities::ActivityRepresenter.new(result.result, current_user:)
    end

    # What the UI does for an internal comment: a mention of someone who cannot read internal comments
    # becomes plain text, so the comment does not reach into people it is meant to be hidden from.
    def without_unmentionable_mentions(work_package, comment)
      User.execute_as(current_user) do
        WorkPackages::ActivitiesTab::InternalCommentMentionsSanitizer.sanitize(work_package, comment)
      end
    end
  end
end
