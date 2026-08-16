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
      def initialize(rows:)
        super()
        @rows = rows
      end

      # Duplicate rows are skipped by CreateJob without being validated, so their
      # resolution errors must not block the confirm button (CreateJob likewise
      # excludes them from its own error check).
      def any_errors?
        @rows.any? { |row| row.duplicate.nil? && row.errors.any? }
      end

      # `Types::ApplyPatterns#apply_patterns` (create_service.rb) overwrites `subject` from the
      # type's pattern strictly AFTER save -- the typed heading is a real, resolved value, but
      # not the one that will actually persist, so the header renders a "computed on creation"
      # marker instead of `row.node.subject` when true.
      #
      # This is deliberately the only computed-value marker left in the preview: derived_* fields
      # and the scheduling rewrite of a parent row's dates (multi_update_ancestors/
      # reschedule_related on child creation) are NOT surfaced -- listing them for every row read
      # as noise rather than information.
      def subject_computed?(row)
        return false unless row.work_package

        row.work_package.type&.enabled_patterns&.key?(:subject) || false
      end

      def duplicate_notice(row)
        if row.duplicate[:kind] == :existing
          t("work_packages.import.preview.duplicate_existing", id: row.duplicate[:work_package_id])
        else
          t("work_packages.import.preview.duplicate_in_document",
            line: rows[row.duplicate[:node_index]].node.source_line)
        end
      end

      private

      attr_reader :rows
    end
  end
end
