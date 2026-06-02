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

class RbMasterBacklogsController < RbApplicationController
  include WorkPackages::WithSplitView
  include OpTurbo::ComponentStream

  menu_item :backlogs

  before_action :load_backlogs, only: :index

  def index
    if OpenProject::FeatureDecisions.scrum_projects_active?
      # Feature flag is active, render the new views
      if turbo_frame_request?
        render partial: "agile_list", layout: false
      else
        render :agile_index
      end
    else
      # Feature flag is not active, render legacy views
      if turbo_frame_request? # rubocop:disable Style/IfInsideElse
        render partial: "list", layout: false
      else
        render :index
      end
    end
  end

  def details
    if turbo_frame_request?
      render "work_packages/split_view", layout: false
    else
      load_backlogs

      if OpenProject::FeatureDecisions.scrum_projects_active?
        render :agile_index
      else
        render :index
      end
    end
  end

  def split_view_base_route = backlogs_project_backlogs_path(request.query_parameters)

  LIST_TYPES = %w[inbox sprint backlog].freeze

  # Persists the per-column "include closed items" preference and re-renders
  # only the affected column via turbo-stream.
  def toggle_include_closed
    list_type, column_id, include_closed = parse_toggle_params
    return head :unprocessable_entity if list_type.nil?

    current_user.set_backlogs_include_closed(list_type, column_id, include_closed)
    replace_column_via_turbo_stream(list_type, column_id, include_closed)
    respond_with_turbo_streams
  end

  private

  # Returns [list_type, column_id, include_closed], or nil when the request is
  # malformed (unknown list type, or a non-inbox column without an id).
  def parse_toggle_params
    list_type = params[:list_type].to_s
    column_id = params[:column_id].presence
    return unless LIST_TYPES.include?(list_type)
    return if list_type != "inbox" && column_id.blank?

    [list_type, column_id, ActiveModel::Type::Boolean.new.cast(params[:include_closed])]
  end

  def load_backlogs
    @owner_backlogs = Backlog.owner_backlogs(@project, user: current_user)
    @inbox_include_closed = current_user.backlogs_include_closed?(:inbox)
    @inbox_backlog = Backlog.inbox_backlog(@project, include_closed: @inbox_include_closed)

    if OpenProject::FeatureDecisions.scrum_projects_active?
      @sprints = Agile::Sprint.for_project(@project).not_completed.order_by_date
    else
      @sprint_backlogs = Backlog.sprint_backlogs(@project, user: current_user)
    end
  end

  def replace_column_via_turbo_stream(list_type, column_id, include_closed)
    component =
      if list_type == "inbox"
        inbox = Backlog.inbox_backlog(@project, include_closed:)
        Backlogs::InboxComponent.new(inbox:, project: @project, include_closed:)
      elsif list_type == "sprint" && OpenProject::FeatureDecisions.scrum_projects_active?
        sprint = Agile::Sprint.for_project(@project).find(column_id)
        Backlogs::SprintComponent.new(sprint:)
      else
        # Legacy sprint column and version/owner backlog column both render
        # through the Backlog value object + BacklogComponent.
        sprint = Sprint.visible.apply_to(@project).find(column_id)
        backlog = Backlog.for(sprint:, project: @project, include_closed:)
        Backlogs::BacklogComponent.new(backlog:, project: @project)
      end

    replace_via_turbo_stream(component:)
  end
end
