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

RSpec.describe WorkPackages::ImportRun do
  it "defaults to queued status with no created work packages" do
    run = described_class.new(project: build_stubbed(:project),
                              user: build_stubbed(:user),
                              source: "# Task: Do the thing")

    expect(run.status).to eq("queued")
    expect(run.created_work_package_ids).to eq([])
  end

  it "requires source" do
    run = described_class.new(project: build_stubbed(:project), user: build_stubbed(:user))

    expect(run).not_to be_valid
    expect(run.errors[:source]).to be_present
  end

  it "exposes status as a queryable enum" do
    run = described_class.new(status: "succeeded")

    expect(run).to be_succeeded
  end
end
