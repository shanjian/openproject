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

class AddRecurrenceOptionsToRecurringMeetings < ActiveRecord::Migration[8.0]
  def up
    change_table :recurring_meetings, bulk: true do |t|
      t.integer :weekdays, array: true, default: [], null: false
      t.integer :schedule_mode, default: 0, null: false
      t.integer :month_day, null: true
      t.integer :week_ordinal, null: true
    end

    # Existing weekly series recur on their start date's weekday. Make that explicit so
    # the weekly rule can always be built from the weekdays column.
    # frequency = 2 is "weekly"; ISODOW matches our 1 = Monday .. 7 = Sunday convention.
    # start_time is stored as UTC; the weekday must be taken in the series' own zone
    # (a series starting Friday 01:00 AEST is still Thursday in UTC).
    execute <<~SQL.squish
      UPDATE recurring_meetings
      SET weekdays = ARRAY[
        EXTRACT(ISODOW FROM (start_time AT TIME ZONE 'UTC') AT TIME ZONE time_zone)::integer
      ]
      WHERE frequency = 2 AND start_time IS NOT NULL
    SQL
  end

  def down
    change_table :recurring_meetings, bulk: true do |t|
      t.remove :weekdays
      t.remove :schedule_mode
      t.remove :month_day
      t.remove :week_ordinal
    end
  end
end
