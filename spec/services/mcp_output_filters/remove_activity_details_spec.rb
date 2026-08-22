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

RSpec.describe McpOutputFilters::RemoveActivityDetails do
  subject(:filter) { described_class.new }

  # An activity's "details" is the machine-readable diff of every changed attribute. It is large,
  # and an assistant summarising a discussion has no use for it -- the notes carry the meaning.
  it "empties the details list, keeping the key so the shape is unchanged" do
    payload = { "details" => ["subject changed from A to B", "status changed"], "comment" => "hi" }

    filter.filter(payload)

    expect(payload).to eq({ "details" => [], "comment" => "hi" })
  end

  it "leaves a details value that is not a list alone" do
    payload = { "details" => "not a list" }

    filter.filter(payload)

    expect(payload["details"]).to eq("not a list")
  end

  it "reaches activities nested in arrays" do
    payload = { "items" => [{ "details" => %w[a b] }, { "details" => %w[c] }] }

    filter.filter(payload)

    expect(payload["items"].pluck("details")).to all(be_empty)
  end

  it "returns the payload rather than nil when the top level carries details" do
    payload = { "details" => ["x"] }

    expect(filter.filter(payload)).to be(payload)
  end
end
