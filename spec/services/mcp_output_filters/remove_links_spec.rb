# frozen_string_literal: true

# -- copyright
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
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
# ++

require "spec_helper"

RSpec.describe McpOutputFilters::RemoveLinks do
  subject(:filter) { described_class.new(%w[update delete]) }

  it "removes only the blocked links" do
    payload = { "_links" => { "self" => 1, "update" => 2, "delete" => 3, "schema" => 4 } }

    filter.filter(payload)

    expect(payload["_links"].keys).to eq(%w[self schema])
  end

  it "descends through hashes that have no _links of their own" do
    payload = { "_embedded" => { "child" => { "_links" => { "self" => 1, "update" => 2 } } } }

    filter.filter(payload)

    expect(payload.dig("_embedded", "child", "_links").keys).to eq(%w[self])
  end

  it "returns the payload rather than nil when the top level carries _links" do
    payload = { "_links" => { "update" => 1 } }

    expect(filter.filter(payload)).to be(payload)
  end
end
