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

# app/views/roles/_permissions.html.erb renders `t(:"permission_#{permission.name}")` with no
# default for every registered permission, and app/views/projects/settings/modules/_form.html.erb
# renders `t(:"project_module_#{name}")` for every project module. A permission or module added
# without its label therefore breaks the whole page: it raises in test and development (where
# config.i18n.raise_on_missing_translations is on) and renders literal "translation missing" text
# in production. :import_work_packages shipped that way and took the admin New role page with it.
RSpec.describe OpenProject::AccessControl, "translations" do
  it "has a permission_<name> label for every registered permission" do
    missing = described_class.permissions
      .reject { |permission| I18n.exists?(:"permission_#{permission.name}") }
      .map(&:name)

    expect(missing).to be_empty,
                       "Missing en.yml keys: #{missing.map { |n| "permission_#{n}" }.join(', ')}"
  end

  it "has a project_module_<name> label for every project module" do
    missing = described_class.available_project_modules
      .reject { |name| I18n.exists?(:"project_module_#{name}") }

    expect(missing).to be_empty,
                       "Missing en.yml keys: #{missing.map { |n| "project_module_#{n}" }.join(', ')}"
  end
end
