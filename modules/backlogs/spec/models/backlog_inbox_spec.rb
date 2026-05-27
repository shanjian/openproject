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

RSpec.describe Backlog, ".inbox_backlog" do
  let(:project) { create(:project) }
  let(:other_project) { create(:project) }
  let(:status) { create(:status) }
  let(:feature_type) { create(:type_feature) }
  let(:bug_type) { create(:type_bug) }
  let(:version) { create(:version, project:) }

  before do
    allow(Setting).to receive(:plugin_openproject_backlogs)
      .and_return({ "story_types" => [feature_type.id.to_s], "task_type" => "0" })
  end

  subject { described_class.inbox_backlog(project) }

  it "is marked as inbox" do
    expect(subject).to be_inbox
    expect(subject).not_to be_sprint_backlog
    expect(subject).not_to be_owner_backlog
  end

  context "when the project has work packages without a version" do
    let!(:wp_without_version) do
      create(:work_package, project:, type: feature_type, status:, version: nil)
    end
    let!(:wp_with_version) do
      create(:work_package, project:, type: feature_type, status:, version:)
    end

    it "includes only work packages with no version" do
      expect(subject.stories.map(&:id)).to contain_exactly(wp_without_version.id)
    end
  end

  context "when work packages exist in another project" do
    let!(:other_project_wp) do
      create(:work_package, project: other_project, type: feature_type, status:, version: nil)
    end

    it "is scoped to the requested project" do
      expect(subject.stories).to be_empty
    end
  end

  context "when work packages of non-story types exist without a version" do
    let!(:bug_wp) do
      create(:work_package, project:, type: bug_type, status:, version: nil)
    end

    it "includes all types regardless of story_types configuration" do
      expect(subject.stories.map(&:id)).to include(bug_wp.id)
    end
  end

  context "when stories are positioned" do
    let!(:third) do
      create(:work_package, project:, type: feature_type, status:, version: nil, position: 30)
    end
    let!(:first) do
      create(:work_package, project:, type: feature_type, status:, version: nil, position: 10)
    end
    let!(:second) do
      create(:work_package, project:, type: feature_type, status:, version: nil, position: 20)
    end

    it "returns stories ordered by position with NULLS-LAST and assigns sequential ranks" do
      expect(subject.stories.map(&:id)).to eq([first.id, second.id, third.id])
      expect(subject.stories.map(&:rank)).to eq([1, 2, 3])
    end
  end
end
