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
        class VersionFilterDependencyRepresenter <
          FilterDependencyRepresenter
          def json_cache_key
            super + (filter.project.present? ? [filter.project.id] : [])
          end

          def href_callback
            base = filter.project.nil? ? api_v3_paths.versions : api_v3_paths.versions_by_workspace(filter.project.id)

            "#{base}?#{query_params}"
          end

          def type
            "[]Version"
          end

          private

          def query_params
            [kind_filter_param, "sortBy=#{to_query [%i(name desc)]}", "pageSize=-1"].compact.join("&")
          end

          # Offer only the versions of the kind this filter targets:
          # - the native version_id filter is the Sprint selection set => "sprint";
          # - a version custom field filter (e.g. Release) uses its configured version_kind;
          # - a version custom field with no kind offers all versions (no kind filter).
          def kind_filter_param
            kind = filtered_version_kind
            return if kind.blank?

            "filters=#{to_query([{ kind: { operator: '=', values: [kind] } }])}"
          end

          def filtered_version_kind
            if filter.is_a?(::Queries::Filters::Shared::CustomFields::Base)
              filter.custom_field.version_kind
            else
              "sprint"
            end
          end

          def to_query(param)
            CGI.escape(::JSON.dump(param))
          end
        end
      end
    end
  end
end
