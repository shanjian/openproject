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
require Rails.root.join("db/migrate/20261127120100_add_reviewer_to_people_form_configs.rb")

RSpec.describe AddReviewerToPeopleFormConfigs, type: :model do
  subject(:migrate!) { ActiveRecord::Migration.suppress_messages { described_class.migrate(:up) } }

  def raw_groups(type)
    Type.where(id: type.id).pick(:attribute_groups)
  end

  # Write the raw column directly to simulate a form configuration an admin saved
  # before the Reviewer attribute existed.
  def persist_raw(type, groups)
    type.update_column(:attribute_groups, groups)
  end

  context "with a saved People group containing Accountable" do
    let!(:type) do
      create(:type).tap do |t|
        persist_raw(t, [["people", %w[assignee author responsible]], ["details", %w[priority date]]])
      end
    end

    it "inserts reviewer right after responsible and leaves other groups untouched" do
      migrate!

      expect(raw_groups(type)).to eq([["people", %w[assignee author responsible reviewer]],
                                      ["details", %w[priority date]]])
    end
  end

  context "with a saved People group that has Accountable in the middle" do
    let!(:type) do
      create(:type).tap { |t| persist_raw(t, [["people", %w[assignee responsible author]]]) }
    end

    it "keeps reviewer next to responsible" do
      migrate!

      expect(raw_groups(type)).to eq([["people", %w[assignee responsible reviewer author]]])
    end
  end

  context "with a saved People group without Accountable" do
    let!(:type) do
      create(:type).tap { |t| persist_raw(t, [["people", %w[assignee author]]]) }
    end

    it "inserts reviewer after assignee" do
      migrate!

      expect(raw_groups(type)).to eq([["people", %w[assignee reviewer author]]])
    end
  end

  context "with an empty People group" do
    let!(:type) do
      create(:type).tap { |t| persist_raw(t, [["people", %w[]], ["details", %w[priority]]]) }
    end

    it "appends reviewer to the People group" do
      migrate!

      expect(raw_groups(type)).to eq([["people", %w[reviewer]], ["details", %w[priority]]])
    end
  end

  context "with a People group that already contains reviewer" do
    let!(:type) do
      create(:type).tap { |t| persist_raw(t, [["people", %w[assignee reviewer]]]) }
    end

    it "does not add it twice" do
      expect { migrate! }.not_to change { raw_groups(type) }
    end
  end

  context "with a saved configuration that has no People group" do
    let!(:type) do
      create(:type).tap { |t| persist_raw(t, [["details", %w[priority date]]]) }
    end

    it "leaves the configuration untouched" do
      expect { migrate! }.not_to change { raw_groups(type) }
    end
  end

  context "with the default (unpersisted) configuration" do
    let!(:type) { create(:type) }

    it "stays blank, so the default groups apply" do
      expect(raw_groups(type)).to be_blank

      migrate!

      expect(raw_groups(type)).to be_blank
    end
  end

  describe "reverting" do
    subject(:rollback!) { ActiveRecord::Migration.suppress_messages { described_class.migrate(:down) } }

    let!(:type) do
      create(:type).tap { |t| persist_raw(t, [["people", %w[assignee responsible reviewer]], ["details", %w[priority]]]) }
    end

    it "removes reviewer from every group again" do
      rollback!

      expect(raw_groups(type)).to eq([["people", %w[assignee responsible]], ["details", %w[priority]]])
    end
  end
end
