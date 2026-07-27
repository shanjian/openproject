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
require Rails.root.join("db/migrate/20260727120000_restore_accountable_in_reporter_type_form_configs.rb")

RSpec.describe RestoreAccountableInReporterTypeFormConfigs, type: :model do
  subject(:migrate!) { ActiveRecord::Migration.suppress_messages { described_class.migrate(:up) } }

  def raw_groups(type)
    Type.where(id: type.id).pick(:attribute_groups)
  end

  # Simulate a config persisted under the old broken behaviour by writing the
  # raw column directly, bypassing the read-time reporter normalization.
  def persist_raw(type, groups)
    type.update_column(:attribute_groups, groups)
  end

  context "with a reporter type whose persisted People group lost Accountable" do
    let!(:type) do
      create(:type, name: "Task").tap do |t|
        persist_raw(t, [["people", %w[assignee author]], ["details", %w[priority date]]])
      end
    end

    it "reinserts responsible right after author, leaving other groups untouched" do
      migrate!

      expect(raw_groups(type)).to eq([["people", %w[assignee author responsible]],
                                      ["details", %w[priority date]]])
    end
  end

  context "with a reporter type that already has Accountable" do
    let!(:type) do
      create(:type, name: "Bug").tap do |t|
        persist_raw(t, [["people", %w[assignee author responsible]]])
      end
    end

    it "leaves the config unchanged" do
      expect { migrate! }.not_to change { raw_groups(type) }
    end
  end

  context "with a reporter type using the default (unpersisted) config" do
    let!(:type) { create(:type, name: "Epic") }

    it "leaves the empty persisted config untouched" do
      expect(raw_groups(type)).to be_blank

      migrate!

      expect(raw_groups(type)).to be_blank
    end
  end

  context "with a non-reporter type missing responsible" do
    let!(:type) do
      create(:type, name: "Ticket").tap do |t|
        persist_raw(t, [["people", %w[assignee]]])
      end
    end

    it "is left untouched" do
      expect { migrate! }.not_to change { raw_groups(type) }
    end
  end

  context "with a reporter type whose People group has no assignee or author" do
    let!(:type) do
      create(:type, name: "Feature").tap do |t|
        persist_raw(t, [["people", %w[]], ["details", %w[priority]]])
      end
    end

    it "appends responsible to the People group" do
      migrate!

      expect(raw_groups(type)).to eq([["people", %w[responsible]], ["details", %w[priority]]])
    end
  end
end
