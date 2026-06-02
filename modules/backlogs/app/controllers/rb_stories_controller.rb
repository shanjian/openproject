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

class RbStoriesController < RbApplicationController
  include OpTurbo::ComponentStream

  before_action :load_story

  def move # rubocop:disable Metrics/AbcSize
    # The update service reloads the story internally (via #move_after),
    # so we memoize the previous version_id before the call.
    version_id_was = @story.version_id

    call = Stories::UpdateService
      .new(user: current_user, story: @story)
      .call(
        attributes: move_attributes,
        position: move_params[:position].to_i
      )

    unless call.success?
      render_error_flash_message_via_turbo_stream(
        message: I18n.t(:notice_unsuccessful_update_with_reason, reason: call.message)
      )
    end

    # Refresh the source column the story came from.
    if @sprint
      replace_backlog_component_via_turbo_stream(sprint: @sprint)
    else
      replace_inbox_component_via_turbo_stream
    end

    if @story.version_id != version_id_was
      from_name = @sprint ? @sprint.name : I18n.t("backlogs.inbox_component.title")
      to_name, refresh_target = destination_for_flash

      render_success_flash_message_via_turbo_stream(
        message: I18n.t(:notice_successful_move, from: from_name, to: to_name)
      )
      refresh_target.call
    end

    respond_with_turbo_streams
  end

  # Returns the contents of the row's ActionMenu as an HTML fragment, loaded
  # by `Primer::Alpha::ActionMenu(src:)` on first hover/click. Rendering the
  # menu eagerly per row across hundreds of rows caused the backlogs page to
  # peg browser CPU on initial render; deferring the items keeps the inline
  # DOM minimal (just the kebab trigger) while still restoring the items
  # (including the keyboard-accessible move actions) when the user opens
  # the menu.
  def menu
    @max_position = WorkPackage
      .where(Story.condition(@project.id, [@sprint.id]))
      .maximum(:position) || 0

    render layout: false
  end

  def reorder
    call = Stories::UpdateService
      .new(user: current_user, story: @story)
      .call(attributes: { move_to: reorder_param })

    unless call.success?
      render_error_flash_message_via_turbo_stream(
        message: I18n.t(:notice_unsuccessful_update_with_reason, reason: call.message)
      )
    end

    replace_backlog_component_via_turbo_stream(sprint: @sprint)

    respond_with_turbo_streams
  end

  private

  def replace_backlog_component_via_turbo_stream(sprint:)
    # Backlog.for resolves the column's include-closed state from the user's
    # per-column preference, so the refreshed column matches what the toggle
    # last set.
    @backlog = Backlog.for(sprint:, project: @project, user: current_user)
    replace_via_turbo_stream(
      component: Backlogs::BacklogComponent.new(backlog: @backlog, project: @project)
    )
  end

  def replace_inbox_component_via_turbo_stream
    include_closed = current_user.backlogs_include_closed?(:inbox)
    inbox = Backlog.inbox_backlog(@project, include_closed:)
    replace_via_turbo_stream(
      component: Backlogs::InboxComponent.new(inbox:, project: @project, include_closed:)
    )
  end

  def move_attributes
    if inbox_target?
      { version_id: nil, sprint_id: nil }
    else
      { version_id: move_params[:target_id] }
    end
  end

  def destination_for_flash
    if inbox_target?
      [I18n.t("backlogs.inbox_component.title"), -> { replace_inbox_component_via_turbo_stream }]
    else
      new_sprint = @story.version.becomes(Sprint)
      [new_sprint.name, -> { replace_backlog_component_via_turbo_stream(sprint: new_sprint) }]
    end
  end

  def inbox_target?
    move_params[:target_id].to_s == Backlogs::InboxComponent::INBOX_TARGET_ID
  end

  def load_story
    @story = Story.visible.find(params[:id])
  end

  def move_params
    params.require(%i[position target_id])
    params.permit(:position, :target_id)
  end

  def reorder_param
    params.expect(:direction)
  end
end
