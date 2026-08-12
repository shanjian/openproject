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
require "rack/test"

# The work package table reads its sortBy allowedValues from this form response
# (frontend/.../wp-states-initialization.service.ts), and allowedValues are only rendered on the
# form path. A 500 here therefore leaves every column unsortable -- no sort arrow, and clicking a
# header does nothing -- rather than failing visibly.
RSpec.describe "POST /api/v3/queries/form with a department custom field" do
  include Rack::Test::Methods
  include API::V3::Utilities::PathHelper

  shared_let(:admin) { create(:admin) }
  shared_let(:project) { create(:project) }
  shared_let(:type) { create(:type_task, projects: [project]) }

  # is_for_all matters: the department filter only reaches the *global* query form -- the one the
  # frontend posts to -- when the custom field applies to every project.
  shared_let(:department_cf) do
    create(:wp_custom_field, name: "Organizational Unit", field_format: "department",
                             types: [type], is_for_all: true, is_filter: true)
  end

  before { login_as admin }

  subject(:response_body) do
    post "/api/v3/queries/form", {}.to_json, { "CONTENT_TYPE" => "application/json" }
    last_response.body
  end

  it "succeeds rather than raising for the unmapped filter" do
    expect(response_body).to be_present
    expect(last_response).to have_http_status(200)
  end

  it "offers sortBy allowed values, which is what makes columns sortable" do
    allowed = JSON.parse(response_body).dig("_embedded", "schema", "sortBy", "_embedded",
                                            "allowedValues")

    expect(allowed).to be_an(Array)
    expect(allowed).not_to be_empty
  end

  # The precise shape of the department filter's allowed-values link is asserted in
  # spec/lib/api/v3/queries/schemas/department_filter_dependency_representer_spec.rb. Rendering it
  # at all is what this request spec proves: an unmapped filter cannot render, it raises.
  it "keeps the department filter available on the query" do
    expect(Query.new.available_filters.map { |filter| filter.class.to_s })
      .to include("Queries::Filters::Shared::CustomFields::Department")
  end

  # End-to-end check that the allowed-values link the representer emits really does exclude
  # non-departments: a plain group can never match the filter, because it resolves its values
  # through Group.organizational_units, so offering it in the autocompleter is a dead end.
  describe "following the department filter's allowed values link" do
    shared_let(:department) { create(:group, lastname: "Marketing", organizational_unit: true) }
    shared_let(:plain_group) { create(:group, lastname: "Plain Team") }

    let(:filter) do
      Queries::WorkPackages::Filter::CustomFieldFilter
        .from_custom_field!(custom_field: department_cf, context: Query.new)
    end
    let(:href) do
      API::V3::Queries::Schemas::DepartmentFilterDependencyRepresenter
        .new(filter, Queries::Operators::Equals, form_embedded: true)
        .send(:href_callback)
    end

    it "offers departments and not other groups" do
      get href

      expect(last_response).to have_http_status(200)

      names = JSON.parse(last_response.body).dig("_embedded", "elements").pluck("name")

      expect(names).to include(department.name)
      expect(names).not_to include(plain_group.name)
    end
  end
end
