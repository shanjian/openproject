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

RSpec.describe WorkPackages::CopyService, "label filtering" do
  shared_let(:user) { create(:admin) }
  shared_let(:status) { create(:default_status) }
  shared_let(:priority) { create(:default_priority) }
  shared_let(:type) { create(:type) }
  shared_let(:field) do
    create(:list_wp_custom_field, name: "Labels", multi_value: true, is_for_all: true,
                                  possible_values: %w[ML-Shared])
  end
  shared_let(:source) { create(:project, label_prefix: "AT", types: [type]) }
  shared_let(:target) { create(:project, label_prefix: "ADT", types: [type]) }

  before do
    field.update_column(:allow_project_values, true)
    field.types << type unless field.types.include?(type)
  end

  let(:shared) { field.custom_options.system_level.first }
  let(:owned) { create(:custom_option, custom_field: field, value: "AT-Local", project: source) }

  def labelled_work_package(*options)
    wp = create(:work_package, project: source, type:, status:, priority:)
    options.each { |o| CustomValue.create!(customized: wp, custom_field: field, value: o.id.to_s) }
    wp.reload
  end

  def labels_on(work_package)
    CustomValue.where(customized: work_package, custom_field: field).pluck(:value)
  end

  describe "work package copy" do
    it "drops a source-owned label when copying to another project" do
      wp = labelled_work_package(shared, owned)

      copy = described_class.new(user:, work_package: wp).call(project: target).result

      expect(labels_on(copy)).to include(shared.id.to_s)
      expect(labels_on(copy)).not_to include(owned.id.to_s)
    end

    it "resolves the target from project_id as well as project" do
      wp = labelled_work_package(owned)

      copy = described_class.new(user:, work_package: wp).call(project_id: target.id).result

      expect(labels_on(copy)).not_to include(owned.id.to_s)
    end

    it "keeps labels on a copy within the same project" do
      wp = labelled_work_package(owned)

      copy = described_class.new(user:, work_package: wp).call.result

      expect(labels_on(copy)).to include(owned.id.to_s)
    end

    it "leaves an unrelated field whose value equals an option id alone" do
      integer_field = create(:integer_wp_custom_field, name: "Estimate", is_for_all: true)
      integer_field.types << type
      wp = labelled_work_package(owned)
      CustomValue.create!(customized: wp, custom_field: integer_field, value: owned.id.to_s)

      copy = described_class.new(user:, work_package: wp.reload).call(project: target).result

      expect(CustomValue.where(customized: copy, custom_field: integer_field).pluck(:value))
        .to eq [owned.id.to_s]
    end
  end

  # CopyProjectContract#valid? returns true unconditionally, so the filter is the ONLY
  # protection here. And the dependent service supplies its own custom_field_values override,
  # which wins the merge in CopyService#copied_attributes - filtering there alone would never
  # run on this path.
  describe "project copy" do
    it "drops a source-owned label, and starts the copy without a prefix" do
      labelled_work_package(shared, owned)

      copied = Projects::CopyService.new(user:, source:)
                                    .call(target_project_params: { name: "Copy", identifier: "copy" },
                                          only: %w[work_packages]).result
      copy = copied.work_packages.first

      expect(labels_on(copy)).to include(shared.id.to_s)
      expect(labels_on(copy)).not_to include(owned.id.to_s)
      # label_prefix is unique, so a copy that inherited it would collide
      expect(copied.label_prefix).to be_nil
    end
  end
end
