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

RSpec.describe Users::CommonTimeZones do
  describe "PROFILE_ZONE_IDENTIFIERS" do
    it "excludes Europe/Bratislava and Europe/Stockholm, tzinfo links whose canonical zone " \
       "(Prague/Berlin) is a different, already-curated identifier - offering them as their own " \
       "selectable value would let a user pick an option that then fails " \
       "UserPreferences::BaseContract#time_zone_correctness on save" do
      expect(described_class::PROFILE_ZONE_IDENTIFIERS).not_to include("Europe/Bratislava", "Europe/Stockholm")
    end

    it "is exactly the meeting zone identifiers minus those two aliases" do
      expect(described_class::PROFILE_ZONE_IDENTIFIERS)
        .to match_array(described_class::MEETING_ZONE_IDENTIFIERS - %w[Europe/Bratislava Europe/Stockholm])
    end

    it "resolves every identifier to itself as the canonical zone (a precondition for being " \
       "safely storable as a raw user preference value)" do
      described_class::PROFILE_ZONE_IDENTIFIERS.each do |identifier|
        expect(TZInfo::Timezone.get(identifier).canonical_zone.identifier).to eq(identifier)
      end
    end
  end

  describe ".grouped_options" do
    subject(:options) { described_class.grouped_options(identifiers: described_class::PROFILE_ZONE_IDENTIFIERS) }

    it "returns the curated identifiers first, in the given order" do
      curated_values = options.first(described_class::PROFILE_ZONE_IDENTIFIERS.size).map(&:second)

      expect(curated_values).to eq(described_class::PROFILE_ZONE_IDENTIFIERS)
    end

    it "places a disabled divider row right after the curated identifiers" do
      divider = options[described_class::PROFILE_ZONE_IDENTIFIERS.size]

      expect(divider.third).to be true
    end

    it "lists every other assignable time zone after the divider, grouped by canonical identifier" do
      remaining_values = options.drop(described_class::PROFILE_ZONE_IDENTIFIERS.size + 1).map(&:second)

      expect(remaining_values).to include("Asia/Shanghai", "Asia/Kolkata", "Pacific/Honolulu")
      expect(remaining_values).not_to include(*described_class::PROFILE_ZONE_IDENTIFIERS)
    end

    it "never lists a value twice across the whole list" do
      values = options.map(&:second)

      expect(values.uniq).to eq(values)
    end

    it "excludes Berlin's canonical group entirely when Berlin is curated, so Stockholm " \
       "(a tzinfo link to Berlin) is not offered as a separate remaining-list entry either" do
      remaining_values = options.drop(described_class::PROFILE_ZONE_IDENTIFIERS.size + 1).map(&:second)

      expect(remaining_values).not_to include("Europe/Berlin")
    end

    context "with no offset_period given (profile-style: base offset, not DST-aware)" do
      it "labels a curated zone using its base UTC offset" do
        label = options.find { |_, value, _| value == "America/Los_Angeles" }.first

        expect(label).to eq("(UTC-08:00) Los Angeles / San Francisco — America/Los_Angeles")
      end
    end

    context "with an offset_period given (meeting-style: DST-aware for that date)" do
      it "labels a curated zone using the offset observed on that date" do
        options = described_class.grouped_options(
          identifiers: described_class::MEETING_ZONE_IDENTIFIERS,
          offset_period: DateTime.iso8601("2026-07-01T10:00:00-04:00")
        )
        label = options.find { |_, value, _| value == "America/New_York" }.first

        expect(label).to eq("(UTC-04:00) New York (US East) — America/New_York")
      end
    end

    it "labels the UTC entry without an appended raw identifier" do
      label = options.find { |_, value, _| value == "Etc/UTC" }.first

      expect(label).to eq("(UTC+00:00) UTC")
    end
  end
end
