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

RSpec.describe User, "backlogs include-closed preference" do
  shared_let(:user) { create(:user) }

  describe "#backlogs_include_closed? (per-type defaults)" do
    it "defaults to false for the inbox" do
      expect(user.backlogs_include_closed?(:inbox)).to be(false)
    end

    it "defaults to true for a sprint column (active work shows progress)" do
      expect(user.backlogs_include_closed?(:sprint, 42)).to be(true)
    end

    it "defaults to false for a version/owner backlog column" do
      expect(user.backlogs_include_closed?(:backlog, 7)).to be(false)
    end
  end

  describe "#set_backlogs_include_closed" do
    it "persists a per-column override, including a non-default false" do
      user.set_backlogs_include_closed(:sprint, 42, false)

      expect(user.backlogs_include_closed?(:sprint, 42)).to be(false)
    end

    it "scopes the override to a single column, leaving siblings on their default" do
      user.set_backlogs_include_closed(:sprint, 42, false)

      expect(user.backlogs_include_closed?(:sprint, 99)).to be(true)
    end

    it "stores the inbox value under the bare list-type key" do
      user.set_backlogs_include_closed(:inbox, nil, true)

      expect(user.backlogs_include_closed?(:inbox)).to be(true)
    end

    it "survives a reload" do
      user.set_backlogs_include_closed(:backlog, 7, true)

      expect(user.reload.backlogs_include_closed?(:backlog, 7)).to be(true)
    end

    it "accepts string truthy values from request params" do
      user.set_backlogs_include_closed(:inbox, nil, "1")

      expect(user.backlogs_include_closed?(:inbox)).to be(true)
    end
  end
end
