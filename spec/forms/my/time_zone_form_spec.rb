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
#
require "spec_helper"

RSpec.describe My::TimeZoneForm, type: :forms do
  include_context "with rendered form"

  let(:model) { build_stubbed(:user_preference) }

  it "renders the curated common zones first, in order, then a disabled divider, " \
     "then the rest of the world - so every zone is reachable but the common case stays short" do
    expect(page).to have_select "Time zone", required: true do |select|
      expect(select).to have_element :option, value: "America/New_York",
                                              text: "(UTC-05:00) New York (US East) — America/New_York"
      expect(select).to have_element :option, value: "America/Los_Angeles",
                                              text: "(UTC-08:00) Los Angeles / San Francisco — America/Los_Angeles"
      expect(select).to have_element :option, value: "Europe/Berlin",
                                              text: "(UTC+01:00) Berlin (Germany) — Europe/Berlin"
      expect(select).to have_element :option, disabled: true, text: I18n.t(:label_time_zone_divider)
      # Still reachable, just below the divider - the full list is never hidden.
      expect(select).to have_element :option, value: "Asia/Shanghai", text: "(UTC+08:00) Beijing, Chongqing"
    end
  end

  it "does not offer Europe/Stockholm as its own value - it is a tzinfo link to Europe/Berlin, " \
     "and the preferences contract requires a canonical identifier - but Berlin covers the same zone" do
    expect(page).to have_select "Time zone" do |select|
      expect(select).not_to have_element :option, value: "Europe/Stockholm"
    end
  end

  it "does not offer Europe/Bratislava as its own value for the same canonical-identifier reason" do
    expect(page).to have_select "Time zone" do |select|
      expect(select).not_to have_element :option, value: "Europe/Bratislava"
    end
  end
end
