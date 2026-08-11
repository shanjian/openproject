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
end
