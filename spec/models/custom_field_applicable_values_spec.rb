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

RSpec.describe CustomField, "#applicable_values_options" do
  shared_let(:project) { create(:project, label_prefix: "AT") }
  shared_let(:other) { create(:project, label_prefix: "ADT") }

  context "with a project-aware list field" do
    shared_let(:field) do
      create(:list_wp_custom_field, name: "Labels", multi_value: true, possible_values: %w[ML-Shared])
    end

    before { field.update_column(:allow_project_values, true) }

    it "narrows to the project's own labels plus the system ones" do
      mine = create(:custom_option, custom_field: field, value: "AT-Local", project:)
      theirs = create(:custom_option, custom_field: field, value: "ADT-Local", project: other)

      values = field.reload.applicable_values_options(project).map(&:last)

      expect(values).to include(mine.id.to_s)
      expect(values).not_to include(theirs.id.to_s)
    end

    it "returns everything when no project can be deduced" do
      create(:custom_option, custom_field: field, value: "AT-Local", project:)

      expect(field.reload.applicable_values_options(nil).size).to eq field.custom_options.count
    end

    it "leaves possible_values_options global, because query filters read it" do
      create(:custom_option, custom_field: field, value: "ADT-Local", project: other)

      expect(field.reload.possible_values_options(project).size).to eq field.custom_options.count
    end
  end

  context "with a list field that is not project-aware" do
    shared_let(:field) { create(:list_wp_custom_field, possible_values: %w[A B]) }

    it "returns every option, exactly as before" do
      expect(field.applicable_values_options(project)).to eq field.possible_values_options(project)
    end
  end

  # user and version both register edit_as: "list", and options_for_list branches on
  # version? to build grouped options. A list-only implementation would break them.
  context "with formats that merely render as a list" do
    it "delegates for user fields" do
      field = create(:user_wp_custom_field)

      expect(field.applicable_values_options(project)).to eq field.possible_values_options(project)
    end

    it "delegates for version fields, options and all" do
      field = create(:version_wp_custom_field)

      expect(field.applicable_values_options(project, options: { scope: :visible }))
        .to eq field.possible_values_options(project, options: { scope: :visible })
    end
  end
end
