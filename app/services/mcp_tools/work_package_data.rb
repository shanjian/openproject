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
  # What an assistant may put in the `data` of create_work_package and update_work_package.
  #
  # An allowlist, checked twice. The APIv3 payload parser accepts more than the representer calls writable
  # (attachments, file links, author, timestamps), and drops what it does not know without a word. A denylist
  # would miss the former and a check of parsed attributes alone would hide the latter.
  #
  # 1. #unsupported_keys: what the assistant *sent*. Refuses typos, `watchers`, `meta`, `_type`, `id` and the
  #    rest, so a call can never report success for something that was silently ignored.
  # 2. #unsupported_parsed_keys: what ParseParamsService *produced*. A backstop for a supported raw key that
  #    maps to an attribute nobody intended.
  #
  # New properties, from an upgrade or a module, are refused until someone adds them here.
  class WorkPackageData
    ATTRIBUTES = %w[
      subject description lockVersion startDate dueDate duration estimatedTime remainingTime percentageDone
      scheduleManually ignoreNonWorkingDays storyPoints
    ].freeze
    LINKS = %w[type status priority assignee responsible parent version category epic].freeze
    CREATE_ONLY_LINKS = %w[project].freeze
    CUSTOM_FIELD = /\AcustomField\d+\z/

    PARSED_KEYS = %i[
      lock_version subject description type_id status_id priority_id assigned_to_id responsible_id parent
      version_id category_id epic start_date due_date duration estimated_hours remaining_hours done_ratio
      schedule_manually ignore_non_working_days story_points
    ].freeze
    PARSED_CREATE_ONLY_KEYS = %i[project_id].freeze
    PARSED_CUSTOM_FIELD = /\Acustom_field_\d+\z/

    def initialize(data, creating:)
      @data = data
      @creating = creating
    end

    # @return [Array<String>] the keys the tools do not support, as the assistant wrote them, links as
    #   "_links.name". Empty when everything sent is supported.
    def unsupported_keys
      return ["data"] unless data.respond_to?(:to_hash)

      data.to_hash.deep_stringify_keys.flat_map do |key, value|
        if key == "_links"
          unsupported_link_keys(value)
        else
          attribute?(key) ? [] : [key]
        end
      end
    end

    # @param parsed [Hash] what API::V3::WorkPackages::ParseParamsService produced
    # @return [Array<Symbol>]
    def unsupported_parsed_keys(parsed)
      parsed.keys.reject { |key| parsed_key?(key) }
    end

    def message(unsupported = unsupported_keys)
      "These attributes cannot be set through this tool: #{unsupported.join(', ')}. " \
        "Supported: #{ATTRIBUTES.join(', ')}, customField<id>; and inside _links: #{links.join(', ')}, " \
        "customField<id>. Send only the attributes you want to change."
    end

    private

    attr_reader :data

    def creating? = @creating

    def links
      creating? ? CREATE_ONLY_LINKS + LINKS : LINKS
    end

    def attribute?(key)
      ATTRIBUTES.include?(key) || CUSTOM_FIELD.match?(key)
    end

    def link?(key)
      links.include?(key) || CUSTOM_FIELD.match?(key)
    end

    def unsupported_link_keys(value)
      return ["_links"] unless value.respond_to?(:to_hash)

      value.to_hash.keys.map(&:to_s).reject { |key| link?(key) }.map { |key| "_links.#{key}" }
    end

    def parsed_key?(key)
      PARSED_KEYS.include?(key) ||
        (creating? && PARSED_CREATE_ONLY_KEYS.include?(key)) ||
        PARSED_CUSTOM_FIELD.match?(key.to_s)
    end
  end
end
