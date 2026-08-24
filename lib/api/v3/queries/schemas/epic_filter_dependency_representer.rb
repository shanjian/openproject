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

module API
  module V3
    module Queries
      module Schemas
        class EpicFilterDependencyRepresenter < ByWorkPackageFilterDependencyRepresenter
          # Epic links may live in a different project than the work package
          # linking to them (see docs/development/epic-link-implementation-tasks.md),
          # so the value picker has to offer epics from every visible project —
          # not only the current one. Override the project-scoped href callback
          # from the parent class to always use the cross-project endpoint.
          #
          # The endpoint is the generic work packages one, so constrain it to the
          # epic types: without that the picker offers every visible work package
          # and a plain task can be selected as though it were an epic, which the
          # filter then rejects as an invalid value.
          def href_callback
            params = [{ type: { operator: "=", values: epic_type_ids } }]
            escaped = CGI.escape(::JSON.dump(params))

            "#{api_v3_paths.work_packages}?filters=#{escaped}"
          end

          # The href embeds the epic type ids, so a type renamed into or out of the
          # epic names has to invalidate the cached schema along with it.
          def json_cache_key
            super + epic_type_ids
          end

          private

          def epic_type_ids
            WorkPackage.epic_target_types.pluck(:id).map(&:to_s)
          end
        end
      end
    end
  end
end
