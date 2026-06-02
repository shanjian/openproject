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

RSpec.describe Backlogs::InboxComponent, type: :component do
  shared_let(:type_feature) { create(:type_feature) }
  shared_let(:type_task) { create(:type_task) }
  shared_let(:default_status) { create(:default_status) }
  shared_let(:default_priority) { create(:default_priority) }
  shared_let(:user) { create(:admin) }
  current_user { user }

  let(:project) { create(:project, types: [type_feature, type_task]) }
  let(:inbox) { Backlog.inbox_backlog(project) }

  before do
    allow(Setting)
      .to receive(:plugin_openproject_backlogs)
      .and_return("story_types" => [type_feature.id.to_s], "task_type" => type_task.id.to_s)

    allow(user).to receive(:backlogs_preference).with(:versions_default_fold_state).and_return("open")
  end

  def render_component(include_closed: false)
    render_inline(described_class.new(inbox:, project:, current_user: user, include_closed:))
  end

  describe "rendering" do
    context "with unassigned work packages" do
      let!(:wp1) do
        create(:work_package,
               project:,
               type: type_feature,
               status: default_status,
               priority: default_priority,
               version: nil,
               sprint: nil,
               subject: "Unassigned story")
      end
      let!(:wp2) do
        create(:work_package,
               project:,
               type: type_task,
               status: default_status,
               priority: default_priority,
               version: nil,
               sprint: nil,
               subject: "Unassigned task")
      end

      it "renders a Primer::Beta::BorderBox" do
        render_component

        expect(page).to have_css(".Box")
      end

      it "uses the inbox sentinel as the DOM id" do
        render_component

        expect(page).to have_css(".Box#backlogs-inbox-component")
      end

      it "renders the inbox title" do
        render_component

        expect(page).to have_css(".Box-header h3", text: I18n.t("backlogs.inbox_component.title"))
      end

      it "renders a row for each unassigned work package, of any type" do
        render_component

        expect(page).to have_text("Unassigned story")
        expect(page).to have_text("Unassigned task")
      end

      it "advertises the inbox sentinel as drop target id" do
        render_component

        box = page.find(".Box")
        expect(box["data-target-id"]).to eq(described_class::INBOX_TARGET_ID)
        expect(box["data-target-allowed-drag-type"]).to eq("story")
      end

      it "uses the non-nested inbox move URL for draggable items" do
        render_component

        row = page.find(".Box-row[id='story_#{wp1.id}']")
        expect(row["data-draggable-id"]).to eq(wp1.id.to_s)
        expect(row["data-draggable-type"]).to eq("story")
        expect(row["data-drop-url"]).to match(%r{/projects/#{project.identifier}/stories/#{wp1.id}/move\z})
      end

    end

    context "without stories" do
      it "renders the inbox blankslate" do
        render_component

        expect(page).to have_text(I18n.t("backlogs.inbox_component.blankslate_title"))
      end
    end

    describe "truncation banner" do
      let(:inbox) { Backlog.new(sprint: nil, stories: [], inbox: true, truncated: true) }

      it "is rendered when the inbox is truncated" do
        render_component

        expect(page).to have_text(I18n.t("backlogs.column_truncated", count: Story::COLUMN_LIMIT))
      end

      context "when not truncated" do
        let(:inbox) { Backlog.new(sprint: nil, stories: [], inbox: true, truncated: false) }

        it "is not rendered" do
          render_component

          expect(page).to have_no_text(I18n.t("backlogs.column_truncated", count: Story::COLUMN_LIMIT))
        end
      end
    end

    describe "include closed menu" do
      it "renders the inbox actions kebab menu" do
        render_component

        expect(page).to have_css("action-menu")
        expect(page).to have_text(I18n.t("backlogs.include_closed.menu_item"))
      end

      it "links to turn the filter on, unchecked, by default" do
        render_component

        link = page.find(:link, I18n.t("backlogs.include_closed.menu_item"), visible: :all)
        expect(link["href"]).to include("list_type=inbox", "include_closed=true")
        expect(link["href"]).not_to include("column_id")
        expect(link["data-turbo-method"]).to eq("put")
        expect(link["data-turbo-stream"]).to eq("true")
      end

      it "links to turn the filter off when currently on" do
        render_component(include_closed: true)

        link = page.find(:link, I18n.t("backlogs.include_closed.menu_item"), visible: :all)
        expect(link["href"]).to include("include_closed=false")
      end

      it "marks the column for the loading spinner controller" do
        render_component

        expect(page.find(".Box")["data-controller"]).to include("backlogs--card-list-filter")
      end
    end
  end
end
