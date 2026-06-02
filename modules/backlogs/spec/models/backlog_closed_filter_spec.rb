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

RSpec.describe "Backlogs closed-status filtering", type: :model do
  shared_let(:feature_type) { create(:type_feature) }
  shared_let(:open_status) { create(:status, is_closed: false, is_default: true) }
  shared_let(:closed_status) { create(:status, is_closed: true) }

  let(:project) { create(:project, types: [feature_type]) }

  before do
    allow(Setting)
      .to receive(:plugin_openproject_backlogs)
      .and_return("story_types" => [feature_type.id.to_s], "task_type" => nil)
  end

  describe "Story.backlog_for" do
    let(:version) { create(:version, project:) }
    let!(:open_wp) do
      create(:work_package, project:, type: feature_type, status: open_status, version:)
    end
    let!(:closed_wp) do
      create(:work_package, project:, type: feature_type, status: closed_status, version:)
    end

    it "excludes closed work packages by default" do
      stories, = Story.backlog_for(project.id, version.id)

      expect(stories.map(&:id)).to contain_exactly(open_wp.id)
    end

    it "includes closed work packages when include_closed: true" do
      stories, = Story.backlog_for(project.id, version.id, include_closed: true)

      expect(stories.map(&:id)).to contain_exactly(open_wp.id, closed_wp.id)
    end
  end

  describe "Agile::Sprint#board_work_packages" do
    let(:sprint) { create(:agile_sprint, project:) }
    let!(:open_wp) do
      create(:work_package, project:, type: feature_type, status: open_status, sprint:)
    end
    let!(:closed_wp) do
      create(:work_package, project:, type: feature_type, status: closed_status, sprint:)
    end

    it "excludes closed work packages by default" do
      expect(sprint.board_work_packages.map(&:id)).to contain_exactly(open_wp.id)
    end

    it "includes closed work packages when include_closed: true" do
      expect(sprint.board_work_packages(include_closed: true).map(&:id))
        .to contain_exactly(open_wp.id, closed_wp.id)
    end
  end
end
