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

RSpec.describe GitlabProjectMapping do
  shared_let(:project) { create(:project) }

  it "requires a gitlab_project_id" do
    expect(described_class.new(project:, gitlab_project_id: nil)).not_to be_valid
  end

  it "allows several GitLab projects per OpenProject project" do
    described_class.create!(project:, gitlab_project_id: "group/backend")
    second = described_class.new(project:, gitlab_project_id: "group/frontend")

    expect(second).to be_valid
  end

  it "rejects the same GitLab project mapped twice in one project" do
    described_class.create!(project:, gitlab_project_id: "group/backend")
    duplicate = described_class.new(project:, gitlab_project_id: "group/backend")

    expect(duplicate).not_to be_valid
  end

  describe "#display_name" do
    it "uses the name when present" do
      mapping = described_class.new(name: "Backend API", gitlab_project_id: "group/backend")
      expect(mapping.display_name).to eq("Backend API")
    end

    it "falls back to the GitLab project id/path" do
      mapping = described_class.new(name: "", gitlab_project_id: "group/backend")
      expect(mapping.display_name).to eq("group/backend")
    end
  end

  it "is removed when its project is deleted (FK cascade)" do
    deletable = create(:project)
    described_class.create!(project: deletable, gitlab_project_id: "42")

    expect { deletable.destroy }.to change(described_class, :count).by(-1)
  end
end
