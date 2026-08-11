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
    class PreviewComponent < ViewComponent::Base
      DERIVED_ATTRIBUTES = %w[derived_done_ratio derived_estimated_hours derived_remaining_hours].freeze

      def initialize(rows:)
        super()
        @rows = rows
      end

      def any_errors?
        @rows.any? { |row| row.errors.any? }
      end

      def computed_attribute_names(row)
        return [] unless row.work_package

        names = DERIVED_ATTRIBUTES.select { |attr| row.work_package.class.attribute_names.include?(attr) }
        names << "subject" if row.work_package.type&.enabled_patterns&.key?(:subject)
        names
      end

      private

      attr_reader :rows
    end
  end
end
