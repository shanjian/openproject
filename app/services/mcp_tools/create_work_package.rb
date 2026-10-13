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
  class CreateWorkPackage < Base
    include WorkPackageWriter

    default_title "Create work package"
    default_description "Create a new work package, as the authenticated user. `data` is the APIv3 JSON of the " \
                        "work package, limited to a supported subset; the project is given as a link in _links. " \
                        "#{WorkPackageWriter.supported_attributes_hint} " \
                        "People who are assigned to or responsible for it are notified, as in the UI."

    name "create_work_package"
    annotations read_only: false, idempotent: false, destructive: false

    input_schema(
      additionalProperties: false,
      required: %i[data],
      properties: {
        data: {
          type: "object",
          description: "JSON representation of the work package to create, in the format APIv3 accepts, limited to " \
                       "the supported attributes. A project and a type are needed.",
          properties: {
            _links: {
              description: "Related resources such as the project, type, status, priority and assignee. Each is an " \
                           "object with an 'href' property."
            }
          }
        }
      }
    )

    output_filter McpOutputFilters::RemoveFormattableHtml.new
    output_filter McpOutputFilters::RemoveWorkPackageActionLinks.new

    def call(data:)
      attributes = checked_attributes(data, creating: true)
      return attributes if attributes.is_a?(McpTools::Failure)

      # Base.name is the tool's name, e.g. "create_work_package"
      cause = Journal::CausedByMcp.new(tool: self.class.name)
      result = WorkPackages::CreateService.new(user: current_user).call(**attributes, journal_cause: cause)
      return failure(error_text(result)) if result.failure?

      represent(result.result)
    end
  end
end
