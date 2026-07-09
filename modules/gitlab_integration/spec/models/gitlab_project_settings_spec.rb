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
require_module_spec_helper

RSpec.describe GitlabProjectSettings do
  shared_let(:project) { create(:project) }

  it "requires a gitlab_project_id" do
    expect(described_class.new(project:, gitlab_project_id: nil)).not_to be_valid
  end

  it "allows only one row per project" do
    described_class.create!(project:, gitlab_project_id: "1")
    duplicate = described_class.new(project:, gitlab_project_id: "2")

    expect(duplicate).not_to be_valid
  end

  it "is removed when its project is deleted (FK cascade)" do
    deletable = create(:project)
    described_class.create!(project: deletable, gitlab_project_id: "42")

    expect { deletable.destroy }.to change(described_class, :count).by(-1)
  end
end
