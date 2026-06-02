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

RSpec.describe Backlogs::BacklogComponent, type: :component do
  shared_let(:type_feature) { create(:type_feature) }
  shared_let(:type_task) { create(:type_task) }
  shared_let(:default_status) { create(:default_status) }
  shared_let(:default_priority) { create(:default_priority) }
  shared_let(:user) { create(:admin) }
  current_user { user }

  let(:project) { create(:project, types: [type_feature, type_task]) }
  let(:sprint) { create(:sprint, project:, name: "Sprint 1", start_date: Date.yesterday, effective_date: Date.tomorrow) }
  let(:stories) { [] }
  let(:backlog) { Backlog.new(sprint:, stories:) }

  before do
    allow(Setting)
      .to receive(:plugin_openproject_backlogs)
      .and_return("story_types" => [type_feature.id.to_s], "task_type" => type_task.id.to_s)

    allow(user).to receive(:backlogs_preference).with(:versions_default_fold_state).and_return("open")
  end

  def render_component
    render_inline(
      described_class.new(backlog:, project:, current_user: user)
    )
  end

  describe "rendering" do
    context "with stories" do
      let(:story1) do
        create(:story,
               project:,
               type: type_feature,
               status: default_status,
               priority: default_priority,
               story_points: 5,
               position: 1,
               version: sprint)
      end
      let(:story2) do
        create(:story,
               project:,
               type: type_feature,
               status: default_status,
               priority: default_priority,
               story_points: 3,
               position: 2,
               version: sprint)
      end
      let(:stories) { [story1, story2] }

      it "renders a Primer::Beta::BorderBox" do
        render_component

        expect(page).to have_css(".Box")
      end

      it "has the sprint ID in the DOM id" do
        render_component

        expect(page).to have_css(".Box#backlog_#{sprint.id}")
      end

      it "renders BacklogHeaderComponent in header" do
        render_component

        expect(page).to have_css(".Box-header h3", text: "Sprint 1")
      end

      it "renders StoryComponent for each story" do
        render_component

        expect(page).to have_css(".Box-row", count: 2) # 2 stories
        expect(page).to have_text(story1.subject)
        expect(page).to have_text(story2.subject)
      end

      it "has drop target data attributes" do
        render_component

        box = page.find(".Box")
        expect(box["data-target-id"]).to eq(sprint.id.to_s)
        expect(box["data-target-allowed-drag-type"]).to eq("story")
      end

      it "has draggable data attributes on story rows" do
        render_component

        story_row = page.find(".Box-row[id='story_#{story1.id}']")
        expect(story_row["data-draggable-id"]).to eq(story1.id.to_s)
        expect(story_row["data-draggable-type"]).to eq("story")
        expect(story_row["data-drop-url"]).to include("move")
      end

      it "renders story rows with proper classes" do
        render_component

        story_row = page.find(".Box-row[id='story_#{story1.id}']")
        expect(story_row[:class]).to include("Box-row--hover-blue")
        expect(story_row[:class]).to include("Box-row--focus-gray")
        expect(story_row[:class]).to include("Box-row--clickable")
      end

      it "offers an include-closed menu item keyed to this column" do
        render_component

        expect(page).to have_text(I18n.t("backlogs.include_closed.menu_item"))
        link = page.find(:link, I18n.t("backlogs.include_closed.menu_item"), visible: :all)
        expect(link["href"]).to include("list_type=sprint", "column_id=#{sprint.id}", "include_closed=true")
        expect(link["data-turbo-method"]).to eq("put")
      end
    end

    context "without stories" do
      let(:stories) { [] }
      let(:rendered_component) { render_component }

      it_behaves_like "rendering Blank Slate", heading: "Sprint 1 is empty"
    end

    context "when the column is truncated" do
      let(:story) do
        create(:story, project:, type: type_feature, status: default_status,
                       priority: default_priority, story_points: 1, position: 1, version: sprint)
      end
      let(:stories) { [story] }
      let(:backlog) { Backlog.new(sprint:, stories:, truncated: true) }

      it "renders a truncation banner at the column footer" do
        render_component

        expect(page).to have_text(I18n.t("backlogs.column_truncated", count: Story::COLUMN_LIMIT))
      end
    end

    context "when the column is not truncated" do
      let(:story) do
        create(:story, project:, type: type_feature, status: default_status,
                       priority: default_priority, story_points: 1, position: 1, version: sprint)
      end
      let(:stories) { [story] }
      let(:backlog) { Backlog.new(sprint:, stories:) }

      it "does not render the truncation banner" do
        render_component

        expect(page).to have_no_text(I18n.t("backlogs.column_truncated", count: Story::COLUMN_LIMIT))
      end
    end
  end
end
