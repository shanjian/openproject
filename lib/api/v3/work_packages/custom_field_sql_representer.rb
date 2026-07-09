# frozen_string_literal: true

#  OpenProject is an open source project management software.
#  Copyright (C) the OpenProject GmbH
#
#  This program is free software; you can redistribute it and/or
#  modify it under the terms of the GNU General Public License version 3.
#
#  OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
#  Copyright (C) 2006-2013 Jean-Philippe Lang
#  Copyright (C) 2010-2013 the ChiliProject Team
#
#  This program is free software; you can redistribute it and/or
#  modify it under the terms of the GNU General Public License
#  as published by the Free Software Foundation; either version 2
#  of the License, or (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
#  See COPYRIGHT and LICENSE files for more details.

module API
  module V3
    module WorkPackages
      # Adds work-package custom fields to the /work_packages `select` fast-path
      # (SQL representer). Custom fields are data-driven, so they are NOT static
      # `link`/`property` declarations: instead any `customFieldN` naming an
      # existing WorkPackageCustomField becomes selectable and its SQL is
      # generated on demand. They render ONLY when explicitly selected (never via
      # `*`), mirroring the object representer's JSON shape:
      #
      #   linked single (version/list/user, multi=false) -> _links.customFieldN = { href, title }
      #   linked multi                                    -> _links.customFieldN = [ { href, title }, ... ]
      #   primitive (string/int/float/bool/date)          -> customFieldN = <typed value>
      #
      # Two deliberate divergences from the object representer (see below), both
      # accepted because closing them is either impossible or disproportionate on
      # a SQL-only path:
      #   * text CFs render as the raw string, not a Formattable { format, raw,
      #     html } object -- `html` is the markdown pipeline, unreachable in SQL.
      #     See custom_field_primitive_cast.
      #   * every WorkPackageCustomField is selectable regardless of whether it is
      #     applicable to a given WP's project/type; a non-applicable field renders
      #     an empty value instead of being omitted. See work_package_custom_fields.
      #
      # Each selected CF adds a LEFT JOIN to a derived table that aggregates
      # custom_values, keyed on work_packages.id (like the version/epic joins), so
      # it works both when this representer is walked standalone and as the
      # elements of the collection representer.
      #
      # Include AFTER API::Decorators::Sql::Hal so the overrides below can `super`
      # into the base select machinery.
      module CustomFieldSqlRepresenter
        extend ActiveSupport::Concern

        CF_SELECT_PATTERN = /\AcustomField(\d+)\z/
        LINKED_FORMATS = %w[version list user].freeze
        TITLE_JOIN_TABLES = { "version" => "versions", "list" => "custom_options", "user" => "users" }.freeze

        class_methods do
          # Accept customFieldN for every work-package custom field on top of the
          # statically declared links/properties.
          def valid_selects
            super + work_package_custom_fields.keys.map { |id| :"customField#{id}" }
          end

          # Primitive custom fields render as top-level properties.
          def properties_sql(select, walker_results)
            merge_fragments(super, custom_field_fragments(select, linked: false))
          end

          # Linked custom fields render inside _links.
          def links_selects(select, walker_result)
            merge_fragments(super, custom_field_fragments(select, linked: true))
          end

          # One LEFT JOIN per selected custom field, aggregating its custom_values.
          def joins(select, scope)
            selected_custom_fields(select).reduce(super) do |acc, field|
              acc.joins(custom_field_join(field)).select(custom_field_join_select(field))
            end
          end

          private

          def merge_fragments(base, extra)
            [base.presence, extra.presence].compact.join(", ")
          end

          # { id => { format:, multi: } } for every work-package custom field.
          # Memoized per request (CFs change rarely; a new one is picked up on the
          # next request since RequestStore resets per request).
          #
          # ponytail: intentionally NOT filtered by project/type applicability.
          # Applicability is per-work-package (WorkPackage.available_custom_fields),
          # but this representer is one instance shared across the whole collection,
          # so a non-applicable CF just renders an empty value rather than being
          # omitted (an empty cell, not wrong data). Add a per-row applicability
          # join if a client ever needs the object representer's omit-the-key shape.
          def work_package_custom_fields
            RequestStore.fetch(:wp_sql_custom_fields) do
              WorkPackageCustomField
                .pluck(:id, :field_format, :multi_value)
                .to_h { |id, format, multi| [id, { format:, multi: }] }
            end
          end

          def selected_custom_fields(select)
            known = work_package_custom_fields
            cleaned_selects(select).filter_map do |name|
              id = name.to_s[CF_SELECT_PATTERN, 1]&.to_i
              known[id] && { id:, **known[id] }
            end
          end

          def custom_field_link?(field)
            LINKED_FORMATS.include?(field[:format])
          end

          # "'customFieldN', <value sql>" fragments, filtered to linked or primitive.
          def custom_field_fragments(select, linked:)
            selected_custom_fields(select)
              .select { |field| custom_field_link?(field) == linked }
              .map { |field| "'customField#{field[:id]}', #{custom_field_value_sql(field)}" }
              .join(", ")
          end

          def custom_field_value_sql(field)
            col = "cf_#{field[:id]}_value"
            if custom_field_link?(field)
              if field[:multi]
                "COALESCE(#{col}, '[]'::jsonb)"
              else
                %(COALESCE(#{col} -> 0, '{"href": null}'::jsonb))
              end
            else
              custom_field_primitive_cast(field, col)
            end
          end

          def custom_field_join(field)
            table = "cf_#{field[:id]}"
            <<~SQL.squish
              LEFT OUTER JOIN (#{custom_field_subquery(field)}) #{table}
              ON #{table}.customized_id = work_packages.id
            SQL
          end

          def custom_field_join_select(field)
            "cf_#{field[:id]}.value cf_#{field[:id]}_value"
          end

          # ponytail: aggregates all of the field's custom_values (indexed by
          # custom_field_id), not just the page's rows. Fine for typical CF
          # cardinality; switch to a LATERAL join keyed on the page if a field
          # ever holds enough values to matter.
          def custom_field_subquery(field)
            if custom_field_link?(field)
              <<~SQL.squish
                SELECT cv.customized_id,
                       jsonb_agg(#{custom_field_element_sql(field)} ORDER BY cv.id) AS value
                FROM custom_values cv
                #{custom_field_title_join(field)}
                WHERE cv.customized_type = 'WorkPackage'
                  AND cv.custom_field_id = #{field[:id]}
                  AND cv.value ~ '^[0-9]+$'
                GROUP BY cv.customized_id
              SQL
            else
              <<~SQL.squish
                SELECT cv.customized_id, MAX(cv.value) AS value
                FROM custom_values cv
                WHERE cv.customized_type = 'WorkPackage'
                  AND cv.custom_field_id = #{field[:id]}
                GROUP BY cv.customized_id
              SQL
            end
          end

          def custom_field_element_sql(field)
            case field[:format]
            when "version"
              %(jsonb_build_object('href', format('#{api_v3_paths.version('%s')}', cv.value), 'title', t.name))
            when "list"
              %(jsonb_build_object('href', format('#{api_v3_paths.custom_option('%s')}', cv.value), 'title', t.value))
            when "user"
              %(jsonb_build_object('href', format('#{api_v3_paths.user('%s')}', cv.value), 'title', #{user_title_sql('t')}))
            end
          end

          # LEFT JOIN so a value pointing at a deleted version/option/user is kept
          # (title NULL) rather than dropped from the aggregate. A dead target then
          # renders { href, title: null } instead of vanishing (multi) or looking
          # unset (single). Exact parity with the object representer for
          # version/user; for list it omits the object representer's localized
          # "<id> (not found)" title, which is the accepted trade for not dropping
          # the row.
          def custom_field_title_join(field)
            table = TITLE_JOIN_TABLES[field[:format]]
            "LEFT JOIN #{table} t ON t.id = cv.value::integer" if table
          end

          # Mirrors HalAssociatedResource's user-title logic (respects the
          # user_format setting) against the joined `t` alias.
          def user_title_sql(table)
            joiner = Setting.user_format == :lastname_comma_firstname ? " || ', ' || " : " || ' ' || "
            User::USER_FORMATS_STRUCTURE[Setting.user_format]
              .map { |column| "#{table}.#{column}" }
              .join(joiner)
          end

          def custom_field_primitive_cast(field, col)
            case field[:format]
            when "int"   then "NULLIF(#{col}, '')::bigint"
            when "float" then "NULLIF(#{col}, '')::float"
            when "date"  then "NULLIF(#{col}, '')::date"
            when "bool"
              "CASE WHEN #{col} IN ('1','t','true') THEN true " \
              "WHEN #{col} IN ('0','f','false') THEN false ELSE NULL END"
            # ponytail: text CFs fall through to raw string here. The object
            # representer wraps them in a Formattable { format, raw, html }, but
            # `html` is the rendered-markdown pipeline (format_text) which has no
            # SQL equivalent. Raw string is the closest honest degradation; the
            # only correct alternative is routing text CFs to the object path.
            else col # string / text / anything else -> raw text
            end
          end
        end
      end
    end
  end
end
