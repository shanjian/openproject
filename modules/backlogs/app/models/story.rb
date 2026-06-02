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

class Story < WorkPackage
  extend OpenProject::Backlogs::Mixins::PreventIssueSti

  def self.backlogs(project_id, sprint_ids, options = {}) # rubocop:disable Metrics/AbcSize
    options.reverse_merge!(order: Story::ORDER,
                           conditions: Story.condition(project_id, sprint_ids))

    candidates = Story.where(options[:conditions])
                      .includes(:status, :type)
                      .order(Arel.sql(options[:order]))

    stories_by_version = Hash.new do |hash, sprint_id|
      hash[sprint_id] = []
    end

    candidates.each do |story|
      last_rank = if stories_by_version[story.version_id].size > 0
                    stories_by_version[story.version_id].last.rank
                  else
                    0
                  end

      story.rank = last_rank + 1
      stories_by_version[story.version_id] << story
    end

    stories_by_version
  end

  def self.sprint_backlog(project, sprint, options = {})
    Story.backlogs(project.id, [sprint.id], options)[sprint.id]
  end

  # Per-column ceiling used by the master backlog page. Loading thousands of
  # stories per column makes Ruby spend the bulk of the page-render time
  # allocating ViewComponent instances. Cap to a workable size; columns with
  # more items than this render a "showing first N" banner.
  COLUMN_LIMIT = 200

  # Returns [stories, truncated?] for a single backlog column. Uses the
  # `LIMIT + 1` trick to detect truncation without a separate COUNT query.
  # Each story gets a sequential `rank` set, matching `.backlogs`' behavior.
  #
  # By default closed-status work packages are excluded. Pass
  # `include_closed: true` to surface them too (see `inbox_for` for why
  # `preload` is paired with a `joins(:status)` filter rather than
  # `includes`).
  def self.backlog_for(project_id, sprint_id, include_closed: false, limit: COLUMN_LIMIT)
    scope = Story.where(Story.condition(project_id, [sprint_id]))
                 .preload(:status, :type)
    scope = scope.joins(:status).where(statuses: { is_closed: false }) unless include_closed

    candidates = scope.order(Arel.sql(Story::ORDER)).limit(limit + 1).to_a

    truncate_and_rank(candidates, limit)
  end

  # Trims a `limit+1`-sized candidate array to `limit`, signals whether
  # truncation happened, and assigns sequential `rank` values starting at 1.
  # Shared by `backlog_for` and `inbox_for`.
  def self.truncate_and_rank(candidates, limit)
    truncated = candidates.size > limit
    candidates = candidates.first(limit) if truncated
    candidates.each_with_index { |story, i| story.rank = i + 1 }
    [candidates, truncated]
  end
  private_class_method :truncate_and_rank

  # Work packages in this project that belong to neither a Version (legacy
  # Sprint column) nor an Agile::Sprint column. Filtered to the same type
  # set the backlogs columns use — `Story.types ∪ Task.type` — so the
  # Inbox mirrors what's draggable into a sprint/version column. Types not
  # configured as story or task (Epics in the default config, Bugs,
  # Features outside backlogs, etc.) intentionally drop out.
  #
  # By default closed-status work packages (Done / Closed / Rejected) are
  # excluded so the inbox stays focused on actionable items. Pass
  # `include_closed: true` to surface them too.
  def self.inbox_for(project_id, include_closed: false, limit: COLUMN_LIMIT)
    inbox_type_ids = inbox_type_ids()
    return [[], false] if inbox_type_ids.empty?

    # `preload` is used instead of `includes` so the closed-status filter
    # below (joins(:status).where(statuses: …)) does not silently upgrade
    # the eager-load strategy to a single multi-table JOIN that selects
    # every column from work_packages, statuses, and types. With preload
    # we get one focused main query plus two small id-lookup queries.
    scope = Story.where(project_id:, version_id: nil, sprint_id: nil, type_id: inbox_type_ids)
                 .preload(:status, :type)
    scope = scope.joins(:status).where(statuses: { is_closed: false }) unless include_closed

    candidates = scope.order(Arel.sql(Story::ORDER)).limit(limit + 1).to_a
    truncate_and_rank(candidates, limit)
  end

  def self.inbox_type_ids
    ids = Story.types.dup
    ids << Task.type if Task.type.to_i > 0
    ids.uniq
  end

  def self.at_rank(project_id, sprint_id, rank)
    Story.where(Story.condition(project_id, sprint_id))
         .joins(:status)
         .order(Arel.sql(Story::ORDER))
         .offset(rank - 1)
         .first
  end

  def self.types
    types = Setting.plugin_openproject_backlogs["story_types"]
    return [] if types.blank?

    types.map { |type| Integer(type) }
  end

  def tasks
    Task.tasks_for(id)
  end

  def tasks_and_subtasks
    return [] unless Task.type

    descendants.where(type_id: Task.type)
  end

  def direct_tasks_and_subtasks
    return [] unless Task.type

    children.where(type_id: Task.type).map { |t| [t] + t.descendants }.flatten
  end

  def set_points(p)
    init_journal(User.current)

    if p.blank? || p == "-"
      update_attribute(:story_points, nil)
      return
    end

    if p.downcase == "s"
      update_attribute(:story_points, 0)
      return
    end

    p = Integer(p)
    if p >= 0
      update_attribute(:story_points, p)
      nil
    end
  end

  # TODO: Refactor and add tests
  #
  # groups = tasks.partition(&:closed?)
  # {:open => tasks.last.size, :closed => tasks.first.size}
  #
  def task_status
    closed = 0
    open = 0

    tasks.each do |task|
      if task.closed?
        closed += 1
      else
        open += 1
      end
    end

    { open:, closed: }
  end

  def rank=(r)
    @rank = r
  end

  def rank
    if position.blank?
      extras = [
        "and ((#{WorkPackage.table_name}.position is NULL and #{WorkPackage.table_name}.id <= ?) or not #{WorkPackage.table_name}.position is NULL)", id
      ]
    else
      extras = ["and not #{WorkPackage.table_name}.position is NULL and #{WorkPackage.table_name}.position <= ?", position]
    end

    @rank ||= WorkPackage.where(Story.condition(project.id, version_id, extras))
              .joins(:status)
              .count
    @rank
  end

  def self.condition(project_id, sprint_ids, extras = [])
    # Backlog columns surface story-type work packages plus orphan tasks
    # (Task type with no parent). Tasks normally live on the Sprint Task
    # Board under a parent story; an orphan task has no story to live
    # under, so it is treated as a first-class column item.
    c = if Task.type
          ["project_id = ? AND " \
           "(type_id IN (?) OR (type_id = ? AND parent_id IS NULL)) AND " \
           "version_id IN (?)",
           project_id, Story.types, Task.type, sprint_ids]
        else
          ["project_id = ? AND type_id IN (?) AND version_id IN (?)",
           project_id, Story.types, sprint_ids]
        end

    if extras.size > 0
      c[0] += " " + extras.shift
      c += extras
    end

    c
  end

  # Sort stories by position with NULL positions last, breaking ties by id.
  # PostgreSQL's native `NULLS LAST` is equivalent to the older CASE WHEN
  # form and is more legible to the planner — opening the door to an
  # eventual `(project_id, version_id, position, id)` composite index that
  # could serve the sort directly.
  ORDER = "#{WorkPackage.table_name}.position ASC NULLS LAST, #{WorkPackage.table_name}.id ASC".freeze
end
