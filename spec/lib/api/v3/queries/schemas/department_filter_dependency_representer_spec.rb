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
require_relative "../../support/api_v3_filter_dependency"

RSpec.describe API::V3::Queries::Schemas::DepartmentFilterDependencyRepresenter do
  include API::V3::Utilities::PathHelper

  let(:project) { build_stubbed(:project) }
  let(:query) { build_stubbed(:query, project:) }
  let(:custom_field) { build_stubbed(:wp_custom_field, field_format: "department") }
  let(:filter) do
    Queries::WorkPackages::Filter::CustomFieldFilter.from_custom_field! custom_field:,
                                                                        context: query
  end
  let(:form_embedded) { false }
  # Default for the examples outside the operator-specific contexts below.
  let(:operator) { Queries::Operators::Equals }

  let(:instance) { described_class.new(filter, operator, form_embedded:) }

  subject(:generated) { instance.to_json }

  # Without this mapping the factory raises ArgumentError, which surfaces as a 500 on
  # POST /api/v3/queries/form for any instance with a filterable, for-all department custom
  # field -- taking the whole work package table's sorting with it, since the frontend reads
  # its sortBy allowedValues from that form response.
  it "is the representer the factory picks for a department custom field filter" do
    expect(API::V3::Queries::Schemas::FilterDependencyRepresenterFactory
             .representer_class(filter))
      .to be(described_class)
  end

  # The frontend prepends a "Me" option to anything whose values type contains "User"
  # (filter-searchable-multiselect-value.component.ts#isUserResource). "Me" is never a department,
  # so this must not inherit the "[]User" of PrincipalFilterDependencyRepresenter.
  it "declares a department values type so the frontend offers no 'Me' option" do
    values_type = JSON.parse(generated).dig("values", "type")

    expect(values_type).to eq("[]Department")
    expect(values_type).not_to include("User")
  end

  describe "values" do
    let(:path) { "values" }
    let(:type) { "[]Department" }
    # Organisational units only, and deliberately not narrowed to members of the filter's project:
    # a department is an organisational unit rather than a project member, so a member filter would
    # answer an empty list and leave the filter unusable.
    let(:filter_query) do
      [{ type: { operator: "=", values: ["Group"] } },
       { organizationalUnit: { operator: "=", values: [OpenProject::Database::DB_VALUE_TRUE] } }]
    end
    let(:href) do
      "#{api_v3_paths.principals}?filters=#{CGI.escape(JSON.dump(filter_query))}&pageSize=-1"
    end

    context "for operator 'Queries::Operators::Equals'" do
      let(:operator) { Queries::Operators::Equals }

      it_behaves_like "filter dependency with allowed link"
    end

    context "for operator 'Queries::Operators::NotEquals'" do
      let(:operator) { Queries::Operators::NotEquals }

      it_behaves_like "filter dependency with allowed link"
    end
  end
end
