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

RSpec.describe Queries::Principals::Filters::OrganizationalUnitFilter do
  shared_let(:department) { create(:group, lastname: "Marketing", organizational_unit: true) }
  shared_let(:plain_group) { create(:group, lastname: "Plain Team") }
  shared_let(:user) { create(:user) }
  shared_let(:admin) { create(:admin) }

  # PrincipalQuery#results scopes by visibility, so without a current user every result set is
  # empty and the assertions below would pass vacuously.
  before { login_as(admin) }

  def results_for(operator, values)
    query = Queries::Principals::PrincipalQuery.new
    query.where(:organizational_unit, operator, values)

    query.results.to_a
  end

  it "is registered on the principal query" do
    expect(Queries::Principals::PrincipalQuery.new.available_filters.map(&:name))
      .to include(:organizational_unit)
  end

  describe "with '= t'" do
    it "returns only organizational units" do
      expect(results_for("=", [OpenProject::Database::DB_VALUE_TRUE]))
        .to contain_exactly(department)
    end
  end

  describe "with '= f'" do
    # A join on group_details would silently drop users too, so assert they survive the negation.
    it "returns everything that is not an organizational unit, users included" do
      results = results_for("=", [OpenProject::Database::DB_VALUE_FALSE])

      expect(results).to include(plain_group, user)
      expect(results).not_to include(department)
    end
  end

  describe "with '! t'" do
    it "negates to everything that is not an organizational unit" do
      results = results_for("!", [OpenProject::Database::DB_VALUE_TRUE])

      expect(results).to include(plain_group, user)
      expect(results).not_to include(department)
    end
  end

  # Department custom fields intentionally expose every organisational unit as an assignable
  # value regardless of the viewer's permissions (CustomField#possible_department_values has no
  # visibility check of its own), so PrincipalQuery must widen past its ordinary Principal.visible
  # restriction for this filter specifically -- otherwise a user without view_all_principals or
  # manage_members would never see a department outside their own visible projects/groups.
  describe "for a regular user with no special visibility permissions" do
    shared_let(:regular_user) { create(:user) }

    before { login_as(regular_user) }

    it "still returns a department unrelated to the user's projects and groups" do
      expect(results_for("=", [OpenProject::Database::DB_VALUE_TRUE]))
        .to contain_exactly(department)
    end

    it "keeps the ordinary visibility restriction for everything else" do
      results = results_for("=", [OpenProject::Database::DB_VALUE_FALSE])

      expect(results).not_to include(plain_group, department)
    end
  end
end
