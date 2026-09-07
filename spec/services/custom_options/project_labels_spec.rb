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

RSpec.describe CustomOptions::ProjectLabels::CreateService do
  shared_let(:field) do
    create(:list_wp_custom_field, name: "Labels", multi_value: true, possible_values: %w[ML-Shared])
  end
  shared_let(:project) { create(:project, label_prefix: "AT") }
  shared_let(:other) { create(:project, label_prefix: "ADT") }
  shared_let(:role) { create(:project_role, permissions: %i[manage_project_labels]) }
  shared_let(:manager) { create(:user, member_with_roles: { project => role }) }
  shared_let(:outsider) { create(:user) }

  before { field.update_columns(allow_project_values: true, option_pattern: '\A[A-Z][A-Z0-9]{1,5}-[A-Za-z0-9]+([-_][A-Za-z0-9]+)*\z') }

  def create_label(value, user: manager, in_project: project)
    described_class.new(user:, project: in_project, custom_field: field).call(value:)
  end

  describe "creating" do
    it "creates a label carrying the project's prefix" do
      call = create_label("AT-Bounce")

      expect(call).to be_success
      expect(call.result.project).to eq project
    end

    it "refuses a value that does not carry the prefix" do
      expect(create_label("ADT-Bounce")).not_to be_success
    end

    it "refuses a user without the permission" do
      expect(create_label("AT-Bounce", user: outsider)).not_to be_success
    end

    it "refuses a field that does not accept project values" do
      field.update_column(:allow_project_values, false)

      expect(create_label("AT-Bounce")).not_to be_success
    end

    it "refuses a project with no prefix" do
      prefixless = create(:project, label_prefix: nil)
      create(:member, project: prefixless, user: manager, roles: [role])

      expect(create_label("AT-Bounce", in_project: prefixless)).not_to be_success
    end
  end

  describe CustomOptions::ProjectLabels::UpdateService do
    let(:option) { create(:custom_option, custom_field: field, value: "AT-Bounce", project:) }

    it "renames a label the project owns" do
      call = described_class.new(user: manager, project:, custom_field: field).call(option:, value: "AT-Renamed")

      expect(call).to be_success
      expect(option.reload.value).to eq "AT-Renamed"
    end

    it "refuses to touch a system label" do
      system_label = field.custom_options.system_level.first

      call = described_class.new(user: manager, project:, custom_field: field)
                            .call(option: system_label, value: "AT-Hijacked")

      expect(call).not_to be_success
      expect(system_label.reload.value).to eq "ML-Shared"
    end

    it "refuses to touch another project's label" do
      theirs = create(:custom_option, custom_field: field, value: "ADT-Theirs", project: other)

      call = described_class.new(user: manager, project:, custom_field: field).call(option: theirs, value: "AT-Mine")

      expect(call).not_to be_success
    end
  end

  describe CustomOptions::ProjectLabels::DeleteService do
    it "removes the label and its stored values together" do
      option = create(:custom_option, custom_field: field, value: "AT-Gone", project:)
      wp = create(:work_package, project:)
      CustomValue.create!(customized: wp, custom_field: field, value: option.id.to_s)

      call = described_class.new(user: manager, project:, custom_field: field).call(option:)

      expect(call).to be_success
      expect(CustomOption.where(id: option.id)).to be_empty
      expect(CustomValue.where(custom_field: field, value: option.id.to_s)).to be_empty
    end

    it "refuses to delete a system label" do
      system_label = field.custom_options.system_level.first

      call = described_class.new(user: manager, project:, custom_field: field).call(option: system_label)

      expect(call).not_to be_success
      expect(CustomOption.where(id: system_label.id)).to exist
    end
  end
end
