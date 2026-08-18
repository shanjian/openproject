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

# Curated, city-labelled set of time zones offered by the meeting form.
#
# The full ActiveSupport list (UserPreferences::BaseContract.assignable_time_zones,
# still used by My account and the admin settings) labels zones with Rails'
# friendly names - US East is "Eastern Time (US & Canada)" - so searching the
# meeting dropdown for "New York" found nothing. This list fixes the labels and
# narrows the dropdown to the zones meetings are actually scheduled in.
#
# To extend it, add a row to CURATED. Nothing else needs to change.
module Meeting::TimeZones
  # Label shown in the select => IANA identifier.
  CURATED = {
    "New York (US East)" => "America/New_York",
    "Toronto" => "America/Toronto",
    "Los Angeles / San Francisco" => "America/Los_Angeles",
    "Mexico City" => "America/Mexico_City",
    "São Paulo" => "America/Sao_Paulo",
    "London" => "Europe/London",
    "Paris" => "Europe/Paris",
    "Berlin" => "Europe/Berlin",
    "Stockholm" => "Europe/Stockholm",
    "Madrid" => "Europe/Madrid",
    "Rome" => "Europe/Rome",
    "Prague" => "Europe/Prague",
    "Bratislava" => "Europe/Bratislava",
    "Bucharest" => "Europe/Bucharest",
    "Tokyo" => "Asia/Tokyo",
    "Seoul" => "Asia/Seoul",
    "Taipei" => "Asia/Taipei",
    "Sydney" => "Australia/Sydney",
    "Auckland" => "Pacific/Auckland",
    "UTC" => "UTC"
  }.freeze

  class << self
    # [label, value] pairs for the meeting form's time zone select, in CURATED
    # order. Values are canonical tzinfo identifiers - the format meetings.time_zone
    # stores and user preferences validate against - matching what the select
    # already wrote before this list existed.
    #
    # Several curated cities share a canonical zone (tzdata links
    # Europe/Stockholm -> Europe/Berlin and Europe/Bratislava -> Europe/Prague),
    # so their labels are merged into the single option they map to. That keeps
    # every curated city name findable when typing in the dropdown.
    def options
      resolved = CURATED.filter_map do |label, identifier|
        canonical = canonical_zone(identifier)
        [label, canonical] if canonical
      end

      resolved
        .group_by(&:last)
        .map { |canonical, entries| build_entry(canonical, entries.map(&:first)) }
    end

    # An option for a zone outside CURATED, labelled with its own identifier.
    #
    # Meetings stored in an uncurated zone - created before this list existed, or
    # by a user whose profile zone is not curated - must still render with their
    # own zone selected. Without this, no option would match and an unmodified
    # browser submit would silently rewrite the meeting to the first option (the
    # regression fixed in a6d027e300c).
    #
    # Returns nil if the identifier does not resolve.
    def uncurated_option(identifier)
      canonical = canonical_zone(identifier)
      return if canonical.nil?

      build_entry(canonical, [canonical.identifier])
    end

    private

    def canonical_zone(identifier)
      ActiveSupport::TimeZone[identifier]&.tzinfo&.canonical_zone
    end

    def build_entry(canonical_zone, labels)
      offset = ActiveSupport::TimeZone.seconds_to_utc_offset(canonical_zone.base_utc_offset)

      ["(UTC#{offset}) #{labels.join(', ')}", canonical_zone.identifier]
    end
  end
end
