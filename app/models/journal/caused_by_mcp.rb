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
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

# Marks a journal that an AI assistant wrote through the MCP server, rather than a person in the UI.
# The assistant acts as the token's user, so the journal's user alone cannot tell the two apart.
#
# An origin cause (see Journal::ORIGIN_CAUSE_TYPES): it records where a journal came from, describes
# no change of its own, is shown to the user, and is never the reason a journal exists.
class Journal::CausedByMcp < CauseOfChange::Base
  TYPE = "mcp"

  # The tools that write. Closed on purpose: the name is stored, and rendered through a translation key.
  TOOLS = %w[create_work_package update_work_package create_work_package_comment].freeze

  attr_reader :tool

  def initialize(tool:)
    @tool = tool.to_s

    unless TOOLS.include?(@tool)
      raise ArgumentError, "Unknown MCP tool #{tool.inspect}, expected one of #{TOOLS.join(', ')}"
    end

    super(TYPE, { "tool" => @tool })
  end
end
