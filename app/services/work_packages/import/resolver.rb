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

      def initialize(project:, user:)
        @project = project
        @user = user
      end

      private

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

      def convert_custom_value(custom_field, raw) # rubocop:disable Metrics/AbcSize
        case custom_field.field_format
        when "date" then resolve_date(raw).iso8601
        when "int" then Integer(raw.delete("%").strip)
        when "float" then Float(raw.delete("%").strip)
        when "bool" then %w[yes true].include?(raw.strip.downcase)
        when "list" then resolve_list_option(custom_field, raw)
        else raw
        end
      rescue ArgumentError
        raise AttributeError, "#{raw.inspect} is not a valid #{custom_field.field_format} value"
      end

      def resolve_list_option(custom_field, raw)
        option = custom_field.custom_options.find_by(value: raw.strip)
        raise AttributeError, "#{raw.inspect} is not an option of #{custom_field.name}" unless option

        option
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
        path_by_depth = []

        # Build each department's "Root / Child / Leaf" path from the already
        # depth-first-ordered, in-memory tree, instead of calling #ancestry_path
        # (which issues its own recursive query per group). in_tree_order sets
        # hierarchy_depth as it walks, so a stack indexed by depth is enough to
        # reconstruct every ancestor without touching the database again.
        departments.each do |department|
          path_by_depth[department.hierarchy_depth] = department.name
          by_path[path_by_depth[0..department.hierarchy_depth].join(" / ")] = department
        end

        {
          by_leaf_name: departments.group_by(&:name),
          by_path:
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
