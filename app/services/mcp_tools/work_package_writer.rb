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
  # What create_work_package and update_work_package share: refusing what the tools do not support, and
  # turning APIv3 JSON into the attributes the work package services take.
  module WorkPackageWriter
    # The core assigns a default type, status and priority when one is empty, and an ID that does not exist
    # counts as empty. APIv3 does the same, but an assistant that guessed an ID must not be told it succeeded
    # while a work package of another type was made.
    DEFAULTED = {
      type_id: [::Type, "type", "list_types"],
      status_id: [::Status, "status", "list_statuses"],
      priority_id: [::IssuePriority, "priority", "list_priorities"]
    }.freeze

    # For the tool descriptions: the model reads these to decide what to send.
    def self.supported_attributes_hint
      "Supported attributes: #{WorkPackageData::ATTRIBUTES.join(', ')}, customField<id>. " \
        "Supported links, inside _links: #{WorkPackageData::LINKS.join(', ')}, customField<id>. " \
        "Resolve IDs with the search and list tools first; never guess one. Formatted text such as the " \
        "description is an object, {\"raw\": \"...\"}. Attachments, file links, watchers and comments cannot " \
        "be set here."
    end

    private

    # @return [Hash, McpTools::Failure] the attributes for the service, or why there are none
    def checked_attributes(data, creating:)
      data = data.to_hash.deep_stringify_keys if data.respond_to?(:to_hash)
      checker = WorkPackageData.new(data, creating:)

      refusal_before_parsing(checker) || parsed_and_checked(data, checker)
    rescue API::Errors::ErrorBase => e
      # A link the parser cannot read, e.g. an href that is not an APIv3 resource.
      failure(e.message)
    end

    def parsed_and_checked(data, checker)
      parsed = API::V3::WorkPackages::ParseParamsService.new(current_user, model: WorkPackage).call(data)
      return failure(error_text(parsed)) if parsed.failure?

      refusal_after_parsing(checker, parsed.result) || parsed.result
    end

    def refusal_before_parsing(checker)
      unsupported = checker.unsupported_keys

      failure(checker.message(unsupported)) if unsupported.any?
    end

    def refusal_after_parsing(checker, attributes)
      unsupported = checker.unsupported_parsed_keys(attributes)
      return failure("Unsupported after parsing: #{unsupported.join(', ')}.") if unsupported.any?

      unknown = unknown_defaulted_records(attributes)
      failure(unknown.join(" ")) if unknown.any?
    end

    def unknown_defaulted_records(attributes)
      DEFAULTED.filter_map do |key, (model, noun, list_tool)|
        id = attributes[key]
        next if id.blank? || model.exists?(id)

        "There is no #{noun} with ID #{id}; nothing was written. Look the ID up with #{list_tool}."
      end
    end

    def error_text(result)
      text = super
      text += " Read the work package again and retry with its current lockVersion." if conflict?(result)
      text
    end

    # The contract's own wording says only that someone else changed it. An assistant needs to be told what to do.
    def conflict?(result)
      result.errors.details[:base].to_a.any? { |detail| detail[:error] == :error_conflict }
    end

    def represent(work_package)
      API::V3::WorkPackages::WorkPackageRepresenter.create(work_package, current_user:)
    end
  end
end
