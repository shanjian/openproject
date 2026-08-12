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
      DATE_LABELS = ["Start date", "Finish date"].freeze

      def initialize(rows:)
        super()
        @rows = rows
      end

      def any_errors?
        @rows.any? { |row| row.errors.any? }
      end

      # `index` is this row's position within the full `rows` array (its `node.parent_index`
      # points at other rows by that same position) -- callers must iterate with
      # `rows.each_with_index`, not `rows.each`, since "has children" only makes sense relative to
      # the whole tree, not a single row in isolation.
      def computed_attribute_names(row, index)
        return [] unless row.work_package

        names = DERIVED_ATTRIBUTES.select { |attr| row.work_package.class.attribute_names.include?(attr) }
        # A row with at least one child never keeps the dates resolved into its `work_package`:
        # WorkPackages::Import::CreateJob creates rows top-down, and each child's creation runs
        # `multi_update_ancestors`/`reschedule_related` (see WorkPackage's scheduling callbacks),
        # which silently rewrites the parent's start_date/due_date once the child actually exists.
        # Since this whole feature exists to import hierarchies, this applies to every non-leaf row.
        names.push("start_date", "due_date") if has_children?(index)
        names
      end

      # Rows with a child list "start_date"/"due_date" in `computed_attribute_names` (see above);
      # showing the author's typed "Start date: 2026-01-01" from `attribute_matches` right next to
      # "start_date: computed on creation" for the same row is contradictory, so those two labels
      # are dropped from the exact-value list wherever the computed marker is about to appear.
      def attribute_matches_for(row, index)
        return row.attribute_matches unless has_children?(index)

        row.attribute_matches.reject { |match| DATE_LABELS.include?(match[:label]) }
      end

      # `Types::ApplyPatterns#apply_patterns` (create_service.rb) overwrites `subject` from the
      # type's pattern strictly AFTER save -- the typed heading shown as this row's header is
      # exactly as unreliable here as start_date/due_date are for a row with children, and for the
      # same reason: it's a real, resolved value, but not the one that will actually persist. The
      # header renders this instead of `row.node.subject` when true, rather than showing both (the
      # typed heading is what `subject_computed?` replaces here, not a duplicate of the generic
      # "computed on creation" sub-list, which handles the derived/date fields separately).
      def subject_computed?(row)
        return false unless row.work_package

        row.work_package.type&.enabled_patterns&.key?(:subject) || false
      end

      private

      attr_reader :rows

      def has_children?(index)
        rows.any? { |row| row.node.parent_index == index }
      end
    end
  end
end
