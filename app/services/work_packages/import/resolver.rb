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

      ResolvedRow = Struct.new(:node, :work_package, :attribute_matches, :errors,
                               :duplicate, :department_values)

      # Imported items default to this status (when the instance has one) instead of the
      # instance-wide default status. An explicit `Status:` attribute in the document wins.
      # Note that SetAttributesService#reassign_invalid_status_if_type_changed still reverts
      # any status that is not part of the item type's workflows (or the instance default),
      # so "Draft" must be included in the OKR types' workflows to actually stick.
      DEFAULT_STATUS_NAME = "Draft"

      BUILTIN_ATTRIBUTE_KEYS = {
        "Accountable" => :responsible_id,
        "Assignee" => :assigned_to_id,
        "Version" => :version_id,
        "Status" => :status_id,
        "Priority" => :priority_id,
        "Start date" => :start_date,
        "Finish date" => :due_date
      }.freeze

      # Short-hand type names accepted in a heading in place of the real work package type name.
      TYPE_NAME_ALIASES = {
        "KR" => "Key Result"
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

        rows = document.nodes.map { |node| resolve_node(node) }
        mark_duplicates(rows)

        ServiceResult.success(result: rows)
      end

      private

      def resolve_node(node) # rubocop:disable Metrics/AbcSize,Metrics/PerceivedComplexity
        type = @project.types.find_by(name: TYPE_NAME_ALIASES.fetch(node.type_name, node.type_name))

        if type.nil?
          message = "unknown or disabled work package type #{node.type_name.inspect}"
          return ResolvedRow.new(node:, work_package: nil, attribute_matches: [],
                                 errors: [{ source_line: node.source_line, message: }])
        end

        # type_id must be set before any custom-field resolution below: it (together with
        # @project, set via `project:`) is what WorkPackage#available_custom_fields needs to
        # compute the project- and type-aware set of enabled custom fields.
        work_package = WorkPackage.new(project: @project, type_id: type.id)
        # skip_templated_description: an imported node without prose must stay without a
        # description; SetAttributesService would otherwise fill in the type's default text.
        attributes = { type_id: type.id, subject: node.subject, description: node.description,
                       skip_templated_description: true }
        attributes[:status_id] = default_status_id if default_status_id && !node.attributes.key?("Status")
        attribute_matches = []
        errors = []
        department_values = []

        node.attributes.each do |label, raw_value|
          inherited = node.inherited_keys&.include?(label) || false
          resolved = resolve_attribute(work_package, label, raw_value, inherited:)
          next unless resolved

          attributes[resolved[:key]] = resolved[:value]
          department_values << resolved[:value].to_s if resolved[:department]
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

        ResolvedRow.new(node:, work_package: result.result, attribute_matches:, errors:, department_values:)
      end

      def default_status_id
        return @default_status_id if defined?(@default_status_id)

        @default_status_id = Status.find_by(name: DEFAULT_STATUS_NAME)&.id
      end

      # Marks rows that duplicate either an existing work package of the project or an earlier
      # row of the same document, keyed on the department ("Organization Unit") custom field
      # values plus the case-folded subject. Marked rows are skipped by CreateJob and reported
      # as warnings; their children are re-parented onto the duplicate's target.
      def mark_duplicates(rows) # rubocop:disable Metrics/AbcSize
        keyed = []
        rows.each_with_index do |row, index|
          next unless row.work_package && row.node.subject.present?
          # The heading subject never persists for a type with an enabled subject pattern
          # (Types::ApplyPatterns overwrites it after save), so it cannot identify
          # duplicates: identical headings still yield distinct generated subjects.
          next if row.work_package.type&.replacement_pattern_defined_for?(:subject)

          keyed << [dedup_key(row), row, index]
        end
        return if keyed.empty?

        existing = existing_work_package_ids_by_key(keyed.map(&:first))
        seen = {}

        keyed.each do |key, row, index|
          row.duplicate = duplicate_for(key, existing, seen)
          seen[key] = index unless row.duplicate
        end
      end

      def duplicate_for(key, existing, seen)
        if (work_package_id = existing[key])
          { kind: :existing, work_package_id: }
        elsif (original_index = seen[key])
          { kind: :in_document, node_index: original_index }
        end
      end

      def dedup_key(row)
        [row.department_values.sort, row.node.subject.downcase]
      end

      # One batched lookup instead of a query per row: fetch every work package of the project
      # whose subject case-insensitively matches any subject of the document, then their
      # department custom values, and index them by the same key #dedup_key produces. The oldest
      # match wins so re-imports keep pointing children at the original work package.
      def existing_work_package_ids_by_key(keys) # rubocop:disable Metrics/AbcSize
        subjects = keys.map(&:last).uniq
        work_packages = WorkPackage
                          .where(project: @project)
                          .where("LOWER(work_packages.subject) IN (?)", subjects)
                          .order(:id)
                          .pluck(:id, :subject)
        return {} if work_packages.empty?

        department_values = department_values_by_work_package_id(work_packages.map(&:first))

        work_packages.each_with_object({}) do |(id, subject), result|
          key = [(department_values[id] || []).map(&:last).sort, subject.downcase]
          result[key] ||= id
        end
      end

      def department_values_by_work_package_id(work_package_ids)
        CustomValue
          .where(customized_type: "WorkPackage",
                 customized_id: work_package_ids,
                 custom_field_id: WorkPackageCustomField.where(field_format: "department"))
          .where.not(value: [nil, ""])
          .pluck(:customized_id, :value)
          .group_by(&:first)
      end

      def resolve_attribute(work_package, label, raw_value, inherited:)
        if BUILTIN_ATTRIBUTE_KEYS.key?(label)
          resolve_builtin_attribute(label, raw_value)
        else
          resolve_custom_field_attribute(work_package, label, raw_value, inherited:)
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

      def resolve_custom_field_attribute(work_package, label, raw_value, inherited:) # rubocop:disable Metrics/AbcSize
        # Deliberately goes through the same project- and type-aware availability list that
        # acts_as_customizable's custom_field_<id> accessors are gated on (see
        # WorkPackage.available_custom_fields), not the type-only `type.custom_fields`
        # association: a field enabled for the type but not for this specific project (a normal,
        # separate admin step) must be rejected here too, or SetAttributesService would later
        # silently drop the very attribute this method just reported as resolved.
        custom_field = work_package.available_custom_fields.find { |cf| cf.name == label }
        if custom_field.nil?
          # An inherited attribute (front matter or an ancestor's own bullet) is a document-wide
          # default, not something this node asked for -- a type it does not apply to should
          # silently ignore it instead of failing the row. Only a bullet the node wrote itself
          # can be genuinely wrong.
          return nil if inherited

          raise AttributeError, "no field named #{label.inspect} on type #{work_package.type.name.inspect}"
        end

        value = case custom_field.field_format
                when "user" then resolve_user(raw_value)
                when "department" then resolve_department(raw_value)
                when "hierarchy" then resolve_hierarchy_value(custom_field, raw_value)
                else convert_custom_value(custom_field, raw_value)
                end

        stored_value = value.is_a?(ActiveRecord::Base) ? value.id.to_s : value

        { key: :"custom_field_#{custom_field.id}", value: stored_value, formatted: format_value(value),
          department: custom_field.department? }
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
