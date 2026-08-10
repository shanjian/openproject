# Department Custom Field Format Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new custom field format, `"department"`, selectable in the standard "new custom field" admin flow and attachable to work package types, whose value is a single reference to a `Group` where `organizational_unit? == true` (the existing org-unit tree from the Department admin feature).

**Architecture:** `department` is a reference-type, single-select custom field format, architecturally closest to the existing `version` format (a flat reference to another table's rows), not to `hierarchy` (which has its own per-custom-field, Enterprise-gated tree model). Tree depth is faked for display via a breadcrumb label (`Group#ancestry_path`, e.g. `"Engineering / Frontend"`), the same trick `hierarchy` already uses. No new database tables or columns are needed — `custom_fields`/`custom_values` already support any `field_format` string. No new Angular component is needed — the existing generic `SelectEditFieldComponent` (already used by `version`/`hierarchy`) is reused by registering `'Group'` in its type map; it embeds allowed values directly (`schema_with_allowed_collection`, matching `version`), which the component already supports without a live HTTP fetch.

**Tech Stack:** Ruby on Rails 8 (custom field format registry, `CustomValue` strategies, `Queries::Filters`), Angular/TypeScript (edit-field type registration), RSpec.

## Global Constraints

- **Single-select only.** The format is registered with `multi_value_possible: false`. Do not add multi-value support.
- **Exact-match filtering/grouping only.** Filtering or grouping by a department must match only that exact node — never roll up to descendants. This is a deliberate v1 scope decision (see design doc); descendant rollup is planned for later and the filter class is written as its own dedicated class specifically so that change stays contained to one file.
- **Reuse the existing org-unit tree.** Every department option comes from `Group.organizational_units` (built by the earlier Department admin feature, already on `epic`). Do not introduce a second/parallel hierarchy model.
- **`only: %w(WorkPackage)`.** Do not add `Project` or other entities — out of scope for this iteration.
- **No EE dependency.** Do not set `enterprise_feature:` on the format registration, and do not gate anything behind `EnterpriseToken`.
- **Optional field.** Do not make any Objective/KR-specific requiredness assumption in this plan — that's an admin-configuration decision made when the field is activated on a type, not something this plan hard-codes.
- Source of truth for every design decision below: `docs/superpowers/specs/2026-08-10-department-custom-field-design.md`.

---

### Task 1: `Group#ancestry_path` + `:department` factories

Foundation used by every later task: the breadcrumb-style label, and factories for a department-format custom field.

**Files:**
- Modify: `app/models/groups/hierarchy.rb`
- Modify: `spec/factories/custom_field_factory.rb`
- Test: `spec/models/group_spec.rb`

**Interfaces:**
- Produces: `Group#ancestry_path` (instance method, no args, returns a `" / "`-joined string from root to self, e.g. `"Engineering / Frontend"`; a root node's path is just its own name). `factory :department_wp_custom_field` and the `:department` trait on `factory :custom_field`. Tasks 2, 3, 5, 6 depend on `ancestry_path`; Tasks 3-8's specs depend on the factories.

- [ ] **Step 1: Write the failing spec**

Add to the existing `describe "hierarchy" do ... end` block in `spec/models/group_spec.rb` (alongside the `#children`/`#destroy` examples already there), right after the `#destroy` block added by the earlier Department feature:

```ruby
    describe "#ancestry_path" do
      it "is just its own name for a root group" do
        expect(grandparent.ancestry_path).to eq(grandparent.name)
      end

      it "joins ancestor names root-to-leaf with a slash" do
        expect(grandchild.ancestry_path)
          .to eq("#{grandparent.name} / #{parent_group.name} / #{child.name} / #{grandchild.name}")
      end
    end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/models/group_spec.rb -e "#ancestry_path"`
Expected: FAIL — `NoMethodError: undefined method 'ancestry_path'`.

- [ ] **Step 3: Add the method**

In `app/models/groups/hierarchy.rb`, add this public instance method (alongside `#children`, `#root`, etc. — anywhere in the public section is fine, e.g. right after `#root?`):

```ruby
  def ancestry_path
    (ancestors(order: :asc).to_a + [self]).map(&:name).join(" / ")
  end
```

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bundle exec rspec spec/models/group_spec.rb -e "#ancestry_path"`
Expected: PASS.

- [ ] **Step 5: Add the `:department` factory trait and `:department_wp_custom_field`**

In `spec/factories/custom_field_factory.rb`, add a new trait right after the existing `trait :version do ... end` block:

```ruby
    trait :department do
      field_format { "department" }
    end
```

In the same file, find the `factory :wp_custom_field, class: "WorkPackageCustomField" do ... end` block's `%w[...]` trait list (the one containing `version multi_version`) and add `"department"` to it:

```ruby
      %w[
        boolean
        date
        department
        float
        hierarchy multi_hierarchy
        integer
        link
        list multi_list
        weighted_item_list
        string
        text
        user multi_user
        version multi_version
      ].each do |trait|
        factory :"#{trait}_wp_custom_field", traits: [trait]
      end
```

(Alphabetical placement — `department` sorts between `date` and `float`.)

- [ ] **Step 6: Verify the factories work**

Run: `bundle exec rspec spec/models/group_spec.rb`
Expected: PASS (all examples, no new failures). This step only exercises `group_spec.rb`; the new factories themselves get exercised for real starting in Task 3's spec.

- [ ] **Step 7: Commit**

```bash
git add app/models/groups/hierarchy.rb spec/factories/custom_field_factory.rb spec/models/group_spec.rb
git commit -m "feat(custom-fields): add Group#ancestry_path and :department factories"
```

---

### Task 2: Register the `department` custom field format

**Files:**
- Modify: `config/initializers/custom_field_format.rb`
- Modify: `config/locales/en.yml`
- Test: `spec/lib/api/v3/utilities/custom_field_injector_spec.rb` (the `TYPE_MAP` example already loops over `OpenProject::CustomFieldFormat.available_formats`, so registering the format will make that existing test start exercising `"department"` automatically once Task 6 adds the `TYPE_MAP` entry — no new spec needed for the format registration itself, but this task's format registration is what makes that loop pick it up).

**Interfaces:**
- Consumes: nothing new.
- Produces: `OpenProject::CustomFieldFormat.find_by(name: "department")`, `"department"` appearing in `OpenProject::CustomFieldFormat.available_formats`. Every later task's specs rely on the format being registered (otherwise `build(:custom_field, field_format: "department")` would still work — factories don't validate against the registry — but the admin UI dropdown and `CustomField#validate_field_format_inclusion` do).

- [ ] **Step 1: Write the failing spec**

Create `spec/lib/open_project/custom_field_format_department_spec.rb`:

```ruby
# frozen_string_literal: true

require "spec_helper"

RSpec.describe "the department custom field format" do
  it "is registered" do
    format = OpenProject::CustomFieldFormat.find_by(name: "department")

    expect(format).to be_present
    expect(format.label).to eq(:label_department)
    expect(format.multi_value_possible?).to be(false)
    expect(format.for_class_name?("WorkPackage")).to be(true)
    expect(format.for_class_name?("Project")).to be(false)
  end

  it "is available without an Enterprise token" do
    format = OpenProject::CustomFieldFormat.find_by(name: "department")

    expect(format.available?).to be(true)
  end
end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/lib/open_project/custom_field_format_department_spec.rb`
Expected: FAIL — `expected nil to be_present` (format not found).

- [ ] **Step 3: Register the format**

In `config/initializers/custom_field_format.rb`, add this registration right after the `"version"` block (before the `"empty"` block):

```ruby
  fields.register OpenProject::CustomFieldFormat.new("department",
                                                     label: :label_department,
                                                     only: %w(WorkPackage),
                                                     order: 10.5,
                                                     multi_value_possible: false,
                                                     formatter: "CustomValue::DepartmentStrategy")
```

(`order: 10.5` sits it between `version` (10) and `empty` (11) in the format dropdown — there's no strict requirement it be an integer, `order` is only used for `sort_by`.)

- [ ] **Step 4: Add the locale label**

In `config/locales/en.yml`, add `label_department: "Department"` right before the existing `label_departments: "Organization"` line (find that line — it's near `label_hierarchy`/`label_list` in the same top-level `label_*` cluster):

```yaml
  label_department: "Department"
  label_departments: "Organization"
```

- [ ] **Step 5: Run the spec to verify it passes**

Run: `bundle exec rspec spec/lib/open_project/custom_field_format_department_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add config/initializers/custom_field_format.rb config/locales/en.yml spec/lib/open_project/custom_field_format_department_spec.rb
git commit -m "feat(custom-fields): register the department custom field format"
```

---

### Task 3: `CustomValue::DepartmentStrategy` + `CustomField` integration

Wires the actual value storage/casting/validation, and the `CustomField` methods that list/validate possible departments.

**Files:**
- Create: `app/models/custom_value/department_strategy.rb`
- Modify: `app/models/custom_field.rb`
- Test: `spec/models/custom_value/department_strategy_spec.rb`
- Test: `spec/models/custom_field_spec.rb`

**Interfaces:**
- Consumes: `Group.organizational_units`, `Group#ancestry_path` (Task 1), the `department` format registration (Task 2).
- Produces: `CustomField#possible_department_values` (returns `ActiveRecord::Relation` of `Group`, tree-ordered), `CustomField#possible_department_values_options` (returns `[[breadcrumb_string, id_string], ...]`), and the `"department"` branches in `#possible_values`, `#possible_values_options`, `#cast_value`. Tasks 4, 5, 6 depend on `possible_department_values`/`possible_department_values_options` by exact name.

- [ ] **Step 1: Write the failing spec for the strategy**

Create `spec/models/custom_value/department_strategy_spec.rb`, mirroring the existing `version_strategy_spec.rb` pattern exactly:

```ruby
# frozen_string_literal: true

require "spec_helper"

RSpec.describe CustomValue::DepartmentStrategy do
  let(:instance) { described_class.new(custom_value) }
  let(:custom_value) { instance_double(CustomValue, value:, custom_field:, customized:) }
  let(:customized) { instance_double(WorkPackage) }
  let(:custom_field) { build(:custom_field, :department) }
  let(:department) { build_stubbed(:department) }

  before do
    allow(Group).to receive(:organizational_units).and_return(Group.none)
    allow(Group.organizational_units).to receive(:find_by)
  end

  describe "#parse_value/#typed_value" do
    subject { instance }

    context "with a department" do
      let(:value) { department }

      it "returns the department and sets it for later retrieval" do
        expect(subject.parse_value(value)).to eql department.id.to_s

        expect(subject.typed_value).to eql value

        expect(Group.organizational_units).not_to have_received(:find_by)
      end
    end

    context "with an id string" do
      let(:value) { department.id.to_s }

      it "returns the string and has to later find the department" do
        allow(Group.organizational_units)
          .to receive(:find_by)
          .with(id: department.id.to_s)
          .and_return(department)

        expect(subject.parse_value(value)).to eql value

        expect(subject.typed_value).to eql department
      end
    end

    context "when value is blank" do
      let(:value) { "" }

      it "is nil and does not look for the department" do
        expect(subject.parse_value(value)).to be_nil

        expect(subject.typed_value).to be_nil

        expect(Group.organizational_units).not_to have_received(:find_by)
      end
    end
  end

  describe "#formatted_value" do
    subject { instance.formatted_value }

    context "with a department" do
      let(:value) { department }

      it "is the department's ancestry path (without db access)" do
        instance.parse_value(value)

        expect(subject).to eql department.ancestry_path

        expect(Group.organizational_units).not_to have_received(:find_by)
      end
    end

    context "when the referenced department no longer exists" do
      let(:value) { "999999" }

      it "falls back to a not-found message instead of raising" do
        allow(Group.organizational_units).to receive(:find_by).with(id: "999999").and_return(nil)

        expect(subject).to eql "999999 #{I18n.t(:label_not_found)}"
      end
    end
  end

  describe "#validate_type_of_value" do
    subject { instance.validate_type_of_value }

    let(:allowed_ids) { %w(12 13) }

    before do
      allow(custom_field).to receive(:possible_values).with(customized).and_return(allowed_ids)
    end

    context "when value is an id of an included element" do
      let(:value) { "12" }

      it "accepts" do
        expect(subject).to be_nil
      end
    end

    context "when value is an id of a non-included element" do
      let(:value) { "10" }

      it "rejects" do
        expect(subject).to be(:inclusion)
      end
    end
  end
end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/models/custom_value/department_strategy_spec.rb`
Expected: FAIL — `uninitialized constant CustomValue::DepartmentStrategy`.

- [ ] **Step 3: Write the strategy**

Create `app/models/custom_value/department_strategy.rb`:

```ruby
# frozen_string_literal: true

class CustomValue::DepartmentStrategy < CustomValue::ARObjectStrategy
  def formatted_value
    department = cached_ar_object

    if department
      department.ancestry_path
    else
      "#{value} #{I18n.t(:label_not_found)}"
    end
  end

  private

  def ar_class
    Group
  end

  def ar_object(value)
    Group.organizational_units.find_by(id: value)
  end
end
```

(No `validate_type_of_value` override needed — the base `ARObjectStrategy` checks `custom_field.possible_values(customized).include?(value)`, and Task 3 Step 5 below makes `possible_values` for `"department"` return exactly the set of valid ids, so the inherited check is already correct.)

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bundle exec rspec spec/models/custom_value/department_strategy_spec.rb`
Expected: PASS.

- [ ] **Step 5: Write the failing spec for `CustomField`**

Add to `spec/models/custom_field_spec.rb` (add a new top-level `describe` block; check the file first for where similar `"hierarchy"`/`"version"`-format examples already live and place this alongside them):

```ruby
  describe "department format" do
    shared_let(:root_department) { create(:department) }
    shared_let(:child_department) { create(:department, parent: root_department) }
    let(:custom_field) { build(:custom_field, :department) }

    describe "#possible_department_values" do
      it "returns all organizational units in tree order" do
        expect(custom_field.possible_department_values).to eq([root_department, child_department])
      end
    end

    describe "#possible_department_values_options" do
      it "returns ancestry-path/id pairs" do
        expect(custom_field.possible_department_values_options).to eq(
          [
            [root_department.ancestry_path, root_department.id],
            [child_department.ancestry_path, child_department.id]
          ]
        )
      end
    end

    describe "#possible_values" do
      it "returns the ids of all organizational units as strings" do
        expect(custom_field.possible_values).to contain_exactly(root_department.id.to_s, child_department.id.to_s)
      end
    end

    describe "#possible_values_options" do
      it "delegates to #possible_department_values_options" do
        expect(custom_field.possible_values_options).to eq(custom_field.possible_department_values_options)
      end
    end

    describe "#cast_value" do
      it "returns the referenced department" do
        expect(custom_field.cast_value(child_department.id.to_s)).to eq(child_department)
      end
    end
  end
```

- [ ] **Step 6: Run the spec to verify it fails**

Run: `bundle exec rspec spec/models/custom_field_spec.rb -e "department format"`
Expected: FAIL — `NoMethodError: undefined method 'possible_department_values'`.

- [ ] **Step 7: Add the `CustomField` methods and branches**

In `app/models/custom_field.rb`, add these two new public methods right after `custom_field_hierarchy_items` (which they sit alongside conceptually):

```ruby
  def possible_department_values
    Group.organizational_units.in_tree_order
  end

  def possible_department_values_options
    possible_department_values.map { |department| [department.ancestry_path, department.id] }
  end
```

In the same file, update the `possible_values_options` case statement to add a branch:

```ruby
  def possible_values_options(obj = nil, options: {})
    case field_format
    when "user"
      possible_user_values_options(obj)
    when "version"
      possible_version_values_options(obj, options:)
    when "list"
      possible_list_values_options
    when "department"
      possible_department_values_options
    else
      possible_values
    end
  end
```

Update the `possible_values` case statement:

```ruby
  def possible_values(obj = nil)
    case field_format
    when "user"
      possible_users(obj).pluck(:id).map(&:to_s)
    when "version"
      possible_versions(obj).pluck(:id).map(&:to_s)
    when "list"
      custom_options
    when "hierarchy", "weighted_item_list"
      custom_field_hierarchy_items
    when "department"
      possible_department_values.pluck(:id).map(&:to_s)
    else
      read_attribute(:possible_values)
    end
  end
```

Update the `cast_value` case statement:

```ruby
  def cast_value(value)
    return if value.blank?

    case field_format
    when "string", "text", "list", "link"
      value
    when "date"
      begin
        value.to_date
      rescue StandardError
        nil
      end
    when "bool"
      ActiveRecord::Type::Boolean.new.cast(value)
    when "int"
      value.to_i
    when "float", "calculated_value"
      value.to_f
    when "user"
      Principal.find_by(id: value.to_i)
    when "version"
      Version.find_by(id: value.to_i)
    when "hierarchy", "weighted_item_list"
      CustomField::Hierarchy::Item.find_by(id: value.to_i)
    when "department"
      Group.organizational_units.find_by(id: value.to_i)
    end
  end
```

- [ ] **Step 8: Run the spec to verify it passes**

Run: `bundle exec rspec spec/models/custom_field_spec.rb -e "department format"`
Expected: PASS.

- [ ] **Step 9: Run both specs together plus the format registration spec**

Run: `bundle exec rspec spec/models/custom_value/department_strategy_spec.rb spec/models/custom_field_spec.rb spec/lib/open_project/custom_field_format_department_spec.rb`
Expected: PASS (all).

- [ ] **Step 10: Commit**

```bash
git add app/models/custom_value/department_strategy.rb app/models/custom_field.rb spec/models/custom_value/department_strategy_spec.rb spec/models/custom_field_spec.rb
git commit -m "feat(custom-fields): add CustomValue::DepartmentStrategy and CustomField department branches"
```

---

### Task 4: Filtering — `Queries::Filters::Shared::CustomFields::Department`

A dedicated filter class (not a branch inside the shared `ListOptional` class) so that a future switch to descendant-inclusive matching stays contained to this one file.

**Files:**
- Create: `app/models/queries/filters/shared/custom_fields/department.rb`
- Modify: `app/models/queries/filters/shared/custom_field_filter.rb`
- Test: `spec/models/queries/work_packages/filter/custom_fields/custom_field_filter_spec.rb`

**Interfaces:**
- Consumes: `Group.organizational_units` (Task 1's org-unit tree), `CustomField#possible_department_values_options` (Task 3, via the inherited `Base#allowed_values`).
- Produces: `Queries::Filters::Shared::CustomFields::Department`, registered for `field_format == "department"` in `subfilter_class`. Task 8's end-to-end spec depends on filtering actually working through this class.

- [ ] **Step 1: Write the failing spec**

In `spec/models/queries/work_packages/filter/custom_fields/custom_field_filter_spec.rb`, add a `department_wp_custom_field` let and add it to `all_custom_fields`:

```ruby
  let(:department_wp_custom_field) { build_stubbed(:department_wp_custom_field) }
```

Add it to the `all_custom_fields` array (alongside `hierarchy_wp_custom_field`):

```ruby
  let(:all_custom_fields) do
    [list_wp_custom_field,
     bool_wp_custom_field,
     int_wp_custom_field,
     float_wp_custom_field,
     text_wp_custom_field,
     user_wp_custom_field,
     version_wp_custom_field,
     date_wp_custom_field,
     string_wp_custom_field,
     link_wp_custom_field,
     hierarchy_wp_custom_field,
     department_wp_custom_field]
  end
```

Then, inside the existing `describe "#type" do ... end` block, add a new nested `describe` right after the existing `describe "version" do ... end` block:

```ruby
    describe "department" do
      let(:cf_accessor) { department_wp_custom_field.column_name }

      it "is list_optional for a department" do
        expect(instance.type)
          .to be(:list_optional)
      end
    end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/models/queries/work_packages/filter/custom_fields/custom_field_filter_spec.rb -e "department"`
Expected: FAIL — `expected #<... :string> to be :list_optional` (falls through to the `Base` default because `subfilter_class` doesn't know `"department"` yet, and `Base#type` doesn't special-case it either — it's `:string` by default).

- [ ] **Step 3: Write the filter class**

Create `app/models/queries/filters/shared/custom_fields/department.rb`:

```ruby
# frozen_string_literal: true

require_relative "base"

module Queries::Filters::Shared
  module CustomFields
    class Department < Base
      def ar_object_filter?
        true
      end

      def value_objects
        Group.organizational_units.where(id: @values)
      end

      def type
        :list_optional
      end

      protected

      def type_strategy_class
        ::Queries::Filters::Strategies::CfListOptional
      end
    end
  end
end
```

- [ ] **Step 4: Register it in `subfilter_class`**

In `app/models/queries/filters/shared/custom_field_filter.rb`, update the `subfilter_class` case statement:

```ruby
    def subfilter_class(custom_field)
      case custom_field.field_format
      when "user"
        ::Queries::Filters::Shared::CustomFields::User
      when "list", "version"
        ::Queries::Filters::Shared::CustomFields::ListOptional
      when "hierarchy", "weighted_item_list"
        ::Queries::Filters::Shared::CustomFields::Hierarchy
      when "department"
        ::Queries::Filters::Shared::CustomFields::Department
      when "bool"
        ::Queries::Filters::Shared::CustomFields::Bool
      else
        ::Queries::Filters::Shared::CustomFields::Base
      end
    end
```

- [ ] **Step 5: Run the spec to verify it passes**

Run: `bundle exec rspec spec/models/queries/work_packages/filter/custom_fields/custom_field_filter_spec.rb`
Expected: PASS (all examples, including the pre-existing ones — confirms no regression from adding `department_wp_custom_field` to the shared `all_custom_fields` array).

- [ ] **Step 6: Commit**

```bash
git add app/models/queries/filters/shared/custom_fields/department.rb app/models/queries/filters/shared/custom_field_filter.rb spec/models/queries/work_packages/filter/custom_fields/custom_field_filter_spec.rb
git commit -m "feat(custom-fields): add dedicated Department filter class"
```

---

### Task 5: Grouping — `CustomField::OrderStatements`

**Files:**
- Modify: `app/models/custom_field/order_statements.rb`
- Test: `spec/models/custom_field/order_statements_spec.rb`

**Interfaces:**
- Consumes: nothing new (works directly against `custom_values.value` and the `groups` table).
- Produces: `department` support in `ORDER_JOIN_METHOD_BY_FIELD_FORMAT` and `can_be_used_for_grouping?`. Task 8's end-to-end spec depends on grouping actually working.

- [ ] **Step 1: Write the failing spec**

Add to `spec/models/custom_field/order_statements_spec.rb`, as a new top-level `context` mirroring the existing `context "when hierarchy" do ... end` block exactly in shape:

```ruby
  context "when department" do
    shared_let(:department) { create(:department) }

    subject(:custom_field) { create(:department_wp_custom_field) }

    describe "#order_statement" do
      it { expect(subject.order_statement).to eq("cf_order_#{custom_field.id}.value") }
    end

    describe "#order_join_statement" do
      it "must be equal" do
        expect(custom_field.order_join_statement).to eq(<<-SQL.squish)
          LEFT OUTER JOIN (
            SELECT DISTINCT ON (cv.customized_id) cv.customized_id
                 , departments_for_ordering.lastname "value"
            FROM "custom_values" cv INNER JOIN "users" departments_for_ordering ON departments_for_ordering.id = cv.value::bigint
            WHERE cv.customized_type = 'WorkPackage' AND cv.custom_field_id = #{custom_field.id}
                  AND cv.value IS NOT NULL AND cv.value != '' ORDER BY cv.customized_id, cv.id
          ) cf_order_#{custom_field.id} ON cf_order_#{custom_field.id}.customized_id = "work_packages".id
        SQL
      end
    end

    describe "#can_be_used_for_grouping?" do
      it "is true" do
        expect(custom_field.send(:can_be_used_for_grouping?)).to be(true)
      end
    end

    describe "#group_by_statement" do
      it "equals the order statement" do
        expect(custom_field.group_by_statement).to eq(custom_field.order_statement)
      end
    end
  end
```

(`INNER JOIN "users" departments_for_ordering` — `Group` is a `Principal` STI subtype stored in the `users` table, so `Group.quoted_table_name` is `"users"`, exactly like the FK target in the `group_details` migration from the earlier Department feature.)

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/models/custom_field/order_statements_spec.rb -e "when department"`
Expected: FAIL — `expected nil to eq "cf_order_#{id}.value"` (`order_statement` returns `nil` because `"department"` isn't in `ORDER_JOIN_METHOD_BY_FIELD_FORMAT` yet, and `can_be_used_for_grouping?` is `false`).

- [ ] **Step 3: Add the join method and register it**

In `app/models/custom_field/order_statements.rb`, update the `ORDER_JOIN_METHOD_BY_FIELD_FORMAT` hash:

```ruby
  ORDER_JOIN_METHOD_BY_FIELD_FORMAT = OpenProject::MultiKeyHash.expand(
    %w[string date bool link] => :join_for_order_by_string_sql,
    "int" => :join_for_order_by_int_sql,
    %w[float calculated_value] => :join_for_order_by_float_sql,
    "list" => :join_for_order_by_list_sql,
    "user" => :join_for_order_by_user_sql,
    "version" => :join_for_order_by_version_sql,
    "department" => :join_for_order_by_department_sql,
    %w[hierarchy weighted_item_list] => :join_for_order_by_hierarchy_sql
  ).freeze
```

Update `can_be_used_for_grouping?`:

```ruby
  def can_be_used_for_grouping? = field_format.in?(%w[list date bool int float string link hierarchy department])
```

Add the new private join method, right after `join_for_order_by_version_sql`:

```ruby
  def join_for_order_by_department_sql
    join_for_order_sql(
      value: "departments_for_ordering.lastname",
      join: "INNER JOIN #{Group.quoted_table_name} departments_for_ordering ON departments_for_ordering.id = cv.value::bigint"
    )
  end
```

(No `multi_value?` ternary needed here, unlike `version`/`user` — the `department` format is single-value only, so there's no multi-value branch to support. `multi_value: false` is `join_for_order_sql`'s own default, so it doesn't need to be passed explicitly.)

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bundle exec rspec spec/models/custom_field/order_statements_spec.rb`
Expected: PASS (all examples, including the pre-existing hierarchy one).

- [ ] **Step 5: Commit**

```bash
git add app/models/custom_field/order_statements.rb spec/models/custom_field/order_statements_spec.rb
git commit -m "feat(custom-fields): add grouping support for the department format"
```

---

### Task 6: API v3 — `CustomFieldInjector` + `AssignableCustomFieldValues`

Exposes the field on the work package resource, reusing the existing `Groups::GroupRepresenter`.

**Files:**
- Modify: `lib/api/v3/utilities/custom_field_injector.rb`
- Modify: `app/contracts/concerns/assignable_custom_field_values.rb`
- Test: `spec/lib/api/v3/utilities/custom_field_injector_spec.rb`

**Interfaces:**
- Consumes: `API::V3::Groups::GroupRepresenter` (built by the earlier Department feature), `CustomField#possible_department_values` (Task 3).
- Produces: the `department` format exposed through the work package API's `_links`/schema. Task 8's end-to-end spec depends on this for the request-level assertions.

- [ ] **Step 1: Write the failing spec**

In `spec/lib/api/v3/utilities/custom_field_injector_spec.rb`, add a new `describe` block right after the existing `describe "version custom field" do ... end` block (inside the outer `describe "#inject_schema" do ... end`):

```ruby
    describe "department custom field" do
      let(:custom_field) do
        build(:department_wp_custom_field,
              is_required: true)
      end

      let(:assignable_departments) { build_stubbed_list(:department, 3) }

      before do
        allow(schema)
          .to receive(:assignable_custom_field_values)
          .with(custom_field)
          .and_return(assignable_departments)

        allow(API::V3::Groups::GroupRepresenter).to receive(:create).and_return(double)
      end

      it_behaves_like "has basic schema properties" do
        let(:path) { cf_path }
        let(:type) { "Group" }
        let(:name) { custom_field.name }
        let(:required) { true }
        let(:writable) { true }
        let(:location) { "_links" }
      end

      it_behaves_like "links to allowed values directly" do
        let(:path) { cf_path }
        let(:hrefs) { assignable_departments.map { |department| api_v3_paths.group department.id } }
      end

      it "embeds allowed values" do
        expect(subject)
          .to have_json_size(assignable_departments.size)
          .at_path("#{cf_path}/_embedded/allowedValues")
      end
    end
```

Also add `"department" => "Group"` — no, don't touch `TYPE_MAP` in the spec itself; the existing `describe "TYPE_MAP" do ... end` block already loops over every registered format automatically, so it will start covering `"department"` as soon as Task 6 Step 3 below adds the entry.

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/lib/api/v3/utilities/custom_field_injector_spec.rb -e "department custom field"`
Expected: FAIL — `NoMethodError` or a nil-type failure (no `inject_department_schema`, no `TYPE_MAP` entry yet).

Also run: `bundle exec rspec spec/lib/api/v3/utilities/custom_field_injector_spec.rb -e "TYPE_MAP"`
Expected at this point: still PASS (the format isn't registered as a *new* gap yet from this spec file's perspective) — this is just to confirm the baseline before changing `TYPE_MAP`.

- [ ] **Step 3: Update the injector's format maps**

In `lib/api/v3/utilities/custom_field_injector.rb`, update `TYPE_MAP`:

```ruby
        TYPE_MAP = {
          "string" => "String",
          "empty" => "String",
          "text" => "Formattable",
          "link" => "Link",
          "int" => "Integer",
          "float" => "Float",
          "date" => "Date",
          "bool" => "Boolean",
          "user" => "User",
          "version" => "Version",
          "department" => "Group",
          "list" => "CustomOption",
          "hierarchy" => "CustomField::Hierarchy::Item",
          "weighted_item_list" => "CustomField::Hierarchy::Item",
          "calculated_value" => "CalculatedValue"
        }.freeze
```

Update `LINK_FORMATS`:

```ruby
        LINK_FORMATS = %w(list user version department hierarchy weighted_item_list).freeze
```

Update `NAMESPACE_MAP`:

```ruby
        NAMESPACE_MAP = {
          "user" => %w[users groups placeholder_users],
          "version" => "versions",
          "department" => "groups",
          "list" => "custom_options",
          "hierarchy" => "custom_field_items",
          "weighted_item_list" => "custom_field_items"
        }.freeze
```

Update `REPRESENTER_MAP`:

```ruby
        REPRESENTER_MAP = {
          "user" => "::API::V3::Principals::PrincipalRepresenterFactory",
          "version" => "::API::V3::Versions::VersionRepresenter",
          "department" => "::API::V3::Groups::GroupRepresenter",
          "list" => "::API::V3::CustomOptions::CustomOptionRepresenter",
          "hierarchy" => "::API::V3::CustomFields::Hierarchy::HierarchyItemRepresenter",
          "weighted_item_list" => "::API::V3::CustomFields::Hierarchy::HierarchyItemRepresenter"
        }.freeze
```

- [ ] **Step 4: Add `inject_department_schema` and register it**

In the same file, update the `inject_schema` case statement:

```ruby
        def inject_schema(custom_field)
          case custom_field.field_format
          when "version"
            inject_version_schema(custom_field)
          when "department"
            inject_department_schema(custom_field)
          when "user"
            inject_user_schema(custom_field)
          when "list"
            inject_list_schema(custom_field)
          when "hierarchy", "weighted_item_list"
            inject_hierarchy_schema(custom_field)
          else
            inject_basic_schema(custom_field)
          end

          inject_comment_schema(custom_field)
        end
```

Add the new method right after `inject_version_schema`:

```ruby
        def inject_department_schema(custom_field)
          @class.schema_with_allowed_collection property_name(custom_field),
                                                type: resource_type(custom_field),
                                                name_source: ->(*) { custom_field.name },
                                                values_callback: ->(*) {
                                                  represented
                                                    .assignable_custom_field_values(custom_field)
                                                },
                                                value_representer: Groups::GroupRepresenter,
                                                link_factory: ->(department) {
                                                  {
                                                    href: api_v3_paths.group(department.id),
                                                    title: department.ancestry_path
                                                  }
                                                },
                                                required: custom_field.is_required
        end
```

- [ ] **Step 5: Add the `assignable_custom_field_values` branch**

In `app/contracts/concerns/assignable_custom_field_values.rb`, update the case statement:

```ruby
    def assignable_custom_field_values(custom_field)
      case custom_field.field_format
      when "list"
        custom_field.possible_values
      when "version"
        assignable_version_custom_field_values(custom_field)
      when "department"
        custom_field.possible_department_values
      end
    end
```

- [ ] **Step 6: Run the spec to verify it passes**

Run: `bundle exec rspec spec/lib/api/v3/utilities/custom_field_injector_spec.rb`
Expected: PASS (all examples, including `TYPE_MAP` and every pre-existing format's examples — confirms no regression).

- [ ] **Step 7: Commit**

```bash
git add lib/api/v3/utilities/custom_field_injector.rb app/contracts/concerns/assignable_custom_field_values.rb spec/lib/api/v3/utilities/custom_field_injector_spec.rb
git commit -m "feat(custom-fields): expose the department format through the work package API"
```

---

### Task 7: Angular — register `'Group'` on the select edit field

**Files:**
- Modify: `frontend/src/app/shared/components/fields/edit/edit-field.initializer.ts`

**Interfaces:**
- Consumes: the existing `SelectEditFieldComponent` (already used by `'Version'`, `'CustomField::Hierarchy::Item'`).
- Produces: nothing consumed by a later task in this plan — this is the last plumbing piece; Task 8 verifies the full stack from the API side (frontend behavior itself isn't covered by an RSpec suite, and there's no existing Jasmine/Karma spec file for `edit-field.initializer.ts` to extend — see the "Note" below).

- [ ] **Step 1: Register `'Group'` on the existing select field type**

In `frontend/src/app/shared/components/fields/edit/edit-field.initializer.ts`, update the `SelectEditFieldComponent` registration:

```typescript
      .addFieldType(SelectEditFieldComponent, 'select', [
        'Priority',
        'ProjectPhase',
        'Status',
        'Type',
        'Version',
        'Group',
        'TimeEntriesActivity',
        'Category',
        'CustomOption',
        'CustomField::Hierarchy::Item',
      ])
```

(Do not add `'[]Group'` to `MultiSelectEditFieldComponent`'s list — `department` is single-value only, per the Global Constraints, so there's no multi-value variant.)

- [ ] **Step 2: Confirm the frontend still type-checks**

Run: `cd frontend && npx tsc --noEmit -p tsconfig.json`
Expected: no new type errors (this is a one-line addition to a plain string array — there is no compile-time link between this array and any TypeScript type, so this step is a sanity check, not a strict requirement of the change).

**Note:** this repository's Angular edit-field type registration has no existing unit test file (`edit-field.initializer.ts` is plumbing consumed transitively by every field-type feature spec, not something tested in isolation — confirmed by there being no existing spec for the `'Version'`/`'CustomField::Hierarchy::Item'` entries either). Task 8's end-to-end feature spec is where this registration gets exercised for real, by loading a work package edit form with a department field on it.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/app/shared/components/fields/edit/edit-field.initializer.ts
git commit -m "feat(custom-fields): reuse SelectEditFieldComponent for the department format"
```

---

### Task 8: End-to-end verification

**Files:**
- Test: `spec/requests/api/v3/work_packages/department_custom_field_spec.rb`

**Interfaces:**
- Consumes: everything from Tasks 1-6.
- Produces: nothing — this is the final confirmation that the whole stack works together against a real database, real HTTP-shaped request objects, and a real work package type (a plain generated `:type`, not "Objective"/"Key Result" — those OKR-specific work package types don't exist in this fork yet and are out of scope for this plan; creating them is separate, future work).

- [ ] **Step 1: Write the end-to-end spec**

Create `spec/requests/api/v3/work_packages/department_custom_field_spec.rb`:

```ruby
# frozen_string_literal: true

require "spec_helper"
require "rack/test"

RSpec.describe "Department custom field on work packages", :aggregate_failures do
  include Rack::Test::Methods
  include API::V3::Utilities::PathHelper

  shared_let(:admin) { create(:admin) }
  shared_let(:engineering) { create(:department) }
  shared_let(:frontend_team) { create(:department, parent: engineering) }
  shared_let(:sales) { create(:department) }

  shared_let(:department_field) { create(:department_wp_custom_field) }
  shared_let(:project) { create(:project, work_package_custom_fields: [department_field]) }
  shared_let(:work_package_type) do
    type = create(:type, custom_fields: [department_field])
    project.types << type
    type
  end

  let(:work_package) do
    create(:work_package, project:, type: work_package_type)
  end

  current_user { admin }

  describe "setting the value" do
    it "accepts a link to an organizational unit and rejects a plain (non-department) group" do
      patch api_v3_paths.work_package(work_package.id),
            {
              department_field.attribute_name(:camel_case) => {
                href: api_v3_paths.group(frontend_team.id)
              },
              lockVersion: work_package.lock_version
            }.to_json,
            "CONTENT_TYPE" => "application/json"

      expect(last_response.status).to eq(200)
      expect(work_package.reload.send(department_field.attribute_getter)).to eq(frontend_team)
    end
  end

  describe "the work package's schema" do
    it "embeds all organizational units as allowed values" do
      get api_v3_paths.work_package_schema(project.id, work_package_type.id)

      body = JSON.parse(last_response.body)
      embedded = body[department_field.attribute_name(:camel_case)]["_embedded"]["allowedValues"]

      expect(embedded.pluck("id").map(&:to_i)).to contain_exactly(engineering.id, frontend_team.id, sales.id)
    end
  end

  describe "filtering" do
    let!(:engineering_wp) do
      create(:work_package, project:, type: work_package_type,
                             custom_values: { department_field.id => engineering.id.to_s })
    end
    let!(:sales_wp) do
      create(:work_package, project:, type: work_package_type,
                             custom_values: { department_field.id => sales.id.to_s })
    end

    it "matches only the exact selected department, not its descendants or siblings" do
      query = build(:query, project:)
      query.filters.clear
      query.add_filter(department_field.column_name, "=", [engineering.id.to_s])

      expect(Query::Results.new(query).work_packages).to contain_exactly(engineering_wp)
    end
  end

  describe "grouping" do
    let!(:engineering_wp) do
      create(:work_package, project:, type: work_package_type,
                             custom_values: { department_field.id => engineering.id.to_s })
    end
    let!(:sales_wp) do
      create(:work_package, project:, type: work_package_type,
                             custom_values: { department_field.id => sales.id.to_s })
    end

    it "groups work packages by their department without error, returning every matching work package" do
      query = build(:query, project:)
      query.filters.clear
      query.group_by = department_field.column_name

      expect(Query::Results.new(query).work_packages.pluck(:id))
        .to contain_exactly(engineering_wp.id, sales_wp.id)
    end
  end
end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/requests/api/v3/work_packages/department_custom_field_spec.rb`
Expected: at this point in the plan (Tasks 1-7 already done), this should mostly PASS already — this task is a verification pass, not new implementation. If anything fails, that's a real integration gap between the individually-tested pieces from Tasks 1-6; read the failure and fix the specific layer it points at (do not weaken this spec to make it pass).

- [ ] **Step 3: Fix any integration gaps found**

There is no prescribed code here — if Step 2 fails, the fix belongs in whichever of Tasks 1-6's files the failure implicates. Common things to check first if something fails:
- `attribute_getter`/`attribute_name(:camel_case)` — confirm these are `WorkPackageCustomField`/`CustomField` instance methods already present in this codebase (they are, used throughout the existing custom field system) and are being called correctly.
- If the schema spec fails with an empty `allowedValues`, re-check Task 6 Step 5's `assignable_custom_field_values` branch is actually reached (add a `byebug`/`puts` temporarily, remove before committing).
- If filtering/grouping fail, re-check Task 4/5's exact SQL (`bundle exec rails dbconsole` and run the generated query by hand against the test database if needed).

- [ ] **Step 4: Run the full department-custom-field spec surface**

```bash
bundle exec rspec spec/models/group_spec.rb \
  spec/lib/open_project/custom_field_format_department_spec.rb \
  spec/models/custom_value/department_strategy_spec.rb \
  spec/models/custom_field_spec.rb \
  spec/models/queries/work_packages/filter/custom_fields/custom_field_filter_spec.rb \
  spec/models/custom_field/order_statements_spec.rb \
  spec/lib/api/v3/utilities/custom_field_injector_spec.rb \
  spec/requests/api/v3/work_packages/department_custom_field_spec.rb
```

Expected: all PASS.

- [ ] **Step 5: Run rubocop on all touched files**

```bash
bin/dirty-rubocop --uncommitted
```

Fix any offenses.

- [ ] **Step 6: Confirm no regressions in the adjacent custom field and work package query suites**

```bash
bundle exec rspec spec/models/custom_field_spec.rb spec/models/queries/work_packages/ spec/lib/api/v3/utilities/custom_field_injector_spec.rb spec/models/custom_field/
```

Expected: PASS — in particular, every pre-existing `"version"`/`"hierarchy"`/`"list"` example in these files should still pass unchanged, confirming the new `"department"` branches were purely additive.

- [ ] **Step 7: Manual smoke test**

Start the app (`bin/dev`), sign in as an admin, go to Administration → Custom fields → New custom field for work packages, confirm "Department" appears in the format dropdown, create one, activate it on a work package type, open a work package of that type and confirm the department select shows the org-unit tree (as a flat, breadcrumb-labeled list — no indentation widget, per the design doc's v1 scope), set a value, and confirm filtering/grouping by that field in the work package table works as expected.

- [ ] **Step 8: Commit**

```bash
git add spec/requests/api/v3/work_packages/department_custom_field_spec.rb
git commit -m "test(custom-fields): add end-to-end coverage for the department format"
```
