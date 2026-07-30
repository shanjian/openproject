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
# Copyright (C) the OpenProject GmbH
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
# See docs/COPYRIGHT.rdoc for more details.
#++

# Marks a journal the GitLab integration created in response to a webhook,
# rather than one a person wrote in OpenProject. The mark is what lets the
# activity tab keep integration chatter out of the comments-only view (see
# Journal::INTEGRATION_CAUSE_TYPES); it renders nothing itself.
class Journal::CausedByGitlabEvent < CauseOfChange::Base
  TYPE = "gitlab_event"

  # The event families that can post a comment. Each one is separately
  # switchable per project -- see Project#gitlab_comments_on?.
  EVENTS = %i[push merge_request note issue].freeze

  attr_reader :event

  def initialize(event:)
    @event = event.to_sym

    unless EVENTS.include?(@event)
      raise ArgumentError, "Unknown GitLab event #{event.inspect}, expected one of #{EVENTS.join(', ')}"
    end

    super(TYPE, { "event" => @event.to_s })
  end
end
