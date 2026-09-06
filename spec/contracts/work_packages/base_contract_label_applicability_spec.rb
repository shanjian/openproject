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

RSpec.describe WorkPackages::BaseContract, "label applicability" do
  shared_let(:user) { create(:admin) }
  shared_let(:status) { create(:default_status) }
  shared_let(:priority) { create(:default_priority) }
  shared_let(:field) do
    create(:list_wp_custom_field, name: "Labels", multi_value: true, is_for_all: true,
                                  possible_values: %w[ML-Shared])
  end
  shared_let(:project) { create(:project, label_prefix: "AT", types: [create(:type)]) }
  shared_let(:other) { create(:project, label_prefix: "ADT", types: [project.types.first]) }

  before do
    field.update_column(:allow_project_values, true)
    # a work package custom field only appears in available_custom_fields once it is on the
    # type, and the validation reads that list
    field.types << project.types.first unless field.types.include?(project.types.first)
  end

  let(:shared) { field.custom_options.system_level.first }
  let(:mine) { create(:custom_option, custom_field: field, value: "AT-Local", project:) }
  let(:theirs) { create(:custom_option, custom_field: field, value: "ADT-Local", project: other) }

  def create_wp(labels)
    WorkPackages::CreateService.new(user:).call(
      project:, type: project.types.first, subject: "s", status:, priority:,
      custom_field_values: { field.id => labels }
    )
  end

  it "accepts a system label" do
    expect(create_wp([shared.id.to_s])).to be_success
  end

  it "accepts the project's own label" do
    expect(create_wp([mine.id.to_s])).to be_success
  end

  it "refuses a label owned by another project" do
    call = create_wp([theirs.id.to_s])

    expect(call).not_to be_success
    expect(call.errors.full_messages.join).to match(/cannot use/)
  end

  describe "retention" do
    # a work package that moved projects still carries a label the project cannot apply
    let(:moved) do
      wp = create(:work_package, project: other, type: project.types.first, status:, priority:)
      CustomValue.create!(customized: wp, custom_field: field, value: theirs.id.to_s)
      wp.update_column(:project_id, project.id)
      wp.reload
    end

    it "allows an unrelated edit without dropping the retained label" do
      call = WorkPackages::UpdateService.new(user:, model: moved).call(subject: "renamed")

      expect(call).to be_success
      expect(moved.reload.subject).to eq "renamed"
      expect(CustomValue.where(customized: moved, custom_field: field, value: theirs.id.to_s)).to exist
    end

    it "validates only the value being added, not the one already stored" do
      call = WorkPackages::UpdateService.new(user:, model: moved)
                                        .call(custom_field_values: { field.id => [theirs.id.to_s, mine.id.to_s] })

      expect(call).to be_success
    end

    it "still refuses a newly added inapplicable label on the same work package" do
      third = create(:custom_option, custom_field: field, value: "ADT-Another", project: other)

      call = WorkPackages::UpdateService.new(user:, model: moved)
                                        .call(custom_field_values: { field.id => [theirs.id.to_s, third.id.to_s] })

      expect(call).not_to be_success
    end
  end

  it "does not constrain a field that is not project-aware" do
    field.update_column(:allow_project_values, false)

    expect(create_wp([theirs.id.to_s])).to be_success
  end
end
