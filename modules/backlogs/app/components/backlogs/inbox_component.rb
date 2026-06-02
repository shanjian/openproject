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

module Backlogs
  class InboxComponent < ApplicationComponent
    include Primer::AttributesHelper
    include OpTurbo::Streamable
    include RbCommonHelper

    # Sentinel value used in drag-drop URLs and turbo-stream targets to
    # identify the inbox column (it has no sprint/version primary key).
    INBOX_TARGET_ID = "inbox"

    attr_reader :inbox, :project, :current_user, :include_closed

    delegate :stories, to: :inbox

    def initialize(inbox:, project:, current_user: User.current, include_closed: false, **system_arguments)
      super()

      @inbox = inbox
      @project = project
      @current_user = current_user
      @include_closed = include_closed

      @system_arguments = system_arguments
      @system_arguments[:id] = "backlogs-inbox-component"
      @system_arguments[:list_id] = "#{@system_arguments[:id]}-list"
      @system_arguments[:padding] = :condensed
      @system_arguments[:data] = merge_data(
        @system_arguments,
        { data: drop_target_config.merge(controller: "backlogs--card-list-filter") }
      )
    end

    def wrapper_uniq_by
      INBOX_TARGET_ID
    end

    private

    def folded?
      current_user.backlogs_preference(:versions_default_fold_state) == "closed"
    end

    def max_position
      stories.filter_map(&:position).max
    end

    def drop_target_config
      {
        generic_drag_and_drop_target: "container",
        target_container_accessor: ":scope > ul",
        target_id: INBOX_TARGET_ID,
        target_allowed_drag_type: "story"
      }
    end

    def draggable_item_config(story)
      {
        draggable_id: story.id,
        draggable_type: "story",
        drop_url: move_backlogs_project_inbox_story_path(project_id: project, id: story)
      }
    end
  end
end
