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

RSpec.describe RbStoriesController, "inbox move flows" do
  shared_let(:type_feature) { create(:type_feature) }
  shared_let(:type_task) { create(:type_task) }
  shared_let(:user) { create(:admin) }
  current_user { user }

  let(:project) { create(:project) }
  let(:status)  { create(:status, name: "status 1", is_default: true) }
  let(:sprint)  { create(:sprint, project:) }

  before do
    allow(Setting)
      .to receive(:plugin_openproject_backlogs)
      .and_return({ "story_types" => [type_feature.id], "task_type" => type_task.id })
  end

  describe "PUT #move from sprint into inbox" do
    let(:story) { create(:story, status:, version: sprint, project:) }

    it "clears version_id and sprint_id, refreshes both source sprint and inbox columns" do
      put :move, params: {
                   project_id: project.id,
                   sprint_id: sprint.id,
                   id: story.id,
                   target_id: Backlogs::InboxComponent::INBOX_TARGET_ID,
                   position: 1
                 },
                 format: :turbo_stream

      expect(response).to have_http_status :ok
      expect(story.reload.version_id).to be_nil
      expect(story.sprint_id).to be_nil
      expect(response).to have_turbo_stream action: "replace", target: "backlogs-backlog-component-#{sprint.id}"
      expect(response).to have_turbo_stream action: "replace", target: "backlogs-inbox-component-inbox"
    end
  end

  describe "PUT #move from inbox into a sprint via the non-nested route" do
    let(:story) { create(:story, status:, version: nil, project:) }

    it "assigns version_id and refreshes both inbox and destination sprint columns" do
      put :move, params: {
                   project_id: project.id,
                   id: story.id,
                   target_id: sprint.id,
                   position: 1
                 },
                 format: :turbo_stream

      expect(response).to have_http_status :ok
      expect(story.reload.version_id).to eq(sprint.id)
      expect(response).to have_turbo_stream action: "replace", target: "backlogs-inbox-component-inbox"
      expect(response).to have_turbo_stream action: "replace", target: "backlogs-backlog-component-#{sprint.id}"
    end
  end

  describe "PUT #move when both source and target are the inbox" do
    let(:story) { create(:story, status:, version: nil, project:) }

    it "leaves version_id nil and only refreshes the inbox column" do
      put :move, params: {
                   project_id: project.id,
                   id: story.id,
                   target_id: Backlogs::InboxComponent::INBOX_TARGET_ID,
                   position: 1
                 },
                 format: :turbo_stream

      expect(response).to have_http_status :ok
      expect(story.reload.version_id).to be_nil
      expect(response).to have_turbo_stream action: "replace", target: "backlogs-inbox-component-inbox"
    end
  end

  describe "PUT #move rebuilds the inbox column from the stored include-closed preference" do
    let(:story_to_move) { create(:story, status:, version: nil, project:) }

    before { allow(Backlogs::InboxComponent).to receive(:new).and_call_original }

    it "rebuilds the inbox component with include_closed: true when the inbox preference is on" do
      user.set_backlogs_include_closed(:inbox, nil, true)

      put :move, params: {
                   project_id: project.id,
                   id: story_to_move.id,
                   target_id: Backlogs::InboxComponent::INBOX_TARGET_ID,
                   position: 1
                 },
                 format: :turbo_stream

      expect(response).to have_http_status :ok
      expect(Backlogs::InboxComponent).to have_received(:new).with(hash_including(include_closed: true))
    end

    it "rebuilds the inbox component with include_closed: false by default" do
      put :move, params: {
                   project_id: project.id,
                   id: story_to_move.id,
                   target_id: Backlogs::InboxComponent::INBOX_TARGET_ID,
                   position: 1
                 },
                 format: :turbo_stream

      expect(response).to have_http_status :ok
      expect(Backlogs::InboxComponent).to have_received(:new).with(hash_including(include_closed: false))
    end
  end
end
