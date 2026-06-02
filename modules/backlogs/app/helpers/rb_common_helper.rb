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

module RbCommonHelper
  # Appends the per-column "include closed items" toggle to a Primer
  # ActionMenu (`menu`). Activating it issues a turbo PUT that flips the
  # stored preference and re-renders just this column; the in-column spinner
  # is driven by the `backlogs--card-list-filter` Stimulus controller.
  #
  # `list_type` is one of "inbox" / "sprint" / "backlog"; `column_id` is the
  # column's id (nil for the inbox).
  def include_closed_action_menu_item(menu, project:, list_type:, column_id:, include_closed:)
    menu.with_item(
      label: I18n.t("backlogs.include_closed.menu_item"),
      href: toggle_include_closed_backlogs_project_backlogs_path(
        project,
        list_type:,
        column_id:,
        include_closed: !include_closed
      ),
      content_arguments: {
        data: {
          turbo_method: :put,
          turbo_stream: true,
          action: "backlogs--card-list-filter#loading"
        }
      }
    ) do |item|
      item.with_leading_visual_icon(icon: include_closed ? :check : :dash)
    end
  end

  def format_date_range(dates)
    return nil if dates.all?(&:nil?)

    from, to = dates.map { |date| tag.time(datetime: date.iso8601) { format_date(date) } if date }
    safe_join([from, "–", to], " ") # &ndash; and &nbsp;
  end

  def assignee_id_or_empty(story)
    story.assigned_to_id.to_s
  end

  def assignee_name_or_empty(story)
    story.blank? || story.assigned_to.blank? ? "" : "#{story.assigned_to.firstname} #{story.assigned_to.lastname}"
  end

  def blocks_ids(ids)
    ids.sort.join(",")
  end

  def build_inline_style(task)
    is_assigned_task?(task) ? color_style(task) : ""
  end

  def color_style(task)
    background_color = get_backlogs_preference(task.assigned_to, :task_color)

    "style=\"background-color:#{background_color};\"".html_safe
  end

  def color_contrast_class(task)
    if is_assigned_task?(task)
      color_contrast(background_color_hex(task)) ? "light" : "dark"
    else
      ""
    end
  end

  def color_contrast(color)
    _, bright = find_color_diff 0x000000, color
    (bright > 128)
  end

  # Return the contrast and brightness difference between two RGB values
  def find_color_diff(c1, c2)
    r1, g1, b1 = break_color c1
    r2, g2, b2 = break_color c2
    cont_diff = (r1 - r2).abs + (g1 - g2).abs + (b1 - b2).abs # Color contrast
    bright1 = ((r1 * 299) + (g1 * 587) + (b1 * 114)) / 1000
    bright2 = ((r2 * 299) + (g2 * 587) + (b2 * 114)) / 1000
    brt_diff = (bright1 - bright2).abs # Color brightness diff
    [cont_diff, brt_diff]
  end

  # Break a color into the R, G and B components
  def break_color(rgb)
    r = (rgb & 0xff0000) >> 16
    g = (rgb & 0x00ff00) >> 8
    b = rgb & 0x0000ff
    [r, g, b]
  end

  def is_assigned_task?(task)
    !(task.blank? || task.assigned_to.blank?)
  end

  def background_color_hex(task)
    background_color = get_backlogs_preference(task.assigned_to, :task_color)
    background_color.sub("#", "0x").hex
  end

  def id_or_empty(item)
    item.id.to_s
  end

  def work_package_link_or_empty(work_package)
    modal_link_to_work_package(work_package.id, work_package, class: "prevent_edit") unless work_package.new_record?
  end

  def modal_link_to_work_package(title, work_package, options = {})
    modal_link_to(title, work_package_path(work_package), options)
  end

  def modal_link_to(title, path, options = {})
    html_id = "modal_work_package_#{SecureRandom.hex(10)}"
    link_to(title, path, options.merge(id: html_id, target: "_blank"))
  end

  def mark_if_closed(story)
    !story.new_record? && work_package_status_for_id(story.status_id).is_closed? ? "closed" : ""
  end

  def story_html_id_or_empty(story)
    story.id.nil? ? "" : "story_#{story.id}"
  end

  def date_string_with_milliseconds(d, add = 0)
    return "" if d.blank?

    d.strftime("%B %d, %Y %H:%M:%S") + "." + ((d.to_f % 1) + add).to_s.split(".")[1]
  end

  def remaining_hours(item)
    item.remaining_hours.blank? || item.remaining_hours == 0 ? "" : item.remaining_hours
  end

  def scrum_projects_enabled?
    OpenProject::FeatureDecisions.scrum_projects_active?
  end

  def allow_sprint_creation?(project)
    scrum_projects_enabled? && current_user.allowed_in_project?(:create_sprints, project)
  end

  private

  def work_package_status_for_id(id)
    @all_work_package_status_by_id ||= all_work_package_status.inject({}) do |mem, status|
      mem[status.id] = status
      mem
    end

    @all_work_package_status_by_id[id]
  end

  def all_work_package_status
    @all_work_package_status ||= Status.order(Arel.sql("position ASC"))
  end

  def backlogs_types
    @backlogs_types ||= begin
      backlogs_ids = Setting.plugin_openproject_backlogs["story_types"]
      backlogs_ids << Setting.plugin_openproject_backlogs["task_type"]

      Type.where(id: backlogs_ids).order(Arel.sql("position ASC"))
    end
  end

  def story_types
    @story_types ||= begin
      backlogs_type_ids = Setting.plugin_openproject_backlogs["story_types"].map(&:to_i)

      backlogs_types.select { |t| backlogs_type_ids.include?(t.id) }
    end
  end

  def get_backlogs_preference(assignee, attr)
    assignee.is_a?(User) ? assignee.backlogs_preference(attr) : "#24B3E7"
  end
end
