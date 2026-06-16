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

require "spec_helper"
require Rails.root.join("db/migrate/20260616120000_reverse_board_query_sort_to_newest_first.rb")

RSpec.describe ReverseBoardQuerySortToNewestFirst, type: :model do
  subject(:migrate!) { ActiveRecord::Migration.suppress_messages { described_class.migrate(:up) } }

  # A board column query still on the old default (manual_sorting ascending).
  let!(:board) { create(:board_grid_with_query) }
  let(:board_query) { board.contained_queries.first }

  # A board column a user re-sorted to something else.
  let(:custom_query) do
    build(:public_query, name: "Custom", project: board.project).tap do |q|
      q.sort_criteria = [[:priority, "desc"]]
      q.save!
    end
  end
  let!(:custom_board) { create(:board_grid_with_query, query: custom_query) }

  # A standalone (non-board) query that happens to be manually sorted.
  let!(:standalone_query) do
    build(:public_query, name: "Standalone", project: board.project).tap do |q|
      q.sort_criteria = [[:manual_sorting, "asc"]]
      q.save!
    end
  end

  it "flips board queries to newest-first, leaving custom and non-board queries untouched" do
    expect(board_query.sort_criteria).to eq([%w[manual_sorting asc]])

    migrate!

    expect(board_query.reload.sort_criteria).to eq([%w[manual_sorting desc], %w[id desc]])
    expect(custom_query.reload.sort_criteria).to eq([%w[priority desc]])
    expect(standalone_query.reload.sort_criteria).to eq([%w[manual_sorting asc]])
  end

  it "is reversible" do
    migrate!
    ActiveRecord::Migration.suppress_messages { described_class.migrate(:down) }

    expect(board_query.reload.sort_criteria).to eq([%w[manual_sorting asc], %w[id asc]])
  end
end
