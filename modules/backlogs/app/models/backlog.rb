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

class Backlog
  extend ActiveModel::Naming

  attr_accessor :sprint, :stories
  attr_reader :include_closed

  delegate :id, to: :sprint, prefix: true

  # +include_closed+ defaults to the per-column user preference (resolved
  # from the column's list type and id) when not given explicitly. Callers
  # that already know the desired value — e.g. the toggle endpoint — pass it
  # in to avoid a redundant preference read.
  def self.for(sprint:, project:, user: User.current, include_closed: nil)
    owner_backlog = sprint.settings(project)&.display == VersionSetting::DISPLAY_RIGHT
    list_type = owner_backlog ? :backlog : :sprint
    include_closed = user.backlogs_include_closed?(list_type, sprint.id) if include_closed.nil?
    stories, truncated = Story.backlog_for(project.id, sprint.id, include_closed:)
    new(sprint:, stories:, owner_backlog:, truncated:, include_closed:)
  end

  def self.owner_backlogs(project, user: User.current)
    # Loop one bounded query per backlog instead of a single unbounded query
    # across all of them. For typical projects (low single digits of backlog
    # columns) the additional round trips are cheap and the LIMIT keeps any
    # one column from dominating page-render time.
    backlogs = Sprint.apply_to(project).with_status_open.displayed_right(project).order(:name)
    backlogs.map do |sprint|
      include_closed = user.backlogs_include_closed?(:backlog, sprint.id)
      stories, truncated = Story.backlog_for(project.id, sprint.id, include_closed:)
      new(stories:, owner_backlog: true, sprint:, truncated:, include_closed:)
    end
  end

  def self.sprint_backlogs(project, user: User.current)
    sprints = Sprint.apply_to(project).with_status_open.displayed_left(project).order_by_date
    sprints.map do |sprint|
      include_closed = user.backlogs_include_closed?(:sprint, sprint.id)
      stories, truncated = Story.backlog_for(project.id, sprint.id, include_closed:)
      new(stories:, sprint:, truncated:, include_closed:)
    end
  end

  def self.inbox_backlog(project, include_closed: false)
    stories, truncated = Story.inbox_for(project.id, include_closed:)
    new(sprint: nil, stories:, inbox: true, truncated:, include_closed:)
  end

  def initialize(sprint:, stories:, owner_backlog: false, inbox: false, truncated: false, include_closed: false)
    @sprint = sprint
    @stories = stories
    @owner_backlog = owner_backlog
    @inbox = inbox
    @truncated = truncated
    @include_closed = include_closed
  end

  def updated_at
    @stories.max_by(&:updated_at).try(:updated_at)
  end

  def owner_backlog?
    !!@owner_backlog
  end

  def sprint_backlog?
    !owner_backlog? && !inbox?
  end

  def inbox?
    !!@inbox
  end

  # The list-type key used for the per-column include-closed preference.
  def list_type
    if inbox?
      :inbox
    elsif owner_backlog?
      :backlog
    else
      :sprint
    end
  end

  def truncated?
    !!@truncated
  end

  def column_limit
    Story::COLUMN_LIMIT
  end

  def to_key
    [inbox? ? "inbox" : sprint_id]
  end
end
