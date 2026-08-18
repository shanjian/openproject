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

RSpec.describe Meeting::TimeZones do
  describe "CURATED" do
    it "resolves every identifier through ActiveSupport::TimeZone" do
      unresolvable = described_class::CURATED.reject { |_label, id| ActiveSupport::TimeZone[id] }

      expect(unresolvable).to be_empty
    end

    it "is frozen so it cannot be mutated at runtime" do
      expect(described_class::CURATED).to be_frozen
    end
  end

  describe ".options" do
    subject(:options) { described_class.options }

    it "offers New York under a searchable city label, which the full " \
       "ActiveSupport list did not (it calls the zone \"Eastern Time (US & Canada)\")" do
      expect(options).to include(["(UTC-05:00) New York (US East)", "America/New_York"])
    end

    it "offers Toronto, which is absent from ActiveSupport::TimeZone.all entirely " \
       "and so could never appear while the select was sourced from assignable_time_zones" do
      expect(ActiveSupport::TimeZone.all.map { |tz| tz.tzinfo.name }).not_to include("America/Toronto")
      expect(options).to include(["(UTC-05:00) Toronto", "America/Toronto"])
    end

    it "merges curated cities that tzdata links to a shared canonical zone, keeping " \
       "both city names searchable in the single option they map to" do
      # tzdata 2026a: Europe/Stockholm -> Europe/Berlin, Europe/Bratislava -> Europe/Prague.
      expect(options).to include(["(UTC+01:00) Berlin, Stockholm", "Europe/Berlin"])
      expect(options).to include(["(UTC+01:00) Prague, Bratislava", "Europe/Prague"])
    end

    it "uses Etc/UTC as the UTC option's value, the canonical identifier the " \
       "meetings.time_zone column and user preferences already store" do
      expect(options).to include(["(UTC+00:00) UTC", "Etc/UTC"])
    end

    it "emits canonical tzinfo identifiers as values, with no duplicates" do
      values = options.map(&:last)

      expect(values).to all(satisfy { |value| ActiveSupport::TimeZone[value].tzinfo.canonical_zone.identifier == value })
      expect(values).to eq(values.uniq)
    end

    it "no longer offers the full ActiveSupport list" do
      expect(options.size).to be < ActiveSupport::TimeZone.all.size
      expect(options.map(&:first)).to all(satisfy { |label| label.exclude?("Eastern Time (US & Canada)") })
    end
  end

  describe ".uncurated_option" do
    it "builds an option for a zone outside the curated list, so a meeting stored " \
       "in one still renders with its own zone rather than silently switching" do
      expect(described_class.uncurated_option("Asia/Kolkata")).to eq(["(UTC+05:30) Asia/Kolkata", "Asia/Kolkata"])
    end

    it "canonicalises the identifier it is given" do
      expect(described_class.uncurated_option("Europe/Stockholm")).to eq(["(UTC+01:00) Europe/Berlin", "Europe/Berlin"])
    end

    it "returns nil for an unresolvable identifier" do
      expect(described_class.uncurated_option("Not/AZone")).to be_nil
    end
  end
end
