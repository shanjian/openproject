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

require "rails_helper"

RSpec.describe Settings::TimeZoneSettingComponent, type: :component do
  subject { render_inline(described_class.new("user_default_timezone")) }

  it "renders the curated common zones first, then a disabled divider, then every other " \
     "zone grouped by identifier - so nothing is unreachable, but the common case stays short" do
    subject

    expect(page).to have_css("option[value=\"America/New_York\"]",
                             text: "(UTC-05:00) New York (US East) — America/New_York")
    expect(page).to have_css("option[value=\"Europe/Berlin\"]", text: "(UTC+01:00) Berlin (Germany) — Europe/Berlin")
    expect(page).to have_css("option[disabled]", text: I18n.t(:label_time_zone_divider))
    # Still reachable, just below the divider - the full list is never hidden.
    expect(page).to have_css("option[value=\"Asia/Shanghai\"]", text: "(UTC+08:00) Beijing, Chongqing")
  end

  it "does not offer Europe/Stockholm or Europe/Bratislava as their own values - both are tzinfo " \
     "links whose canonical identifier (Berlin/Prague) is already curated" do
    subject

    expect(page).to have_no_css("option[value=\"Europe/Stockholm\"]")
    expect(page).to have_no_css("option[value=\"Europe/Bratislava\"]")
  end
end
