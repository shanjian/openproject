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
  class SprintComponent < ApplicationComponent
    include Primer::AttributesHelper
    include OpTurbo::Streamable
    include RbCommonHelper

    attr_reader :sprint, :current_user, :include_closed

    delegate :project, to: :sprint

    def initialize(sprint:, current_user: User.current, **system_arguments)
      super()

      @sprint = sprint
      @current_user = current_user
      @include_closed = current_user.backlogs_include_closed?(:sprint, sprint.id)

      @system_arguments = system_arguments
      @system_arguments[:id] = dom_id(sprint)
      @system_arguments[:list_id] = "#{@system_arguments[:id]}-list"
      @system_arguments[:padding] = :condensed
      @system_arguments[:data] = merge_data(
        @system_arguments,
        { data: drop_target_config.merge(controller: "backlogs--card-list-filter") }
      )
    end

    def stories
      @stories ||= sprint.board_work_packages(include_closed:).to_a
    end

    def wrapper_uniq_by
      sprint.id
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
        target_id: sprint.id,
        target_allowed_drag_type: "story"
      }
    end

    def draggable_item_config(story)
      {
        draggable_id: story.id,
        draggable_type: "story",
        drop_url: move_backlogs_project_sprint_story_path(project_id: project, sprint_id: sprint, id: story)
      }
    end
  end
end
