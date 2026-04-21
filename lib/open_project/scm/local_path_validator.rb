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

module OpenProject
  module SCM
    module LocalPathValidator
      module_function

      def points_to_openproject_directory?(value)
        path = local_path(value)
        return false if path.blank?

        forbidden_roots.any? { |root| path_within_root?(path, root) }
      end

      def local_path(value)
        return if value.blank?

        parsed = URI.parse(value)

        if parsed.scheme == "file"
          return File.expand_path(parsed.path)
        end

        return File.expand_path(value) if parsed.scheme.nil? && value.start_with?("/")
      rescue URI::Error
        return
      end

      def forbidden_roots
        roots = [
          OpenProject::Configuration.scm_local_checkout_path,
          Repository::Git.managed_root,
          Repository::Subversion.managed_root
        ]

        roots.compact_blank.map { |root| File.expand_path(root) }.uniq
      end

      def path_within_root?(path, root)
        path == root || path.start_with?("#{root}/")
      end
    end
  end
end
