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
  class UpdateWorkPackage < Base
    include WorkPackageWriter

    default_title "Update work package"
    default_description "Update a work package in place, as the authenticated user. Send only the attributes that " \
                        "change, plus the `lockVersion` you read it with: if someone changed it since, the update " \
                        "is refused, so read it again and retry. #{WorkPackageWriter.supported_attributes_hint} " \
                        "The project cannot be changed. People who watch, are assigned to, or are responsible for " \
                        "it are notified, as in the UI."

    LOCK_VERSION_REQUIRED = "lockVersion is required: read the work package first and send its current lockVersion."

    name "update_work_package"
    # An edit overwrites fields. The journal keeps the old values, but a client should still be able to ask
    # the person before it runs, which is what the destructive hint is for.
    annotations read_only: false, idempotent: true, destructive: true

    input_schema(
      additionalProperties: false,
      required: %w[id data],
      properties: {
        id: {
          type: %w[string number],
          description: "The ID of the work package to update."
        },
        data: {
          type: "object",
          description: "JSON representation of the changes, in the format APIv3 accepts, limited to the supported " \
                       "attributes. Only attributes that shall be changed need to be included.",
          required: %w[lockVersion],
          properties: {
            lockVersion: {
              type: "number",
              description: "The lockVersion the work package had when you read it. It guards against overwriting " \
                           "someone else's change: if it is stale the update is refused, so read the work package " \
                           "again and apply your change to its new state."
            },
            _links: {
              description: "Related resources such as the type, status, priority and assignee. Each is an object " \
                           "with an 'href' property."
            }
          }
        }
      }
    )

    output_filter McpOutputFilters::RemoveFormattableHtml.new
    output_filter McpOutputFilters::RemoveWorkPackageActionLinks.new

    def call(id:, data:)
      work_package = WorkPackage.visible(current_user).find_by(id:)
      return failure("The given work package could not be found.") if work_package.nil?

      attributes = checked_attributes(data, creating: false)
      return attributes if attributes.is_a?(McpTools::Failure)
      return failure(LOCK_VERSION_REQUIRED) if attributes[:lock_version].nil?

      update(work_package, attributes)
    rescue ActiveRecord::StaleObjectError
      failure("The work package was changed since you read it. Read it again and retry with its current lockVersion.")
    end

    private

    def update(work_package, attributes)
      # Base.name is the tool's name, e.g. "update_work_package"
      cause = Journal::CausedByMcp.new(tool: self.class.name)
      result = WorkPackages::UpdateService.new(user: current_user, model: work_package)
                                          .call(**attributes, journal_cause: cause)

      result.failure? ? failure(error_text(result)) : represent(result.result)
    end
  end
end
