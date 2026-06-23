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

namespace :work_packages do
  desc "Copy a date custom field's values into the built-in start_date " \
       "(fill-only-when-blank, direct write). " \
       "Usage: rake \"work_packages:migrate_custom_start_date[CUSTOM_FIELD_ID]\" (dry run); " \
       "prepend APPLY=1 to write."
  task :migrate_custom_start_date, [:custom_field_id] => :environment do |_task, args|
    custom_field_id = args[:custom_field_id].presence || ENV["CUSTOM_FIELD_ID"].presence
    if custom_field_id.blank?
      abort 'Provide the custom field id, e.g. rake "work_packages:migrate_custom_start_date[42]"'
    end

    custom_field = WorkPackageCustomField.find_by(id: custom_field_id)
    abort "No work package custom field with id=#{custom_field_id}" if custom_field.nil?

    apply = ENV["APPLY"] == "1"

    report = WorkPackages::MigrateCustomStartDateService.new(custom_field:, apply:).call
    puts report

    puts "\nDry run only. Re-run with APPLY=1 to write changes." unless apply
  end
end
