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

RSpec.describe CustomField, "project value settings" do
  subject(:field) { create(:list_wp_custom_field, possible_values: %w[A]) }

  it "refuses to allow project values without a naming pattern" do
    field.allow_project_values = true

    expect(field).not_to be_valid
    expect(field.errors[:allow_project_values]).to be_present
  end

  it "allows project values once a pattern is set" do
    field.option_pattern = '\A[A-Z][A-Z0-9]{1,5}-[A-Z][A-Za-z0-9]*\z'
    field.allow_project_values = true

    expect(field).to be_valid
  end

  # An unbalanced bracket saved here would otherwise raise RegexpError later, at label
  # creation, in a different screen.
  it "rejects a malformed pattern where it is entered" do
    field.option_pattern = '\A(ML|AD-'

    expect(field).not_to be_valid
    expect(field.errors[:option_pattern]).to be_present
  end

  it "leaves the pattern optional when project values are off" do
    expect(field).to be_valid
  end
end
