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

RSpec.describe WorkPackages::Import::Resolver do
  subject(:resolver) { described_class.new(project: build_stubbed(:project), user: build_stubbed(:user)) }

  describe "#resolve_date" do
    it "parses an ISO date" do
      expect(resolver.send(:resolve_date, "2026-09-30")).to eq(Date.new(2026, 9, 30))
    end

    it "rejects a non-ISO date" do
      expect { resolver.send(:resolve_date, "09/30/2026") }
        .to raise_error(described_class::AttributeError, /not a valid ISO date/)
    end
  end

  describe "#convert_custom_value for numeric formats" do
    let(:custom_field) { build_stubbed(:custom_field, field_format: "int") }
    let(:float_field) { build_stubbed(:custom_field, field_format: "float") }

    it "parses a plain integer" do
      expect(resolver.send(:convert_custom_value, custom_field, "42")).to eq(42)
    end

    it "tolerates a trailing percent sign" do
      expect(resolver.send(:convert_custom_value, custom_field, "80%")).to eq(80)
    end

    it "parses a float" do
      expect(resolver.send(:convert_custom_value, float_field, "0.8")).to eq(0.8)
    end

    it "raises AttributeError on garbage input" do
      expect { resolver.send(:convert_custom_value, custom_field, "not a number") }
        .to raise_error(described_class::AttributeError, /not a valid int/)
    end
  end

  describe "#convert_custom_value for bool" do
    let(:bool_field) { build_stubbed(:custom_field, field_format: "bool") }

    it "accepts yes/true as truthy" do
      expect(resolver.send(:convert_custom_value, bool_field, "yes")).to be true
      expect(resolver.send(:convert_custom_value, bool_field, "True")).to be true
    end

    it "accepts anything else as false" do
      expect(resolver.send(:convert_custom_value, bool_field, "no")).to be false
    end
  end

  describe "#convert_custom_value for string/text" do
    let(:string_field) { build_stubbed(:custom_field, field_format: "string") }

    it "passes the value through verbatim" do
      expect(resolver.send(:convert_custom_value, string_field, "Rework the sequence")).to eq("Rework the sequence")
    end
  end

  describe "#resolve_user" do
    let!(:jane) { create(:user, mail: "jane.doe@example.com", firstname: "Jane", lastname: "Doe") }
    let!(:sam) { create(:user, mail: "sam.lee@example.com", firstname: "Sam", lastname: "Lee") }

    before { resolver.instance_variable_set(:@user_lookup, resolver.send(:build_user_lookup)) }

    it "resolves by email" do
      expect(resolver.send(:resolve_user, "jane.doe@example.com")).to eq(jane)
    end

    it "resolves by unambiguous display name" do
      expect(resolver.send(:resolve_user, jane.name)).to eq(jane)
    end

    it "raises on an unknown email" do
      expect { resolver.send(:resolve_user, "nobody@example.com") }
        .to raise_error(described_class::AttributeError, /no user found with email/)
    end

    context "with two users sharing a display name" do
      let!(:other_jane) { create(:user, mail: "jane.doe2@example.com", firstname: "Jane", lastname: "Doe") }

      # Re-run after other_jane exists: the outer `before` (a hook declared in an
      # enclosing context) always fires before this context's own `let!(:other_jane)`
      # hook, so without rebuilding here the lookup would be built too early and miss her.
      before { resolver.instance_variable_set(:@user_lookup, resolver.send(:build_user_lookup)) }

      it "raises ambiguity, not a silent guess" do
        expect { resolver.send(:resolve_user, jane.name) }
          .to raise_error(described_class::AttributeError, /matches more than one user/)
      end
    end
  end

  describe "#resolve_department" do
    let!(:marketing) { create(:group, lastname: "Marketing", organizational_unit: true) }
    let!(:retention) { create(:group, lastname: "Retention", parent: marketing, organizational_unit: true) }
    let!(:security_group) { create(:group, lastname: "Retention", organizational_unit: false) }

    before { resolver.instance_variable_set(:@department_lookup, resolver.send(:build_department_lookup)) }

    it "resolves a full ancestry path" do
      expect(resolver.send(:resolve_department, "Marketing / Retention")).to eq(retention)
    end

    it "resolves an unambiguous leaf name" do
      expect(resolver.send(:resolve_department, "Marketing")).to eq(marketing)
    end

    it "never matches a same-named regular security group" do
      # "Retention" as a bare leaf name is ambiguous between the org unit and the
      # regular group only if both are considered — assert only the org unit counts.
      expect(resolver.send(:build_department_lookup)[:by_leaf_name]["Retention"]).to eq([retention])
    end

    it "raises on an unknown path" do
      expect { resolver.send(:resolve_department, "Sales / Enablement") }
        .to raise_error(described_class::AttributeError, /no organizational unit/)
    end
  end

  describe "#build_department_lookup query count" do
    before do
      marketing = create(:group, lastname: "Marketing", organizational_unit: true)
      5.times { |i| create(:group, lastname: "Team #{i}", parent: marketing, organizational_unit: true) }
    end

    it "issues at most one query regardless of tree size" do
      expect { resolver.send(:build_department_lookup) }.to have_a_query_limit(1)
    end
  end
end
