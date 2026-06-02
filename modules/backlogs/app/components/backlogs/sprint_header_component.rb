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
  class SprintHeaderComponent < ApplicationComponent
    include OpPrimer::ComponentHelpers
    include OpTurbo::Streamable
    include Primer::FetchOrFallbackHelper
    include Redmine::I18n
    include RbCommonHelper

    attr_reader :sprint, :collapsed, :current_user, :include_closed

    delegate :project, to: :sprint
    delegate :name, to: :sprint, prefix: :sprint

    def initialize(
      sprint:,
      folded: false,
      include_closed: false,
      current_user: User.current
    )
      super()

      @sprint = sprint
      @collapsed = folded
      @include_closed = include_closed
      @current_user = current_user
    end

    def wrapper_uniq_by
      sprint.id
    end

    def stories
      @stories ||= sprint.board_work_packages(include_closed:).to_a
    end

    private

    def story_points
      @story_points ||= stories.sum { |story| story.story_points || 0 }
    end

    def story_count
      @story_count ||= stories.size
    end

    def date_range
      [sprint.start_date, sprint.finish_date]
    end
  end
end
