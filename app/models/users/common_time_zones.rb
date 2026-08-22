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

module Users
  # Builds the time zone select shared by the meeting form, My account, and
  # the admin default time zone setting: a handful of curated, city-labeled
  # zones our offices actually use, a disabled divider row, then every other
  # assignable zone below it - so nothing is ever unreachable, but the common
  # case stays a short list.
  module CommonTimeZones
    MEETING_ZONE_IDENTIFIERS = %w[
      America/New_York
      America/Toronto
      America/Los_Angeles
      America/Mexico_City
      America/Sao_Paulo
      Europe/London
      Europe/Paris
      Europe/Berlin
      Europe/Stockholm
      Europe/Madrid
      Europe/Rome
      Europe/Prague
      Europe/Bratislava
      Europe/Bucharest
      Asia/Tokyo
      Asia/Seoul
      Asia/Taipei
      Australia/Sydney
      Pacific/Auckland
      Etc/UTC
    ].freeze

    # Meetings validate their stored time_zone by resolvability alone
    # (Meeting#time_zone_resolves), so tzinfo link zones like Bratislava and
    # Stockholm are safe to offer as their own entries there. A user
    # preference is stricter: UserPreferences::BaseContract#time_zone_correctness
    # requires the stored string to equal some zone's *canonical* tzinfo
    # identifier exactly, and Bratislava/Stockholm both canonicalize to a
    # different, already-curated identifier (Prague/Berlin) - offering them
    # here would let a user pick an option that then fails validation on
    # save. Dropping them doesn't remove a destination: picking Prague or
    # Berlin already means the same wall-clock time.
    PROFILE_ZONE_IDENTIFIERS = (MEETING_ZONE_IDENTIFIERS - %w[Europe/Bratislava Europe/Stockholm]).freeze

    DIVIDER_VALUE = ""

    module_function

    # Returns [label, value, disabled] triples: the curated identifiers
    # first, in the given order, then a disabled divider row, then every
    # other assignable time zone grouped by canonical identifier (unchanged
    # labeling from the original uncurated list), excluding whatever is
    # already represented above the divider.
    def grouped_options(identifiers:, offset_period: nil)
      curated_options(identifiers, offset_period) + [divider_option] + remaining_options(identifiers)
    end

    def curated_options(identifiers, offset_period)
      identifiers.map { |identifier| [label_for(identifier, offset_period), identifier, false] }
    end

    def label_for(identifier, offset_period)
      name = I18n.t("common_time_zones.#{key_for(identifier)}")
      offset = ActiveSupport::TimeZone.seconds_to_utc_offset(offset_seconds_for(identifier, offset_period))

      identifier == "Etc/UTC" ? "(UTC#{offset}) #{name}" : "(UTC#{offset}) #{name} — #{identifier}"
    end

    def key_for(identifier)
      identifier.downcase.gsub(%r{[/\s-]}, "_")
    end

    # Base offset (nil period) matches how the uncurated "remaining" list has
    # always been labeled - stable and deterministic, appropriate for a
    # standing preference with no particular date attached. A given period
    # (the meeting form passes the meeting's own start time) instead reports
    # the offset actually observed then, so e.g. New York shows -04:00 in
    # July and -05:00 in January rather than always claiming its base -05:00.
    def offset_seconds_for(identifier, offset_period)
      tzinfo = TZInfo::Timezone.get(identifier)
      offset_period ? tzinfo.observed_utc_offset(offset_period) : tzinfo.canonical_zone.base_utc_offset
    end

    def divider_option
      [I18n.t(:label_time_zone_divider), DIVIDER_VALUE, true]
    end

    def remaining_options(curated_identifiers)
      curated_canonical = curated_identifiers.to_set { |identifier| TZInfo::Timezone.get(identifier).canonical_zone.identifier }

      UserPreferences::UpdateContract
        .assignable_time_zones
        .group_by { it.tzinfo.canonical_zone }
        .reject { |canonical_zone, _| curated_canonical.include?(canonical_zone.identifier) }
        .map { |canonical_zone, zones| full_list_entry(canonical_zone, zones) }
    end

    def full_list_entry(canonical_zone, zones)
      zone_names = zones.map(&:name).join(", ")
      offset = ActiveSupport::TimeZone.seconds_to_utc_offset(canonical_zone.base_utc_offset)

      ["(UTC#{offset}) #{zone_names}", canonical_zone.identifier, false]
    end
  end
end
