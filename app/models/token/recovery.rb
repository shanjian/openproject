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

module Token
  class Recovery < Base
    include ExpirableToken

    CHANNEL_CHAT_LINK = "chat_link"
    EMAIL_VALIDITY = 3.days
    CHAT_LINK_VALIDITY = 1.day

    def self.validity_time
      EMAIL_VALIDITY
    end

    def validity_time
      # `data` is nil for a new record until an explicit `data:` value is assigned
      # (Rails does not run a serialized column's coder over its unset default),
      # so `&.dig` is required here, not just for readability.
      data&.dig("channel") == CHANNEL_CHAT_LINK ? CHAT_LINK_VALIDITY : self.class.validity_time
    end
  end
end
