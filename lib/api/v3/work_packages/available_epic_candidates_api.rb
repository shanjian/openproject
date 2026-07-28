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
    module WorkPackages
      # Provides epic candidates for the work package *create* form, where no
      # persisted work package (and thus no id) exists yet. The persisted case is
      # served by AvailableRelationCandidatesAPI (type: :epic). Candidates are
      # simply the visible Epic-target-type work packages, optionally narrowed by
      # a typeahead query. Cross-project links are allowed, so the collection is
      # not scoped to a single project.
      class AvailableEpicCandidatesAPI < ::API::OpenProjectAPI
        helpers do
          def combined_params
            params
              .merge({ filters: filters_param }.with_indifferent_access)
          end

          def filters_param
            JSON::parse(params[:filters] || "[]")
              .concat([string_filter].compact)
          end

          def string_filter
            return unless params.key?(:query)

            { typeahead: { operator: "**", values: params[:query] } }.with_indifferent_access
          end

          # Base scope restricting candidates to Epic-target-type work packages.
          # Passed as the service's scope (intersected by id with the query
          # results), so when no epic types exist it cleanly yields an empty
          # collection rather than an invalid (blank type) filter.
          def epic_candidate_scope
            WorkPackage.where(type_id: epic_type_ids)
          end

          def epic_type_ids
            ::Type.where("LOWER(name) IN (?)", WorkPackage::EPIC_TARGET_TYPE_NAMES).select(:id)
          end
        end

        resource :available_epic_candidates do
          after_validation do
            authorize_in_any_project(:add_work_packages)
          end

          params do
            optional :query, type: String # part of the WP ID and/or part of its subject and/or part of the projects name
            optional :pageSize, type: Integer, default: 10
          end

          get do
            call = raise_invalid_query_on_service_failure do
              WorkPackageCollectionFromQueryParamsService
                        .new(current_user, scope: epic_candidate_scope)
                        .call(combined_params)
            end

            call.result
          end
        end
      end
    end
  end
end
