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

RSpec.describe WorkPackages::Import::OutlineParser do
  subject(:call) { described_class.call(markdown) }

  context "with front matter" do
    let(:markdown) { <<~MD }
      ---
      Project: Company OKRs
      Version: FY2026 Q3
      ---

      # Objective: Increase retention
    MD

    it "parses front matter as a hash" do
      expect(call.result.front_matter).to eq("Project" => "Company OKRs", "Version" => "FY2026 Q3")
    end

    it "parses the single root node" do
      node = call.result.nodes.first
      expect(node.level).to eq(1)
      expect(node.type_name).to eq("Objective")
      expect(node.subject).to eq("Increase retention")
      expect(node.parent_index).to be_nil
      expect(node.source_line).to eq(6)
    end
  end

  context "with nested headings" do
    let(:markdown) { <<~MD }
      # Strategic Initiative: Subscription Growth

      ## Objective: Increase retention

      ### Key Result: Renewals to 75%
    MD

    it "assigns parent_index by heading depth" do
      nodes = call.result.nodes
      expect(nodes[0].parent_index).to be_nil
      expect(nodes[1].parent_index).to eq(0)
      expect(nodes[2].parent_index).to eq(1)
    end

    it "allows multiple roots at the same depth" do
      markdown = "# Objective: A\n\n# Objective: B\n"
      nodes = described_class.call(markdown).result.nodes
      expect(nodes.map(&:parent_index)).to eq([nil, nil])
    end
  end

  context "with a skipped depth" do
    let(:markdown) { <<~MD }
      # Objective: Increase retention

      ### Key Result: Renewals to 75%
    MD

    it "fails with the offending line" do
      expect(call).to be_failure
      expect(call.errors).to eq([{ source_line: 3, message: "heading depth skips a level" }])
    end
  end

  context "when starting below the top heading level" do
    let(:markdown) { <<~MD }
      ## Objective: Increase retention

      ### Key Result: Renewals to 75%
    MD

    it "treats the first heading's depth as the document root" do
      expect(call).to be_success
      expect(call.result.nodes.first.level).to eq(2)
    end
  end

  context "with a bullet block and prose" do
    let(:markdown) { <<~MD }
      # Objective: Increase retention
      - Accountable: jane.doe@example.com
      - Confidence: 80%

      We expect gains from onboarding.

      Multiple paragraphs are joined verbatim.
    MD

    it "parses the bullet block into attributes" do
      expect(call.result.nodes.first.attributes).to eq(
        "Accountable" => "jane.doe@example.com",
        "Confidence" => "80%"
      )
    end

    it "parses everything after the bullet block as description" do
      expect(call.result.nodes.first.description)
        .to eq("We expect gains from onboarding.\n\nMultiple paragraphs are joined verbatim.")
    end
  end

  context "with a duplicate attribute key" do
    let(:markdown) { <<~MD }
      # Objective: Increase retention
      - Accountable: jane.doe@example.com
      - Accountable: sam.lee@example.com
    MD

    it "fails on the duplicate" do
      expect(call).to be_failure
      expect(call.errors.first[:message]).to eq('duplicate attribute key "Accountable"')
    end
  end

  context "with a bullet before any heading" do
    let(:markdown) { "- Accountable: jane.doe@example.com\n" }

    it "fails" do
      expect(call).to be_failure
      expect(call.errors.first[:message]).to eq("attribute bullet before any heading")
    end
  end

  context "attribute inheritance" do
    let(:markdown) { <<~MD }
      ---
      Version: FY2026 Q3
      ---

      # Objective: Increase retention
      - Organizational Unit: Marketing / Retention

      ## Key Result: Renewals to 75%
      - Accountable: sam.lee@example.com

      ## Key Result: NPS to 60
      - Organizational Unit: Marketing / Brand
    MD

    it "flows front matter down to every node" do
      expect(call.result.nodes.map { |n| n.attributes["Version"] }).to eq(["FY2026 Q3"] * 3)
    end

    it "flows an ancestor's own attribute down to descendants" do
      renewals = call.result.nodes.find { |n| n.subject == "Renewals to 75%" }
      expect(renewals.attributes["Organizational Unit"]).to eq("Marketing / Retention")
    end

    it "lets a descendant override an inherited attribute" do
      nps = call.result.nodes.find { |n| n.subject == "NPS to 60" }
      expect(nps.attributes["Organizational Unit"]).to eq("Marketing / Brand")
    end

    it "does not push a sibling's attribute across" do
      renewals = call.result.nodes.find { |n| n.subject == "Renewals to 75%" }
      nps = call.result.nodes.find { |n| n.subject == "NPS to 60" }
      expect(nps.attributes).not_to have_key("Accountable")
      expect(renewals.attributes["Accountable"]).to eq("sam.lee@example.com")
    end

    it "does not inherit front matter Project into node attributes" do
      markdown = <<~MD
        ---
        Project: Company OKRs
        Version: FY2026 Q3
        ---

        # Objective: Increase retention
      MD
      node = described_class.call(markdown).result.nodes.first

      expect(node.attributes["Version"]).to eq("FY2026 Q3")
      expect(node.attributes).not_to have_key("Project")
    end
  end

  context "with three levels of nesting" do
    let(:markdown) { <<~MD }
      # Strategic Initiative: Subscription Growth
      - Organizational Unit: Marketing

      ## Objective: Increase retention

      ### Key Result: Renewals to 75%
    MD

    it "carries a grandparent-only attribute down to a grandchild" do
      key_result = call.result.nodes.find { |n| n.subject == "Renewals to 75%" }
      expect(key_result.attributes["Organizational Unit"]).to eq("Marketing")
    end
  end
end
