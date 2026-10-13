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

module WorkPackages
  module Shared
    # Saving a work package consumes its journal cause. When a service then saves the same work package
    # again (a pattern generated subject, rescheduling), that follow-up save would write a journal without
    # the cause. For an origin cause such as an MCP assistant's this hands it on, so the one call leaves
    # one marked journal. Other causes are left exactly as they were.
    module CarryOriginCause
      private

      def carry_origin_cause(work_package)
        cause = params[:journal_cause]

        work_package.journal_cause = cause if Journal.origin_cause?(cause)
      end

      # The cause is only meant for saves inside the service call. Do not leave it behind for the caller's
      # next, unrelated save of the same instance. Call it from an `ensure`: an exception, or a failed
      # validation, must not leave an assistant's cause on an object the caller may save later.
      def release_origin_cause(work_package)
        return unless work_package && Journal.origin_cause?(params[:journal_cause])

        work_package.journal_cause = nil
      end
    end
  end
end
