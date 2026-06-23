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

require "spec_helper"

RSpec.describe WorkPackages::MigrateCustomStartDateService, type: :model do
  shared_let(:start_cf) { create(:work_package_custom_field, field_format: "date", is_for_all: true) }
  shared_let(:type) { create(:type, custom_fields: [start_cf]) }
  shared_let(:project) { create(:project, types: [type]) }

  subject(:report) { described_class.new(custom_field: start_cf, apply:).call }

  let(:apply) { false }

  # Creates a work package with the exact built-in date state and a custom-field value.
  def work_package_with(custom_value:, start_date: nil, due_date: nil, ignore_non_working_days: true)
    wp = create(:work_package, project:, type:, ignore_non_working_days:)
    wp.update_columns(start_date:, due_date:, duration: nil)
    if custom_value
      CustomValue.create!(customized: wp, custom_field: start_cf, value: custom_value)
    end
    wp
  end

  describe "reporting (dry run)" do
    let!(:fillable) { work_package_with(custom_value: "2026-06-01", start_date: nil, due_date: Date.new(2026, 6, 5)) }
    let!(:fillable_no_due) { work_package_with(custom_value: "2026-06-01", start_date: nil, due_date: nil) }
    let!(:already_same) do
      work_package_with(custom_value: "2026-06-01", start_date: Date.new(2026, 6, 1), due_date: Date.new(2026, 6, 5))
    end
    let!(:already_differ) do
      work_package_with(custom_value: "2026-06-01", start_date: Date.new(2026, 5, 1), due_date: Date.new(2026, 6, 5))
    end
    let!(:conflict) { work_package_with(custom_value: "2026-06-10", start_date: nil, due_date: Date.new(2026, 6, 5)) }
    let!(:no_value) { work_package_with(custom_value: nil, start_date: nil, due_date: Date.new(2026, 6, 5)) }

    it "counts each case without writing anything" do
      aggregate_failures do
        expect(report.total_with_value).to eq 5 # excludes no_value
        expect(report.unparseable).to eq 0
        expect(report.builtin_set_same).to eq 1
        expect(report.builtin_set_differ).to eq 1
        expect(report.conflicts).to contain_exactly(conflict.id)
        expect(report.builtin_blank).to eq 3 # fillable + fillable_no_due + conflict
        expect(report.to_fill).to eq 2 # fillable + fillable_no_due (conflict excluded)
      end
    end

    it "treats both blank-and-no-conflict rows as fillable" do
      # fillable (due set, start <= due) and fillable_no_due (no due) are both eligible
      expect(report.to_fill).to eq 2
      expect(report.filled).to eq 0 # dry run
    end

    it "does not modify the database" do
      report
      expect(fillable.reload.start_date).to be_nil
      expect(fillable_no_due.reload.start_date).to be_nil
    end

    context "with an unparseable custom value" do
      let!(:broken) { work_package_with(custom_value: "2026-06-01", start_date: nil) }

      before { broken.custom_values.find_by(custom_field: start_cf).update_column(:value, "not-a-date") }

      it "counts it as unparseable and does not fill" do
        expect(report.unparseable).to eq 1
      end
    end
  end

  describe "applying the migration" do
    let(:apply) { true }

    let!(:fillable) { work_package_with(custom_value: "2026-06-01", start_date: nil, due_date: Date.new(2026, 6, 5)) }
    let!(:fillable_no_due) { work_package_with(custom_value: "2026-06-02", start_date: nil, due_date: nil) }
    let!(:already_set) do
      work_package_with(custom_value: "2026-06-01", start_date: Date.new(2026, 5, 1), due_date: Date.new(2026, 6, 5))
    end
    let!(:conflict) { work_package_with(custom_value: "2026-06-10", start_date: nil, due_date: Date.new(2026, 6, 5)) }

    it "fills the blank built-in start_date from the custom value" do
      report
      expect(fillable.reload.start_date).to eq Date.new(2026, 6, 1)
      expect(fillable_no_due.reload.start_date).to eq Date.new(2026, 6, 2)
    end

    it "recomputes duration when a due date is present (and leaves it nil otherwise)" do
      report
      # 2026-06-01..2026-06-05 inclusive, ignoring non-working days => 5
      expect(fillable.reload.duration).to eq 5
      expect(fillable_no_due.reload.duration).to be_nil
    end

    it "never overwrites an already-set built-in start_date" do
      report
      expect(already_set.reload.start_date).to eq Date.new(2026, 5, 1)
    end

    it "skips rows where the start would be after the due date" do
      report
      expect(conflict.reload.start_date).to be_nil
      expect(report.conflicts).to contain_exactly(conflict.id)
    end

    it "reports the number actually filled" do
      expect(report.filled).to eq 2
    end

    it "is idempotent (a second run fills nothing more)" do
      report
      second = described_class.new(custom_field: start_cf, apply: true).call
      expect(second.filled).to eq 0
    end
  end

  describe "guard against a non-date custom field" do
    let(:text_cf) { create(:work_package_custom_field, field_format: "text") }

    it "raises" do
      expect { described_class.new(custom_field: text_cf).call }.to raise_error(ArgumentError)
    end
  end
end
