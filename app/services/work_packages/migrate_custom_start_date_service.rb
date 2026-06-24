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
  # One-time migration: copy the values of a date custom field (e.g. a legacy
  # custom "Start date") into the built-in start_date.
  #
  # - Fills only when the built-in start_date is blank (never overwrites an
  #   existing scheduled start).
  # - Skips rows where the imported date would be after the due date (start must
  #   be <= due).
  # - Writes directly to the columns (update_columns): no journal entry, no
  #   validations, and no scheduling cascade -- this is a data backfill, not a
  #   new activity. When a due date is present, the duration column is
  #   recomputed so the row stays consistent.
  #
  # Run with apply: false (default) to only collect the report.
  class MigrateCustomStartDateService
    Report = Struct.new(
      :custom_field_id, :custom_field_name, :apply,
      :total_with_value, :unparseable,
      :builtin_set_same, :builtin_set_differ,
      :conflicts, :to_fill, :filled
    ) do
      def builtin_blank
        to_fill + conflicts.size
      end

      def builtin_set
        builtin_set_same + builtin_set_differ
      end

      def to_s
        <<~TEXT.chomp
          Custom field: "#{custom_field_name}" (id=#{custom_field_id})
          Mode: #{apply ? 'APPLY (changes written)' : 'DRY RUN (no changes written)'}

          Work packages with a value in the custom field: #{total_with_value}
            - unparseable value (skipped):                #{unparseable}
            - built-in Start date already set (skipped):  #{builtin_set}
                * same as custom value:                   #{builtin_set_same}
                * differs from custom value:              #{builtin_set_differ}
            - built-in Start date blank:                  #{builtin_blank}
                * start would be after Due date (skipped):#{conflicts.size}
                * eligible to fill:                       #{to_fill}
          #{apply ? "Filled: #{filled}" : "Would fill: #{to_fill}"}
        TEXT
      end
    end

    def initialize(custom_field:, apply: false)
      @custom_field = custom_field
      @apply = apply
    end

    def call
      ensure_date_custom_field!

      report = new_report

      custom_values.find_each do |custom_value|
        work_package = custom_value.customized
        next unless work_package.is_a?(WorkPackage)

        report.total_with_value += 1
        classify(work_package, parse_date(custom_value), report)
      end

      report
    end

    private

    attr_reader :custom_field, :apply

    def classify(work_package, date, report)
      if date.nil?
        report.unparseable += 1
      elsif work_package.start_date.present?
        skip_already_set(work_package, date, report)
      elsif work_package.due_date && date > work_package.due_date
        report.conflicts << work_package.id
      else
        report.to_fill += 1
        fill!(work_package, date) && (report.filled += 1) if apply
      end
    end

    def skip_already_set(work_package, date, report)
      if work_package.start_date == date
        report.builtin_set_same += 1
      else
        report.builtin_set_differ += 1
      end
    end

    def fill!(work_package, date)
      attributes = { start_date: date }
      # keep duration consistent when both ends are now known
      attributes[:duration] = days_for(work_package).duration(date, work_package.due_date) if work_package.due_date

      work_package.update_columns(attributes)
    end

    def new_report
      Report.new(
        custom_field_id: custom_field.id,
        custom_field_name: custom_field.name,
        apply:,
        total_with_value: 0,
        unparseable: 0,
        builtin_set_same: 0,
        builtin_set_differ: 0,
        conflicts: [],
        to_fill: 0,
        filled: 0
      )
    end

    def custom_values
      CustomValue
        .where(customized_type: "WorkPackage", custom_field_id: custom_field.id)
        .where.not(value: [nil, ""])
        .includes(:customized)
    end

    def parse_date(custom_value)
      value = custom_value.typed_value
      value.is_a?(Date) ? value : nil
    rescue StandardError
      nil
    end

    def days_for(work_package)
      WorkPackages::Shared::Days.for(work_package)
    end

    def ensure_date_custom_field!
      return if custom_field.is_a?(WorkPackageCustomField) && custom_field.field_format == "date"

      raise ArgumentError, "Expected a date WorkPackageCustomField, got: #{custom_field.inspect}"
    end
  end
end
