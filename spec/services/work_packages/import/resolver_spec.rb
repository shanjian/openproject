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

RSpec.describe WorkPackages::Import::Resolver do
  subject(:resolver) { described_class.new(project: build_stubbed(:project), user: build_stubbed(:user)) }

  def document(markdown)
    WorkPackages::Import::OutlineParser.call(markdown).result
  end

  describe "#resolve_date" do
    it "parses an ISO date" do
      expect(resolver.send(:resolve_date, "2026-09-30")).to eq(Date.new(2026, 9, 30))
    end

    it "rejects a non-ISO date" do
      expect { resolver.send(:resolve_date, "09/30/2026") }
        .to raise_error(described_class::AttributeError, /not a valid ISO date/)
    end
  end

  describe "#convert_custom_value for numeric formats" do
    let(:custom_field) { build_stubbed(:custom_field, field_format: "int") }
    let(:float_field) { build_stubbed(:custom_field, field_format: "float") }

    it "parses a plain integer" do
      expect(resolver.send(:convert_custom_value, custom_field, "42")).to eq(42)
    end

    it "tolerates a trailing percent sign" do
      expect(resolver.send(:convert_custom_value, custom_field, "80%")).to eq(80)
    end

    it "parses a float" do
      expect(resolver.send(:convert_custom_value, float_field, "0.8")).to eq(0.8)
    end

    it "raises AttributeError on garbage input" do
      expect { resolver.send(:convert_custom_value, custom_field, "not a number") }
        .to raise_error(described_class::AttributeError, /not a valid int/)
    end
  end

  describe "#convert_custom_value for bool" do
    let(:bool_field) { build_stubbed(:custom_field, field_format: "bool") }

    it "accepts yes/true as truthy" do
      expect(resolver.send(:convert_custom_value, bool_field, "yes")).to be true
      expect(resolver.send(:convert_custom_value, bool_field, "True")).to be true
    end

    it "accepts no/false as falsy" do
      expect(resolver.send(:convert_custom_value, bool_field, "no")).to be false
      expect(resolver.send(:convert_custom_value, bool_field, "False")).to be false
    end

    it "raises AttributeError for anything outside yes/no/true/false" do
      expect { resolver.send(:convert_custom_value, bool_field, "maybe") }
        .to raise_error(described_class::AttributeError, /"maybe" is not a valid bool value/)
    end
  end

  describe "#convert_custom_value for version" do
    let(:resolver) { described_class.new(project:, user: build_stubbed(:user)) }
    let(:project) { create(:project) }
    let!(:version) { create(:version, project:, name: "FY2026 Q3") }
    let(:version_field) { build_stubbed(:custom_field, field_format: "version") }

    it "resolves a version name to the real Version record" do
      # convert_custom_value returns the resolved record itself for reference-type formats
      # (matching the "list" branch's CustomOption return) -- resolve_custom_field_attribute's
      # caller is what converts an ActiveRecord::Base result to its stored `.id.to_s`.
      expect(resolver.send(:convert_custom_value, version_field, "FY2026 Q3")).to eq(version)
    end

    it "raises AttributeError for an unknown version name" do
      expect { resolver.send(:convert_custom_value, version_field, "FY2099 Q1") }
        .to raise_error(described_class::AttributeError, /no version named/)
    end
  end

  describe "#convert_custom_value for hierarchy", with_ee: [:custom_field_hierarchies] do
    let(:resolver) { described_class.new(project: build_stubbed(:project), user: build_stubbed(:user)) }
    let(:hierarchy_field) { create(:hierarchy_wp_custom_field) }
    let!(:marketing) { hierarchy_field.hierarchy_root.children.create!(label: "Marketing") }
    let!(:retention) { marketing.children.create!(label: "Retention") }

    it "resolves a full ancestry path to the real hierarchy item" do
      expect(resolver.send(:resolve_hierarchy_value, hierarchy_field, "Marketing / Retention")).to eq(retention)
    end

    it "raises AttributeError for an unknown path" do
      expect { resolver.send(:resolve_hierarchy_value, hierarchy_field, "Sales / Enablement") }
        .to raise_error(described_class::AttributeError, /no hierarchy value at path/)
    end
  end

  describe "#convert_custom_value for string/text" do
    let(:string_field) { build_stubbed(:custom_field, field_format: "string") }

    it "passes the value through verbatim" do
      expect(resolver.send(:convert_custom_value, string_field, "Rework the sequence")).to eq("Rework the sequence")
    end
  end

  describe "#resolve_user" do
    let!(:jane) { create(:user, mail: "jane.doe@example.com", firstname: "Jane", lastname: "Doe") }
    let!(:sam) { create(:user, mail: "sam.lee@example.com", firstname: "Sam", lastname: "Lee") }

    before { resolver.instance_variable_set(:@user_lookup, resolver.send(:build_user_lookup)) }

    it "resolves by email" do
      expect(resolver.send(:resolve_user, "jane.doe@example.com")).to eq(jane)
    end

    it "resolves by unambiguous display name" do
      expect(resolver.send(:resolve_user, jane.name)).to eq(jane)
    end

    it "raises on an unknown email" do
      expect { resolver.send(:resolve_user, "nobody@example.com") }
        .to raise_error(described_class::AttributeError, /no user found with email/)
    end

    context "with two users sharing a display name" do
      let!(:other_jane) { create(:user, mail: "jane.doe2@example.com", firstname: "Jane", lastname: "Doe") }

      # Re-run after other_jane exists: the outer `before` (a hook declared in an
      # enclosing context) always fires before this context's own `let!(:other_jane)`
      # hook, so without rebuilding here the lookup would be built too early and miss her.
      before { resolver.instance_variable_set(:@user_lookup, resolver.send(:build_user_lookup)) }

      it "raises ambiguity, not a silent guess" do
        expect { resolver.send(:resolve_user, jane.name) }
          .to raise_error(described_class::AttributeError, /matches more than one user/)
      end
    end
  end

  describe "#resolve_department" do
    let!(:marketing) { create(:group, lastname: "Marketing", organizational_unit: true) }
    let!(:retention) { create(:group, lastname: "Retention", parent: marketing, organizational_unit: true) }
    let!(:security_group) { create(:group, lastname: "Retention", organizational_unit: false) }

    before { resolver.instance_variable_set(:@department_lookup, resolver.send(:build_department_lookup)) }

    it "resolves a full ancestry path" do
      expect(resolver.send(:resolve_department, "Marketing / Retention")).to eq(retention)
    end

    it "resolves an unambiguous leaf name" do
      expect(resolver.send(:resolve_department, "Marketing")).to eq(marketing)
    end

    it "never matches a same-named regular security group" do
      # "Retention" as a bare leaf name is ambiguous between the org unit and the
      # regular group only if both are considered — assert only the org unit counts.
      expect(resolver.send(:build_department_lookup)[:by_leaf_name]["Retention"]).to eq([retention])
    end

    it "raises on an unknown path" do
      expect { resolver.send(:resolve_department, "Sales / Enablement") }
        .to raise_error(described_class::AttributeError, /no organizational unit/)
    end
  end

  describe "#format_value for a department already in the lookup" do
    let!(:marketing) { create(:group, lastname: "Marketing", organizational_unit: true) }
    let!(:retention) { create(:group, lastname: "Retention", parent: marketing, organizational_unit: true) }

    before { resolver.instance_variable_set(:@department_lookup, resolver.send(:build_department_lookup)) }

    it "formats the path without calling Group#ancestry_path again" do
      # build_department_lookup already computes every department's path once, from the
      # already-loaded, depth-first tree, specifically to avoid Group#ancestry_path's own
      # query-per-call cost (see its comment). format_value must reuse that, not re-derive the
      # path by calling #ancestry_path on the resolved Group -- otherwise every formatted
      # department match in a document re-triggers the exact query cost the lookup exists to
      # avoid, on top of whatever build_department_lookup already paid once.
      allow(retention).to receive(:ancestry_path).and_raise("should not be called")

      expect(resolver.send(:format_value, retention)).to eq("Marketing / Retention")
    end
  end

  describe "#build_department_lookup query count" do
    before do
      marketing = create(:group, lastname: "Marketing", organizational_unit: true)
      5.times { |i| create(:group, lastname: "Team #{i}", parent: marketing, organizational_unit: true) }
    end

    it "issues at most one query regardless of tree size" do
      expect { resolver.send(:build_department_lookup) }.to have_a_query_limit(1)
    end
  end

  describe "#call" do
    # jane is both the importing user and, in some examples, the assignee/responsible on the
    # resulting work package, so she needs both permissions: add_work_packages lets
    # WorkPackages::CreateContract accept her as author, work_package_assigned lets it accept
    # her as responsible/assignee (see WorkPackages::BaseContract#assignable_assignees).
    let(:project) do
      create(:project, types: [task_type],
                       member_with_permissions: { jane => %i[add_work_packages work_package_assigned] })
    end
    let(:task_type) { create(:type_task, name: "Task") }
    let!(:jane) { create(:user, mail: "jane.doe@example.com") }
    # WorkPackages::CreateContract requires a status and a priority to be assignable by default
    # (WorkPackages::SetAttributesService#set_default_status/#set_default_priority); neither is
    # seeded automatically for a fresh example, so create the "is_default" ones explicitly.
    let!(:default_status) { create(:default_status) }
    let!(:default_priority) { create(:default_priority) }

    it "resolves a single node into an unsaved, contract-valid work package" do
      doc = document("# Task: Rework the renewal reminder sequence\n")
      result = described_class.new(project:, user: jane).call(doc)

      expect(result).to be_success
      row = result.result.first
      expect(row.errors).to be_empty
      expect(row.work_package).not_to be_persisted
      expect(row.work_package.subject).to eq("Rework the renewal reminder sequence")
      expect(row.work_package.type).to eq(task_type)
    end

    it "resolves Accountable to the built-in responsible field" do
      doc = document(<<~MD)
        # Task: Rework the sequence
        - Accountable: jane.doe@example.com
      MD
      row = described_class.new(project:, user: jane).call(doc).result.first

      expect(row.work_package.responsible).to eq(jane)
      expect(row.attribute_matches).to include(label: "Accountable", formatted: "#{jane.name} (#{jane.mail})")
    end

    it "records an error against the source line for an unknown type" do
      doc = document("# Epic: Not enabled in this project\n")
      row = described_class.new(project:, user: jane).call(doc).result.first

      expect(row.errors).to eq([{ source_line: 1, message: 'unknown or disabled work package type "Epic"' }])
    end

    it "records an error for an attribute matching no built-in label and no custom field" do
      doc = document(<<~MD)
        # Task: Rework the sequence
        - Not A Real Field: whatever
      MD
      row = described_class.new(project:, user: jane).call(doc).result.first

      expect(row.errors).to eq([{ source_line: 1,
                                  message: 'Not A Real Field: no field named "Not A Real Field" on type "Task"' }])
    end

    it "raises an AttributeError for a custom field enabled on the type but not on this project" do
      # WorkPackageCustomField enablement is two separate admin steps: per-type (`types:`) and
      # per-project (`projects:`, or `is_for_all: true`). Here only the type side is done, so
      # WorkPackage#available_custom_fields (which acts_as_customizable's custom_field_<id>
      # accessors are gated on) must not see this field for `project` — and neither should the
      # resolver, or the preview would show a value that SetAttributesService later silently drops.
      create(:integer_wp_custom_field, name: "Budget", types: [task_type])
      doc = document(<<~MD)
        # Task: Rework the sequence
        - Budget: 100
      MD
      row = described_class.new(project:, user: jane).call(doc).result.first

      expect(row.errors).to eq([{ source_line: 1,
                                  message: 'Budget: no field named "Budget" on type "Task"' }])
      expect(row.attribute_matches).to be_empty
    end

    it "rejects a document whose front matter Project does not match" do
      doc = document(<<~MD)
        ---
        Project: Some Other Project
        ---

        # Task: Rework the sequence
      MD
      result = described_class.new(project:, user: jane).call(doc)

      expect(result).to be_failure
      expect(result.errors.first[:message]).to include("Some Other Project")
    end
  end

  describe "#call with a full OKR-shaped Key Result" do
    # sam is the importing user and the Key Result's Accountable, so she needs the same two
    # permissions jane needs above.
    let(:project) do
      create(:project, types: [key_result_type],
                       member_with_permissions: { sam => %i[add_work_packages work_package_assigned] })
    end
    let(:key_result_type) { create(:type, name: "Key Result") }
    # `:custom_field` (plain CustomField) has no `types`/`projects` association — only concrete
    # STI subclasses like WorkPackageCustomField do — so this uses the `:integer_wp_custom_field`
    # factory instead of the brief's `:custom_field, field_format: "int"`. Associating the field
    # with `key_result_type` alone is also not enough: WorkPackage.available_custom_fields (which
    # gates the acts_as_customizable custom_field_<id> accessors) additionally requires the field
    # to be enabled on the *project* (or is_for_all), hence `projects: [project]`.
    let!(:baseline_field) do
      create(:integer_wp_custom_field, name: "Baseline", types: [key_result_type], projects: [project])
    end
    let!(:confidence_field) do
      create(:integer_wp_custom_field, name: "Confidence", types: [key_result_type], projects: [project])
    end
    let!(:sam) { create(:user, mail: "sam.lee@example.com") }
    let!(:default_status) { create(:default_status) }
    let!(:default_priority) { create(:default_priority) }

    it "resolves every custom field to its stored value" do
      doc = document(<<~MD)
        # Key Result: Increase annual renewals from 65% to 75%
        - Accountable: sam.lee@example.com
        - Baseline: 65%
        - Confidence: 75%
      MD
      row = described_class.new(project:, user: sam).call(doc).result.first

      expect(row.errors).to be_empty
      expect(row.work_package.responsible).to eq(sam)
      # CustomValue::IntStrategy#typed_value casts back to Integer (value.to_i), not the brief's
      # assumed String — the custom_field_<id> getter always returns the typed value.
      expect(row.work_package.send(:"custom_field_#{baseline_field.id}")).to eq(65)
      expect(row.work_package.send(:"custom_field_#{confidence_field.id}")).to eq(75)
    end
  end
end
