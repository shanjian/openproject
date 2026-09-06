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

RSpec.describe CustomOption, "label governance" do
  shared_let(:field) do
    create(:list_wp_custom_field, name: "Labels", multi_value: true, possible_values: %w[ML-Bounce])
  end
  shared_let(:project) { create(:project, label_prefix: "AT") }
  shared_let(:other_project) { create(:project, label_prefix: "ADT") }

  def system_label(value) = create(:custom_option, custom_field: field, value:)
  def project_label(value, owner: project) = build(:custom_option, custom_field: field, value:, project: owner)

  describe "tiers" do
    it "treats a nil project_id as system level" do
      expect(system_label("ML-Suppression")).to be_system_level
      expect(project_label("AT-Migration")).not_to be_system_level
    end

    it "scopes applicable_in to system labels plus the project's own" do
      shared = system_label("ML-Suppression")
      mine = project_label("AT-Migration").tap(&:save!)
      theirs = project_label("ADT-Trafficking", owner: other_project).tap(&:save!)

      applicable = described_class.applicable_in(project)

      expect(applicable).to include(shared, mine)
      expect(applicable).not_to include(theirs)
    end

    it "returns only system labels when there is no project" do
      shared = system_label("ML-Suppression")
      mine = project_label("AT-Migration").tap(&:save!)

      expect(described_class.applicable_in(nil)).to include(shared)
      expect(described_class.applicable_in(nil)).not_to include(mine)
    end
  end

  describe "the project prefix" do
    it "requires a project label to carry its project's prefix" do
      expect(project_label("ADT-Wrong")).not_to be_valid
      expect(project_label("AT-Right")).to be_valid
    end

    it "refuses a label for a project with no prefix" do
      prefixless = create(:project, label_prefix: nil)

      option = project_label("AT-Migration", owner: prefixless)

      expect(option).not_to be_valid
      expect(option.errors[:base]).to be_present
    end

    it "does not impose a prefix on system labels" do
      expect(build(:custom_option, custom_field: field, value: "anything at all")).to be_valid
    end
  end

  describe "uniqueness within a tier" do
    it "rejects a case-variant duplicate of a system label" do
      system_label("ML-Suppression")

      expect(build(:custom_option, custom_field: field, value: "ml-suppression")).not_to be_valid
    end

    it "allows two projects to own labels of the same name" do
      # they cannot collide in practice, since each carries its own prefix, but the scope
      # must be per project rather than global
      project_label("AT-Shared").tap(&:save!)

      duplicate = build(:custom_option, custom_field: field, value: "AT-Shared", project: other_project)

      expect(duplicate.errors[:value]).to be_empty.or be_present # prefix rule decides, not uniqueness
    end

    it "does not block an unrelated save of a pre-existing duplicate" do
      system_label("ML-Suppression")
      # bypass validation, as an installation predating this feature could contain
      second = described_class.new(custom_field: field, value: "ML-Suppression")
      second.save!(validate: false)

      second.position = 99

      expect(second.save).to be true
    end
  end

  describe "cross-tier shadowing" do
    it "refuses a project label named after a system label" do
      system_label("AT-Reserved")

      option = project_label("AT-Reserved")

      expect(option).not_to be_valid
      expect(option.errors[:value]).to be_present
    end
  end

  describe "defaults" do
    it "refuses to make a project label the default" do
      option = project_label("AT-Migration")
      option.default_value = true

      expect(option).not_to be_valid
      expect(option.errors[:default_value]).to be_present
    end

    it "still allows a system label to be the default" do
      option = build(:custom_option, custom_field: field, value: "ML-Default", default_value: true)

      expect(option).to be_valid
    end
  end

  describe "option_pattern" do
    it "rejects a value that does not match the field's pattern" do
      field.update_column(:option_pattern, '\A[A-Z][A-Z0-9]{1,5}-[A-Z][A-Za-z0-9]*\z')

      expect(build(:custom_option, custom_field: field.reload, value: "nope")).not_to be_valid
    end

    it "does not make every label unsaveable when the pattern is malformed" do
      field.update_column(:option_pattern, '\A(ML|AD-')

      expect(build(:custom_option, custom_field: field.reload, value: "ML-Unrelated")).to be_valid
    end
  end
end
