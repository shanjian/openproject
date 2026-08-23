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

RSpec.describe WorkPackage::EffectiveHierarchy do
  def wp(id, parent_id: nil, epic_id: nil)
    build_stubbed(:work_package, id:).tap do |work_package|
      work_package.parent_id = parent_id
      work_package.epic_id = epic_id
    end
  end

  def effective_parent_of(work_package, within:)
    described_class.new(within).effective_parent_id(work_package)
  end

  describe "a work package with a real parent" do
    it "uses the real parent, even when it also links an epic in the set" do
      epic = wp(1)
      parent = wp(2)
      task = wp(3, parent_id: parent.id, epic_id: epic.id)

      expect(effective_parent_of(task, within: [epic, parent, task])).to eq(parent.id)
    end

    it "uses the real parent even when that parent is not in the set" do
      epic = wp(1)
      task = wp(3, parent_id: 999, epic_id: epic.id)

      expect(effective_parent_of(task, within: [epic, task])).to eq(999)
    end
  end

  describe "a parentless work package linking an epic" do
    it "is adopted by the epic when the epic is in the set" do
      epic = wp(1)
      task = wp(3, epic_id: epic.id)

      expect(effective_parent_of(task, within: [epic, task])).to eq(epic.id)
    end

    it "stays at root level when the epic is not in the set" do
      task = wp(3, epic_id: 1)

      expect(effective_parent_of(task, within: [task])).to be_nil
    end
  end

  describe "a work package with neither parent nor epic" do
    it "stays at root level" do
      task = wp(3)

      expect(effective_parent_of(task, within: [task])).to be_nil
    end
  end

  describe "acyclicity" do
    it "does not adopt into an epic that itself carries an epic link" do
      outer = wp(1)
      epic = wp(2, epic_id: outer.id)
      task = wp(3, epic_id: epic.id)

      expect(effective_parent_of(task, within: [outer, epic, task])).to be_nil
    end

    it "cannot build a two-node cycle out of mutual epic links" do
      a = wp(1, epic_id: 2)
      b = wp(2, epic_id: 1)
      set = [a, b]

      expect(effective_parent_of(a, within: set)).to be_nil
      expect(effective_parent_of(b, within: set)).to be_nil
    end

    it "ignores a self-referencing epic link" do
      task = wp(3, epic_id: 3)

      expect(effective_parent_of(task, within: [task])).to be_nil
    end
  end

  describe "#adopted?" do
    it "is true only for work packages standing in via their epic link" do
      epic = wp(1)
      parent = wp(2)
      adopted = wp(3, epic_id: epic.id)
      parented = wp(4, parent_id: parent.id)
      root = wp(5)
      hierarchy = described_class.new([epic, parent, adopted, parented, root])

      expect(hierarchy.adopted?(adopted)).to be(true)
      expect(hierarchy.adopted?(parented)).to be(false)
      expect(hierarchy.adopted?(root)).to be(false)
      expect(hierarchy.adopted?(epic)).to be(false)
    end
  end

  describe "#linked_children_of" do
    it "returns the epic's linked children that are present in the set" do
      epic = wp(1)
      in_set = wp(3, epic_id: epic.id)
      also_in_set = wp(4, epic_id: epic.id)
      other = wp(5, epic_id: 99)
      hierarchy = described_class.new([epic, in_set, also_in_set, other])

      expect(hierarchy.linked_children_of(epic)).to contain_exactly(in_set, also_in_set)
    end

    it "includes linked children that have their own real parent" do
      epic = wp(1)
      parent = wp(2)
      parented_child = wp(3, parent_id: parent.id, epic_id: epic.id)
      hierarchy = described_class.new([epic, parent, parented_child])

      expect(hierarchy.linked_children_of(epic)).to contain_exactly(parented_child)
    end
  end
end
