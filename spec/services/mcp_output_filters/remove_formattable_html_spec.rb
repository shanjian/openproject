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

RSpec.describe McpOutputFilters::RemoveFormattableHtml do
  subject(:filter) { described_class.new }

  it "drops the html twin of a formattable, keeping the raw text the model reads" do
    payload = { "description" => { "format" => "markdown", "raw" => "# Hi", "html" => "<h1>Hi</h1>" } }

    filter.filter(payload)

    expect(payload["description"]).to eq({ "format" => "markdown", "raw" => "# Hi" })
  end

  it "leaves a hash that is missing one of the three keys alone" do
    payload = { "thing" => { "format" => "markdown", "html" => "<p></p>" } }

    filter.filter(payload)

    expect(payload["thing"]).to have_key("html")
  end

  it "reaches formattables nested inside arrays" do
    formattable = { "format" => "markdown", "raw" => "x", "html" => "<p>x</p>" }
    payload = { "items" => [{ "subject" => "a", "description" => formattable.dup },
                            { "subject" => "b", "description" => formattable.dup }] }

    filter.filter(payload)

    expect(payload["items"].map { |item| item["description"].keys }).to all(eq(%w[format raw]))
  end
end
