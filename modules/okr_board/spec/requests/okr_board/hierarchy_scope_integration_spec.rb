# frozen_string_literal: true

require "spec_helper"

# Backend integration coverage for the OKR board's central promise: that each of the three
# quick-filter scopes ("just this unit", "this and everything above", "this and one level
# down") -- once turned into a concrete list of organizational-unit ids by the frontend (see
# OkrBoardFilterComponent#scopeValues() in okr-board-filter.component.ts) -- actually returns
# the intended work packages when applied as the department custom field's "=" filter.
#
# This does not re-test the frontend's scope-to-id-list computation (already covered by
# Jasmine specs on OkrBoardFilterComponent); it verifies the filter *mechanism* itself: that
# WorkPackageCustomField#column_name "=" a computed id list returns exactly the right rows at
# the query/database level, using the same Query::Results-based pattern established in
# spec/requests/api/v3/work_packages/department_custom_field_spec.rb.
RSpec.describe "OKR board hierarchy scope filtering" do
  shared_let(:admin) { create(:admin) }

  current_user { admin }

  # A root with children.
  shared_let(:engineering) { create(:department, lastname: "Engineering") }
  shared_let(:frontend_team) { create(:department, parent: engineering, lastname: "Frontend") }

  # A root with no children.
  shared_let(:sales) { create(:department, lastname: "Sales") }

  shared_let(:department_field) { create(:department_wp_custom_field) }
  shared_let(:project) { create(:project, work_package_custom_fields: [department_field]) }
  shared_let(:work_package_type) do
    type = create(:type, custom_fields: [department_field])
    project.types << type
    type
  end

  shared_let(:engineering_wp) do
    create(:work_package, project:, type: work_package_type,
                          custom_values: { department_field.id => engineering.id.to_s })
  end
  shared_let(:frontend_wp) do
    create(:work_package, project:, type: work_package_type,
                          custom_values: { department_field.id => frontend_team.id.to_s })
  end
  shared_let(:sales_wp) do
    create(:work_package, project:, type: work_package_type,
                          custom_values: { department_field.id => sales.id.to_s })
  end

  # Applies the given organizational-unit ids as the department custom field's "=" filter,
  # mirroring what OkrBoardFilterComponent#applyUnitFilter() writes into
  # WorkPackageViewFiltersService on the frontend.
  def work_packages_for(unit_ids)
    query = build(:query, project:)
    query.filters.clear
    query.add_filter(department_field.column_name, "=", unit_ids.map(&:to_s))

    Query::Results.new(query).work_packages
  end

  describe "\"just this unit\" scope ([unit.id])" do
    it "returns only the work package tagged with the exact selected unit, not its children" do
      expect(work_packages_for([engineering.id])).to contain_exactly(engineering_wp)
    end

    it "returns only the work package tagged with a childless root unit" do
      expect(work_packages_for([sales.id])).to contain_exactly(sales_wp)
    end
  end

  describe "\"this and everything above\" scope (unit.self_and_ancestors.ids)" do
    it "is a no-op identical to \"just this unit\" for a top-level unit" do
      ids = engineering.self_and_ancestors.ids

      expect(ids).to contain_exactly(engineering.id)
      expect(work_packages_for(ids)).to contain_exactly(engineering_wp)
    end
  end

  describe "\"this and one level down\" scope ([unit.id] + unit.children.ids)" do
    it "includes the unit's own work package and its direct child's" do
      ids = [engineering.id] + engineering.children.ids

      expect(work_packages_for(ids)).to contain_exactly(engineering_wp, frontend_wp)
    end

    it "does not pull in an unrelated unit's work package" do
      ids = [engineering.id] + engineering.children.ids

      expect(work_packages_for(ids)).not_to include(sales_wp)
    end

    it "is just the unit's own work package for a childless root unit" do
      ids = [sales.id] + sales.children.ids

      expect(ids).to contain_exactly(sales.id)
      expect(work_packages_for(ids)).to contain_exactly(sales_wp)
    end
  end
end
