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
# See COPYRIGHT and LICENSE files for more details.
#++

# Board columns load a single page capped at Setting.forced_single_page_size
# (default 250) and have no lazy loading, so cards beyond the cap are invisible.
# Manually-sorted board queries previously sorted oldest-first (manual_sorting's
# baked-in "work_packages.id" tiebreaker is ascending), which pushed the newest
# cards of unbounded columns (e.g. "Done") past the cap. Flipping the
# manual_sorting direction to desc reverses only that id tiebreaker (manual drag
# positions stay ascending), so the newest cards land inside the window.
#
# Only queries still on the old board default (manual_sorting ascending as the
# primary criterion) are touched; boards a user re-sorted to something else are
# left alone.
class ReverseBoardQuerySortToNewestFirst < ActiveRecord::Migration[8.1]
  NEW_SORT_CRITERIA = [["manual_sorting", "desc"], ["id", "desc"]].freeze

  def up
    each_board_query do |query|
      primary = query.sort_criteria.first
      next unless primary && primary.first.to_s == "manual_sorting" && primary.last.to_s != "desc"

      write_sort_criteria(query, NEW_SORT_CRITERIA)
    end
  end

  def down
    each_board_query do |query|
      next unless query.sort_criteria == NEW_SORT_CRITERIA

      write_sort_criteria(query, [["manual_sorting", "asc"], ["id", "asc"]])
    end
  end

  private

  def each_board_query(&)
    query_ids = Boards::Grid
                  .all
                  .flat_map { |grid| grid.widgets.filter_map { |w| w.options["queryId"] || w.options["query_id"] } }
                  .uniq

    Query.where(id: query_ids).find_each(&)
  end

  # Assign through the model so the serializer (and the setter's normalization)
  # runs, but skip validation: legacy board queries may carry unrelated
  # validation issues we don't want to block a pure sort-order rewrite on.
  def write_sort_criteria(query, criteria)
    query.sort_criteria = criteria
    query.save!(validate: false)
  end
end
