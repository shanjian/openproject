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
    class Resolver
      class AttributeError < StandardError; end

      ResolvedRow = Struct.new(:node, :work_package, :attribute_matches, :errors)

      BUILTIN_ATTRIBUTE_KEYS = {
        "Accountable" => :responsible_id,
        "Assignee" => :assigned_to_id,
        "Version" => :version_id,
        "Status" => :status_id,
        "Priority" => :priority_id,
        "Start date" => :start_date,
        "Finish date" => :due_date
      }.freeze

      def initialize(project:, user:)
        @project = project
        @user = user
      end

      # A "Project" front matter key is purely informational: the import always targets the
      # project it is run from, so the key is neither validated against it nor inherited into
      # the nodes (OutlineParser#apply_inheritance excludes it).
      def call(document)
        @user_lookup = build_user_lookup
        @department_lookup = build_department_lookup

        ServiceResult.success(result: document.nodes.map { |node| resolve_node(node) })
      end

      private

      def resolve_node(node) # rubocop:disable Metrics/AbcSize
        type = @project.types.find_by(name: node.type_name)

        if type.nil?
          message = "unknown or disabled work package type #{node.type_name.inspect}"
          return ResolvedRow.new(node:, work_package: nil, attribute_matches: [],
                                 errors: [{ source_line: node.source_line, message: }])
        end

        # type_id must be set before any custom-field resolution below: it (together with
        # @project, set via `project:`) is what WorkPackage#available_custom_fields needs to
        # compute the project- and type-aware set of enabled custom fields.
        work_package = WorkPackage.new(project: @project, type_id: type.id)
        attributes = { type_id: type.id, subject: node.subject, description: node.description }
        attribute_matches = []
        errors = []

        node.attributes.each do |label, raw_value|
          resolved = resolve_attribute(work_package, label, raw_value)
          attributes[resolved[:key]] = resolved[:value]
          attribute_matches << { label:, formatted: resolved[:formatted] }
        rescue AttributeError => e
          errors << { source_line: node.source_line, message: "#{label}: #{e.message}" }
        end

        result = WorkPackages::SetAttributesService
          .new(user: @user, model: work_package, contract_class: WorkPackages::CreateContract)
          .call(attributes)

        if result.failure?
          errors.concat(result.errors.full_messages.map do |message|
            { source_line: node.source_line, message: }
          end)
        end

        ResolvedRow.new(node:, work_package: result.result, attribute_matches:, errors:)
      end

      def resolve_attribute(work_package, label, raw_value)
        if BUILTIN_ATTRIBUTE_KEYS.key?(label)
          resolve_builtin_attribute(label, raw_value)
        else
          resolve_custom_field_attribute(work_package, label, raw_value)
        end
      end

      def resolve_builtin_attribute(label, raw_value)
        value =
          case label
          when "Accountable", "Assignee" then resolve_user(raw_value)
          when "Version" then resolve_version(raw_value)
          when "Status" then resolve_status(raw_value)
          when "Priority" then resolve_priority(raw_value)
          when "Start date", "Finish date" then resolve_date(raw_value)
          end

        { key: BUILTIN_ATTRIBUTE_KEYS.fetch(label),
          value: value.is_a?(ActiveRecord::Base) ? value.id : value,
          formatted: format_value(value) }
      end

      def resolve_custom_field_attribute(work_package, label, raw_value) # rubocop:disable Metrics/AbcSize
        # Deliberately goes through the same project- and type-aware availability list that
        # acts_as_customizable's custom_field_<id> accessors are gated on (see
        # WorkPackage.available_custom_fields), not the type-only `type.custom_fields`
        # association: a field enabled for the type but not for this specific project (a normal,
        # separate admin step) must be rejected here too, or SetAttributesService would later
        # silently drop the very attribute this method just reported as resolved.
        custom_field = work_package.available_custom_fields.find { |cf| cf.name == label }
        unless custom_field
          raise AttributeError, "no field named #{label.inspect} on type #{work_package.type.name.inspect}"
        end

        value = case custom_field.field_format
                when "user" then resolve_user(raw_value)
                when "department" then resolve_department(raw_value)
                when "hierarchy" then resolve_hierarchy_value(custom_field, raw_value)
                else convert_custom_value(custom_field, raw_value)
                end

        stored_value = value.is_a?(ActiveRecord::Base) ? value.id.to_s : value

        { key: :"custom_field_#{custom_field.id}", value: stored_value, formatted: format_value(value) }
      end

      def format_value(value)
        case value
        when User then "#{value.name} (#{value.mail})"
        when Group then department_path(value)
        when ActiveRecord::Base then value.respond_to?(:name) ? value.name : value.to_s
        else value.to_s
        end
      end

      # Reuses the path build_department_lookup already computed for every department in one
      # pass (see its comment on why it avoids Group#ancestry_path in the first place) instead of
      # calling #ancestry_path again here -- every resolved department match in a document would
      # otherwise re-trigger the exact per-row query cost that lookup exists to avoid. `value` is
      # always one of the Group records build_department_lookup itself loaded (resolve_department
      # only ever returns those), so the fallback below is defensive, not a normal path.
      def department_path(value)
        @department_lookup[:path_by_id][value.id] || value.ancestry_path
      end

      def resolve_date(raw)
        Date.iso8601(raw.strip)
      rescue ArgumentError
        raise AttributeError, "#{raw.inspect} is not a valid ISO date (YYYY-MM-DD)"
      end

      def resolve_version(raw)
        version = @project.versions.find_by(name: raw.strip)
        raise AttributeError, "no version named #{raw.inspect} in this project" unless version

        version
      end

      def resolve_status(raw)
        status = Status.find_by(name: raw.strip)
        raise AttributeError, "no status named #{raw.inspect}" unless status

        status
      end

      def resolve_priority(raw)
        priority = IssuePriority.find_by(name: raw.strip)
        raise AttributeError, "no priority named #{raw.inspect}" unless priority

        priority
      end

      def convert_custom_value(custom_field, raw)
        case custom_field.field_format
        when "date" then resolve_date(raw).iso8601
        when "int" then Integer(raw.delete("%").strip)
        when "float" then Float(raw.delete("%").strip)
        when "bool" then resolve_bool(raw)
        when "list" then resolve_list_option(custom_field, raw)
        when "version" then resolve_version(raw)
        else raw
        end
      rescue ArgumentError
        raise AttributeError, "#{raw.inspect} is not a valid #{custom_field.field_format} value"
      end

      def resolve_bool(raw)
        case raw.strip.downcase
        when "yes", "true" then true
        when "no", "false" then false
        else raise AttributeError, "#{raw.inspect} is not a valid bool value"
        end
      end

      def resolve_list_option(custom_field, raw)
        option = custom_field.custom_options.find_by(value: raw.strip)
        raise AttributeError, "#{raw.inspect} is not an option of #{custom_field.name}" unless option

        option
      end

      # Hierarchy-format custom values are `CustomField::Hierarchy::Item` records (closure-tree
      # nodes under `custom_field.hierarchy_root`), never `CustomOption`s -- a distinct storage
      # mechanism from the "list" format despite the similar-looking dropdown UI. Matches on the
      # item's full path only ("Parent / Child"), per the documented accepted input for this
      # format; unlike department there is no documented unambiguous-leaf-name shorthand, and
      # hierarchy item labels are only unique within a tree level, not across the whole tree.
      def resolve_hierarchy_value(custom_field, raw)
        raw = raw.strip
        item = hierarchy_items(custom_field).find { |candidate| candidate.ancestry_path == raw }
        raise AttributeError, "no hierarchy value at path #{raw.inspect} for #{custom_field.name}" unless item

        item
      end

      def hierarchy_items(custom_field)
        return [] if custom_field.hierarchy_root.nil?

        CustomFields::Hierarchy::HierarchicalItemService.new
                                                         .get_descendants(item: custom_field.hierarchy_root, include_self: false)
                                                         .value_or([])
      end

      def build_user_lookup
        users = User.where(status: User.statuses[:active]).to_a
        {
          by_mail: users.index_by { |u| u.mail.to_s.downcase },
          by_name: users.group_by { |u| u.name.downcase }
        }
      end

      def resolve_user(raw)
        raw = raw.strip
        raw.include?("@") ? resolve_user_by_mail(raw) : resolve_user_by_name(raw)
      end

      def resolve_user_by_mail(raw)
        user = @user_lookup[:by_mail][raw.downcase]
        raise AttributeError, "no user found with email #{raw.inspect}" unless user

        user
      end

      def resolve_user_by_name(raw)
        matches = @user_lookup[:by_name][raw.downcase] || []
        raise AttributeError, "no user found named #{raw.inspect}" if matches.empty?
        raise AttributeError, "#{raw.inspect} matches more than one user" if matches.size > 1

        matches.first
      end

      def build_department_lookup
        departments = Group.organizational_units.in_tree_order
        by_path = {}
        path_by_id = {}
        path_by_depth = []

        # Build each department's "Root / Child / Leaf" path from the already
        # depth-first-ordered, in-memory tree, instead of calling #ancestry_path
        # (which issues its own recursive query per group). in_tree_order sets
        # hierarchy_depth as it walks, so a stack indexed by depth is enough to
        # reconstruct every ancestor without touching the database again.
        #
        # path_by_id is kept alongside by_path/by_leaf_name so format_value can look up a
        # resolved department's display path the same way, without calling #ancestry_path a
        # second time per formatted match (see format_value/department_path).
        departments.each do |department|
          path_by_depth[department.hierarchy_depth] = department.name
          path = path_by_depth[0..department.hierarchy_depth].join(" / ")
          by_path[path] = department
          path_by_id[department.id] = path
        end

        {
          by_leaf_name: departments.group_by(&:name),
          by_path:,
          path_by_id:
        }
      end

      def resolve_department(raw)
        raw = raw.strip
        raw.include?("/") ? resolve_department_by_path(raw) : resolve_department_by_leaf_name(raw)
      end

      def resolve_department_by_path(raw)
        department = @department_lookup[:by_path][raw]
        raise AttributeError, "no organizational unit at path #{raw.inspect}" unless department

        department
      end

      def resolve_department_by_leaf_name(raw)
        matches = @department_lookup[:by_leaf_name][raw] || []
        raise AttributeError, "no organizational unit named #{raw.inspect}" if matches.empty?
        if matches.size > 1
          raise AttributeError, "#{raw.inspect} matches more than one organizational unit; use the full path"
        end

        matches.first
      end
    end
  end
end
