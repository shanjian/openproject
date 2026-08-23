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

RSpec.describe Projects::Versions do
  let(:project) { create(:project) }

  describe "#assignable_versions" do
    # This is the scope backing the version picker in the bulk-edit dropdown
    # and the work package form - reversed alphabetically ("Version 3" before
    # "Version 1") so the most recently numbered version surfaces first.
    let!(:version_b) { create(:version, project:, name: "Version B") }
    let!(:version_a) { create(:version, project:, name: "Version A") }
    let!(:version_c) { create(:version, project:, name: "Version C") }

    it "returns versions ordered by name, descending" do
      expect(project.assignable_versions.map(&:name)).to eq(%w[Version\ C Version\ B Version\ A])
    end

    context "with a kind filter" do
      let!(:release_version) { create(:version, project:, name: "Version D", kind: "release") }

      it "restricts the result to that kind while keeping the descending order" do
        expect(project.assignable_versions(kind: "release").map(&:name)).to eq(["Version D"])
        expect(project.assignable_versions.map(&:name)).to eq(%w[Version\ D Version\ C Version\ B Version\ A])
      end
    end
  end
end
