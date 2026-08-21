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

RSpec.describe CustomFields::Hierarchy::HierarchicalItemAggregator do
  describe ".flatten_tree_hash" do
    subject(:flattened) { described_class.flatten_tree_hash(tree) }

    # HierarchicalItemService#hashed_subtree yields nested hashes keyed by the item itself:
    #   { a => { b => { c1 => { d1 => {} }, c2 => {} }, b2 => {} } }
    let(:item_a) { instance_double(CustomField::Hierarchy::Item, label: "a") }
    let(:item_b) { instance_double(CustomField::Hierarchy::Item, label: "b") }
    let(:item_b2) { instance_double(CustomField::Hierarchy::Item, label: "b2") }
    let(:item_c1) { instance_double(CustomField::Hierarchy::Item, label: "c1") }
    let(:item_c2) { instance_double(CustomField::Hierarchy::Item, label: "c2") }
    let(:item_d1) { instance_double(CustomField::Hierarchy::Item, label: "d1") }

    context "with a nested tree" do
      let(:tree) do
        { item_a => { item_b => { item_c1 => { item_d1 => {} }, item_c2 => {} }, item_b2 => {} } }
      end

      it "walks the tree depth first" do
        expect(flattened.map(&:label)).to eq(%w[a b c1 d1 c2 b2])
      end

      # Depth is relative to the item the subtree was requested for, so the root of the passed tree
      # sits at -1 and its children at 0. ItemsAPI relies on this to honour its own depth parameter.
      it "puts the root of the passed tree at depth -1 and counts up from its children" do
        expect(flattened.map { |aggregate| [aggregate.label, aggregate.depth] })
          .to eq([["a", -1], ["b", 0], ["c1", 1], ["d1", 2], ["c2", 1], ["b2", 0]])
      end
    end

    context "with a single childless item" do
      let(:tree) { { item_a => {} } }

      it "returns just that item" do
        expect(flattened.map { |aggregate| [aggregate.label, aggregate.depth] }).to eq([["a", -1]])
      end
    end
  end
end
