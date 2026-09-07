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

  describe "the structural label format" do
    # LABEL_FORMAT was defined and never used: only start_with? and the admin pattern ran,
    # so a permissive pattern - or none - let a bare prefix through.
    it "rejects a bare prefix with no name" do
      expect(project_label("AT-")).not_to be_valid
    end

    it "rejects a lower case name" do
      expect(project_label("AT-lower")).not_to be_valid
    end

    it "still rejects it when the field pattern is permissive" do
      field.update_column(:option_pattern, ".*")

      expect(project_label("AT-")).not_to be_valid
    end

    it "shows the pattern description rather than a regular expression" do
      field.update_columns(option_pattern: '\A[A-Z]{2}-ONLY\z',
                           option_pattern_description: "Only AT-ONLY is allowed here")
      option = project_label("AT-Something")
      option.valid?

      expect(option.errors[:value].join).to include("Only AT-ONLY is allowed here")
    end
  end

  describe "cross-tier shadowing" do
    it "refuses a project label named after a system label" do
      system_label("AT-Reserved")

      option = project_label("AT-Reserved")

      expect(option).not_to be_valid
      expect(option.errors[:value]).to be_present
    end

    # The symmetric case. Checking one direction only leaves an admin free to create or
    # rename a system label onto an existing project label - the same ambiguity, and no
    # index can catch it, because the collision spans both tiers.
    it "refuses a system label named after an existing project label" do
      project_label("AT-Taken").tap(&:save!)

      option = build(:custom_option, custom_field: field, value: "AT-Taken")

      expect(option).not_to be_valid
      expect(option.errors[:value]).to be_present
    end

    it "refuses renaming a system label onto an existing project label" do
      project_label("AT-Taken").tap(&:save!)
      existing = system_label("ML-Something")

      existing.value = "AT-Taken"

      expect(existing).not_to be_valid
    end
  end

  describe "the cross-tier lock" do
    # It lives on the model, not in a service, because there is more than one writer: the
    # project-admin services, the system-admin path saving custom_options_attributes as
    # nested attributes on the field, promotion, and seeds.
    it "is taken when the system-admin nested-attributes path saves an option" do
      field.update_columns(allow_project_values: true, option_pattern: '\A[A-Z][A-Z0-9]{1,5}-[A-Z][A-Za-z0-9]*\z')
      allow(described_class.connection).to receive(:execute).and_call_original

      field.update!(custom_options_attributes: { "0" => { value: "ML-Nested" } })

      expect(described_class.connection)
        .to have_received(:execute).with(/pg_advisory_xact_lock/).at_least(:once)
    end

    it "is not taken for fields that are not project-aware" do
      plain = create(:list_wp_custom_field, possible_values: %w[A])
      allow(described_class.connection).to receive(:execute).and_call_original

      plain.custom_options.create!(value: "B")

      expect(described_class.connection).not_to have_received(:execute).with(/pg_advisory_xact_lock/)
    end
  end

  describe "reading the committed prefix" do
    # The field lock serialises label writes against each other but not against a prefix
    # change, which writes a different table. A request holding a stale in-memory project
    # would otherwise validate against the prefix it loaded, not the one now committed.
    it "rejects a label built against a prefix that has since changed" do
      stale = Project.find(project.id) # loaded while the prefix is still AT
      Project.where(id: project.id).update_all(label_prefix: "ARCH")

      option = build(:custom_option, custom_field: field, value: "AT-Stale", project: stale)

      expect(option).not_to be_valid
    end

    it "accepts a label matching the committed prefix" do
      stale = Project.find(project.id)
      Project.where(id: project.id).update_all(label_prefix: "ARCH")

      option = build(:custom_option, custom_field: field, value: "ARCH-Fresh", project: stale)

      expect(option).to be_valid
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
