# frozen_string_literal: true

require "spec_helper"
require "rack/test"

RSpec.describe "Department custom field on work packages", :aggregate_failures do
  include Rack::Test::Methods
  include API::V3::Utilities::PathHelper

  shared_let(:admin) { create(:admin) }
  shared_let(:engineering) { create(:department) }
  shared_let(:frontend_team) { create(:department, parent: engineering) }
  shared_let(:sales) { create(:department) }

  shared_let(:department_field) { create(:department_wp_custom_field) }
  shared_let(:project) { create(:project, work_package_custom_fields: [department_field]) }
  shared_let(:work_package_type) do
    type = create(:type, custom_fields: [department_field])
    project.types << type
    type
  end

  let(:work_package) do
    create(:work_package, project:, type: work_package_type)
  end

  current_user { admin }

  describe "setting the value" do
    it "accepts a link to an organizational unit and rejects a plain (non-department) group" do
      patch api_v3_paths.work_package(work_package.id),
            {
              department_field.attribute_name(:camel_case) => {
                href: api_v3_paths.group(frontend_team.id)
              },
              lockVersion: work_package.lock_version
            }.to_json,
            "CONTENT_TYPE" => "application/json"

      expect(last_response).to have_http_status(200)
      expect(work_package.reload.send(department_field.attribute_getter)).to eq(frontend_team)
    end
  end

  describe "the work package's update form" do
    it "embeds all organizational units as allowed values" do
      post api_v3_paths.work_package_form(work_package.id), { lockVersion: work_package.lock_version }.to_json,
           "CONTENT_TYPE" => "application/json"

      body = JSON.parse(last_response.body)
      embedded = body["_embedded"]["schema"][department_field.attribute_name(:camel_case)]["_embedded"]["allowedValues"]

      expect(embedded.pluck("id").map(&:to_i)).to contain_exactly(engineering.id, frontend_team.id, sales.id)
    end
  end

  describe "filtering" do
    let!(:engineering_wp) do
      create(:work_package, project:, type: work_package_type,
                            custom_values: { department_field.id => engineering.id.to_s })
    end
    let!(:sales_wp) do
      create(:work_package, project:, type: work_package_type,
                            custom_values: { department_field.id => sales.id.to_s })
    end

    it "matches only the exact selected department, not its descendants or siblings" do
      query = build(:query, project:)
      query.filters.clear
      query.add_filter(department_field.column_name, "=", [engineering.id.to_s])

      expect(Query::Results.new(query).work_packages).to contain_exactly(engineering_wp)
    end
  end

  describe "grouping" do
    let!(:engineering_wp) do
      create(:work_package, project:, type: work_package_type,
                            custom_values: { department_field.id => engineering.id.to_s })
    end
    let!(:sales_wp) do
      create(:work_package, project:, type: work_package_type,
                            custom_values: { department_field.id => sales.id.to_s })
    end

    it "groups work packages by their department without error, returning every matching work package" do
      query = build(:query, project:)
      query.filters.clear
      query.group_by = department_field.column_name

      expect(Query::Results.new(query).work_packages.pluck(:id))
        .to contain_exactly(engineering_wp.id, sales_wp.id)
    end
  end
end
