# Department (Organizational Unit) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port upstream OpenProject's "Departments" feature (a hierarchical organizational-unit entity for users) onto this fork's `epic` branch, giving admins a nested Department tree and giving each user a single `department` attribute.

**Architecture:** `Group` (existing `Principal` STI subtype) gains a generic 1:1 `group_details` table via a new `HasDetailsTable` concern (`organizational_unit` boolean + self-referential `parent_id`), plus a `Groups::Hierarchy` module for tree traversal (ancestors/descendants, circular-dependency checks). A department is simply `Group#organizational_unit? == true`. A new `Admin::DepartmentsController` + ViewComponents provide the admin CRUD/tree UI; `User#department` exposes the single department a user belongs to, surfaced on the profile, hover card, and admin user-edit form.

**Tech Stack:** Ruby 3.4.7 / Rails 8.0.3 (this fork's pins — matches upstream source, which already targets `ActiveRecord::Migration[8.1]`), ViewComponent + Primer + Turbo Frames (existing conventions), RSpec + Capybara.

## Global Constraints

- **Naming**: keep "Department" everywhere — Ruby/JS identifiers, table/column names, routes, locale strings/UI copy — matching upstream 1:1. No fork-specific renaming, even though "Organizational Unit" reads more accurately.
- **Scope**: core feature only. Do **not** port `modules/ldap_departments` (LDAP/AD auto-sync engine) — out of scope, deferred indefinitely.
- **No membership/role propagation**: departments get a plain parent/child tree for organizational display only. Do **not** port upstream's automatic project-role-inheritance-through-group-hierarchy behavior (`Groups::UpdateService#handle_parent_change`, `Groups::CreateInheritedRolesService` ancestor-loop changes, `Members::CreateService`/`Members::UpdateService` descendant/ancestor propagation). A department having a parent must have **zero** effect on project permissions.
- **No feature flag**: the feature is unconditionally enabled — no `OpenProject::FeatureDecisions` check, no EE-token gate.
- **Source of truth**: this is a port, not a fresh design. Every task below cites the exact upstream commit SHA(s) it is drawn from, on the `upstream` remote already configured in this repo (`git show <sha>` works locally without fetching). Where a task says "materialize from `<sha>:<path>`", that means run `git show <sha>:<path>` and write the output verbatim (or with the noted adaptation) — this is the precise, reproducible way to port a self-contained file, preferred over hand-transcription.
- **Migration timestamps**: this fork's latest migration is `20260727120000`. New migrations in this plan use `202608091200{01,02,03,04}` so they sort after it.

---

### Task 1: `HasDetailsTable` concern + `group_details` migration

Generic 1:1 "extra attributes table" pattern for `Principal` subtypes. Foundation for the department flag and parent pointer — has no department-specific logic itself.

**Files:**
- Create: `db/migrate/20260809120001_add_group_details.rb`
- Create: `app/models/concerns/has_details_table.rb`
- Test: `spec/models/concerns/has_details_table_spec.rb`

**Source:** `31a2536f51e` (initial `has_principal_details`), generalized by `deb52888365` (renamed to `has_details_table`, generic `foreign_key:` param). Port directly to the final (`has_details_table`) form — no need to replay the intermediate name.

**Interfaces:**
- Produces: `HasDetailsTable::ClassMethods#has_details_table(foreign_key: "#{model_name.element}_id", &block)` — class macro. When included and called on a model, dynamically defines `<Model>Detail < ApplicationRecord`, a `has_one :<model>_detail` association aliased to `#detail`/`#detail=`/`#build_detail`, and delegates the detail's columns/associations onto the owning model (so `group.organizational_unit?` and `group.parent` work directly). Later tasks (Task 2) call this on `Group`.

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20260809120001_add_group_details.rb
# frozen_string_literal: true

class AddGroupDetails < ActiveRecord::Migration[8.1]
  def change
    create_table :group_details do |t|
      t.references :principal, null: false, foreign_key: { to_table: :users }, index: { unique: true }
      t.boolean :organizational_unit, default: false, null: false
      t.references :parent, foreign_key: { to_table: :users }

      t.timestamps
    end

    reversible do |dir|
      dir.up do
        execute <<~SQL.squish
          INSERT INTO group_details (principal_id, organizational_unit, created_at, updated_at)
          SELECT id, false, NOW(), NOW()
          FROM users
          WHERE type = 'Group'
        SQL
      end
    end
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bundle exec rails db:migrate`
Expected: `group_details` table created; one row per existing `Group` with `organizational_unit: false`.

- [ ] **Step 3: Write the concern's spec**

Materialize `spec/models/concerns/has_details_table_spec.rb` from `deb52888365:spec/models/concerns/has_details_table_spec.rb` (run `git show deb52888365:spec/models/concerns/has_details_table_spec.rb > spec/models/concerns/has_details_table_spec.rb`). This spec defines its own throwaway test model/table inline (check the file — if it creates a temp table via `ActiveRecord::Schema`, no fixture changes are needed here).

- [ ] **Step 4: Run the spec to verify it fails**

Run: `bundle exec rspec spec/models/concerns/has_details_table_spec.rb`
Expected: FAIL — `uninitialized constant HasDetailsTable`.

- [ ] **Step 5: Write the concern**

Materialize `app/models/concerns/has_details_table.rb` from `deb52888365:app/models/concerns/has_details_table.rb` (the file existing at commit `d7bc648642c` is identical — either SHA works):

```ruby
# frozen_string_literal: true

module HasDetailsTable
  extend ActiveSupport::Concern

  class_methods do
    def has_details_table(foreign_key: "#{model_name.element}_id", &) # rubocop:disable Naming/PredicatePrefix
      foreign_key = foreign_key.to_s

      detail_class = build_detail_class(foreign_key, &)
      association_name = detail_class.name.underscore.to_sym

      setup_detail_association(association_name, detail_class, foreign_key)
      setup_detail_aliases(association_name)
      setup_detail_delegation(detail_class, foreign_key)
      setup_detail_changed_tracking(detail_class, foreign_key)
      setup_detail_dup
    end

    private

    def build_detail_class(foreign_key, &block)
      owner_name = model_name.element.to_sym
      fk = foreign_key

      klass = Class.new(ApplicationRecord) do
        belongs_to owner_name,
                   inverse_of: :"#{owner_name}_detail",
                   foreign_key: fk

        validates owner_name, presence: true, uniqueness: true

        class_eval(&block) if block
      end

      Object.const_set("#{name}Detail", klass)
    end

    def setup_detail_association(association_name, detail_class, foreign_key) # rubocop:disable Metrics/AbcSize
      has_one association_name, foreign_key:,
                                dependent: :destroy,
                                inverse_of: model_name.element.to_sym,
                                class_name: detail_class.name,
                                autosave: true
      accepts_nested_attributes_for association_name

      scope :with_detail, -> { joins(association_name).includes(association_name) }

      scope :where_detail, ->(**conditions) {
        joins(association_name).where(detail_class.table_name => conditions)
      }

      validate do
        next if detail.nil? || detail.valid?

        detail.errors.each do |error|
          errors.add(error.attribute, error.type, message: error.message)
        end
      end

      after_initialize do
        build_detail if new_record? && detail.nil?
      end
    end

    def setup_detail_aliases(association_name)
      alias_method :detail, association_name
      alias_method :detail=, :"#{association_name}="
      alias_method :build_detail, :"build_#{association_name}"
    end

    def setup_detail_changed_tracking(detail_class, foreign_key)
      setup_changed_method(detail_class, foreign_key)
      setup_changes_method(detail_class, foreign_key)
      setup_changed_question_method(detail_class, foreign_key)
      setup_changed_attributes_method(detail_class, foreign_key)
      setup_previous_changes_method(detail_class, foreign_key)
      setup_restore_attributes_method(detail_class, foreign_key)
      setup_reload_method

      alias_method :saved_changes, :previous_changes if method_defined?(:saved_changes)
    end

    def setup_changed_method(detail_class, foreign_key)
      define_method(:changed) do
        result = super()
        return result unless detail&.persisted?

        internal_columns = %w[id created_at updated_at] + [foreign_key]
        detail_columns = detail_class.column_names - internal_columns
        result | (detail.changed & detail_columns)
      end
    end

    def setup_changes_method(detail_class, foreign_key)
      define_method(:changes) do
        result = super()
        return result unless detail&.persisted?

        internal_columns = %w[id created_at updated_at] + [foreign_key]
        detail_columns = detail_class.column_names - internal_columns
        detail_changes = detail.changes.slice(*detail_columns)
        result.merge(detail_changes)
      end
    end

    def setup_changed_question_method(detail_class, foreign_key) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
      define_method(:changed?) do |attr = nil| # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
        internal_columns = %w[id created_at updated_at] + [foreign_key]
        detail_columns = detail_class.column_names - internal_columns

        if attr.nil?
          return true if super()
          return false unless detail&.persisted?

          detail.changed.intersect?(detail_columns)
        else
          attr = attr.to_s
          if detail_columns.include?(attr)
            detail.persisted? && detail.changed.include?(attr)
          else
            return false unless super()

            changed.include?(attr)
          end
        end
      end
    end

    def setup_changed_attributes_method(detail_class, foreign_key)
      define_method(:changed_attributes) do
        result = super()
        return result unless detail&.persisted?

        internal_columns = %w[id created_at updated_at] + [foreign_key]
        detail_columns = detail_class.column_names - internal_columns
        detail_changed = detail.changed_attributes.slice(*detail_columns)
        result.merge(detail_changed)
      end
    end

    def setup_previous_changes_method(detail_class, foreign_key)
      define_method(:previous_changes) do
        result = super()
        return result unless detail&.persisted?

        internal_columns = %w[id created_at updated_at] + [foreign_key]
        detail_columns = detail_class.column_names - internal_columns
        detail_previous = detail.previous_changes.slice(*detail_columns)
        result.merge(detail_previous)
      end
    end

    def setup_restore_attributes_method(detail_class, foreign_key)
      define_method(:restore_attributes) do |attributes = changed|
        attributes = Array(attributes).map(&:to_s)
        internal_columns = %w[id created_at updated_at] + [foreign_key]
        detail_columns = detail_class.column_names - internal_columns
        owner_attrs = attributes - detail_columns
        detail_attrs = attributes & detail_columns

        super(owner_attrs) if owner_attrs.any?
        detail.restore_attributes(detail_attrs) if detail_attrs.any? && detail&.persisted?
      end
    end

    def setup_reload_method
      define_method(:reload) do |*args|
        result = super(*args)
        detail&.reload
        result
      end
    end

    def setup_detail_delegation(detail_class, foreign_key)
      if ActiveRecord::Base.connected? && detail_class.table_exists?
        finalize_detail_delegation!(detail_class, foreign_key)
      end

      fk = foreign_key
      after_initialize do
        self.class.send(:finalize_detail_delegation!, detail_class, fk)
      end
    end

    def setup_detail_dup
      define_method(:dup) do
        super().tap do |copy|
          copy.detail = detail.dup if detail.present?
        end
      end
    end

    def define_detail_writer(writer)
      define_method(writer) do |value|
        record = detail || build_detail
        record.public_send(writer, value)
      end
    end

    def finalize_detail_delegation!(detail_class, foreign_key)
      return if @_detail_delegation_set_up
      return unless ActiveRecord::Base.connected? && detail_class.table_exists?

      @_detail_delegation_set_up = true

      delegate_detail_columns(detail_class, foreign_key)
      delegate_detail_associations(detail_class)
    end

    def delegate_detail_columns(detail_class, foreign_key)
      internal_columns = %w[id created_at updated_at] + [foreign_key]

      (detail_class.column_names - internal_columns).each do |col|
        delegate col.to_sym, to: :detail
        define_detail_writer(:"#{col}=")

        if detail_class.columns_hash[col]&.type == :boolean
          delegate :"#{col}?", to: :detail
        end
      end
    end

    def delegate_detail_associations(detail_class)
      detail_class.reflect_on_all_associations(:belongs_to).each do |reflection|
        next if reflection.name == model_name.element.to_sym

        delegate reflection.name, to: :detail
        define_detail_writer(:"#{reflection.name}=")
      end
    end
  end
end
```

- [ ] **Step 6: Run the spec to verify it passes**

Run: `bundle exec rspec spec/models/concerns/has_details_table_spec.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260809120001_add_group_details.rb app/models/concerns/has_details_table.rb spec/models/concerns/has_details_table_spec.rb db/schema.rb db/structure.sql
git commit -m "feat(departments): add HasDetailsTable concern and group_details table"
```

---

### Task 2: `Groups::Hierarchy` + `organizational_units` scope + wire into `Group`

Pure tree structure — ancestors/descendants via recursive CTE against `group_details.parent_id`, circular-dependency prevention, and the `organizational_unit` flag on `Group`. Explicitly excludes any membership/role propagation.

**Files:**
- Create: `app/models/groups/hierarchy.rb`
- Create: `app/models/groups/scopes/organizational_units.rb`
- Modify: `app/models/group.rb`
- Test: `spec/models/group_spec.rb`
- Test: `spec/factories/group_factory.rb` (add `:department` factory)

**Source:** `ae71c27c97c` (hierarchy + circular check), `31a2536f51e` (initial `has_details_table` wiring on `Group`), `35f2942e267` (`no_organizational_unit_mismatch`), final `uniqueness_of_name` rewrite from `2a2374f9be0`, `scopes :organizational_units` registration and `a7d3555db2c` (factory simplification). **Excludes**: `register_ldap_managed_check`/`ldap_managed?`/`synchronized_groups` (LDAP-sync hooks — omit entirely, not just stub, since there's no consumer without the deferred LDAP module) and the SCIM `find_with` hash reformatting (unrelated upstream noise).

**Interfaces:**
- Consumes: `HasDetailsTable::ClassMethods#has_details_table` (Task 1).
- Produces: `Group#organizational_unit?`, `Group#organizational_unit=`, `Group#parent`, `Group#parent_id` (all delegated to `detail`); `Group#children`, `#descendants`, `#self_and_descendants`, `#ancestors(order: nil)`, `#self_and_ancestors`, `#root`, `#root?`, `Group.in_tree_order` (sets `#hierarchy_depth` on each), `Group.organizational_units` / `Group.not_organizational_units` scopes. Task 3 (`User#departments`) and Task 7 (controller) depend on `Group.organizational_units`; Task 8 (ViewComponents) depend on `#ancestors`/`#children`/`#hierarchy_depth`.

- [ ] **Step 1: Write the failing spec additions**

Materialize the hierarchy-specific examples from `ae71c27c97c:spec/models/group_spec.rb` into this fork's existing `spec/models/group_spec.rb` (append; don't overwrite the file — the fork's copy has its own pre-existing examples). Run `git show ae71c27c97c:spec/models/group_spec.rb` to get the exact `describe` blocks for hierarchy/circular-dependency behavior and append them.

Also add the `:department` factory to the fork's existing `spec/factories/group_factory.rb`, inside the existing `factory :group` block:

```ruby
    factory :department do
      sequence(:lastname) { |n| "Department #{n}" }
      organizational_unit { true }
    end
```

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/models/group_spec.rb`
Expected: FAIL — `NoMethodError: undefined method 'organizational_unit?'` or similar.

- [ ] **Step 3: Write `Groups::Hierarchy`**

```ruby
# app/models/groups/hierarchy.rb
# frozen_string_literal: true

module Groups::Hierarchy
  extend ActiveSupport::Concern

  def children
    Group.where_detail(parent_id: id)
  end

  def descendants
    Group.where(id: descendant_ids)
  end

  def self_and_descendants
    Group.where(id: [id] + descendant_ids)
  end

  def ancestors(order: nil)
    ids = ancestor_ids
    scope = Group.where(id: ids)

    if order
      ordered_ids = order == :asc ? ids.reverse : ids
      order_sql = OpenProject::SqlSanitization.sanitize(
        "array_position(ARRAY[?]::bigint[], #{Group.table_name}.id)", ordered_ids
      )
      scope.order(Arel.sql(order_sql))
    else
      scope
    end
  end

  def self_and_ancestors
    Group.where(id: [id] + ancestor_ids)
  end

  def root
    root_id = ancestor_ids.last
    root_id ? Group.find(root_id) : self
  end

  def root?
    parent_id.nil?
  end

  class_methods do
    def in_tree_order
      all_groups = with_detail.order(:lastname).to_a
      children_by_parent = all_groups.group_by(&:parent_id)
      walk_tree(children_by_parent, nil, 0)
    end

    private

    def walk_tree(children_by_parent, parent_id, depth)
      (children_by_parent[parent_id] || []).flat_map do |group|
        group.hierarchy_depth = depth
        [group, *walk_tree(children_by_parent, group.id, depth + 1)]
      end
    end
  end

  private

  def descendant_ids
    return [] if new_record?

    sql = self.class.sanitize_sql([<<~SQL.squish, id])
      WITH RECURSIVE group_descendants(id) AS (
        SELECT gd.principal_id
        FROM group_details gd
        WHERE gd.parent_id = ?

        UNION ALL

        SELECT gd.principal_id
        FROM group_details gd
        INNER JOIN group_descendants ON gd.parent_id = group_descendants.id
      )
      SELECT id FROM group_descendants
    SQL

    self.class.connection.select_values(sql, "Group descendants")
  end

  def ancestor_ids
    return [] if new_record? || parent_id.nil?

    sql = self.class.sanitize_sql([<<~SQL.squish, id])
      WITH RECURSIVE group_ancestors(id) AS (
        SELECT gd.parent_id
        FROM group_details gd
        WHERE gd.principal_id = ? AND gd.parent_id IS NOT NULL

        UNION ALL

        SELECT gd.parent_id
        FROM group_details gd
        INNER JOIN group_ancestors ON gd.principal_id = group_ancestors.id
        WHERE gd.parent_id IS NOT NULL
      )
      SELECT id FROM group_ancestors
    SQL

    self.class.connection.select_values(sql, "Group ancestors")
  end
end
```

- [ ] **Step 4: Write the `organizational_units` scope module**

```ruby
# app/models/groups/scopes/organizational_units.rb
# frozen_string_literal: true

module Groups::Scopes
  module OrganizationalUnits
    extend ActiveSupport::Concern

    class_methods do
      def organizational_units
        where_detail(organizational_unit: true)
      end

      def not_organizational_units
        where_detail(organizational_unit: false)
      end
    end
  end
end
```

- [ ] **Step 5: Wire both into `Group`, add circular/mismatch checks, and rewrite `uniqueness_of_name`**

In `app/models/group.rb`, add right after `include ::Scopes::Scoped`:

```ruby
  include Groups::Hierarchy
  include Groups::Scopes::OrganizationalUnits

  attr_accessor :hierarchy_depth

  has_details_table(foreign_key: :principal_id) do
    belongs_to :parent, class_name: "Group", optional: true

    validates :parent, presence: true, if: -> { parent_id.present? }
  end

  validate :no_circular_parent, if: -> { parent_id.present? }
  validate :no_organizational_unit_mismatch, if: -> { parent_id.present? }
```

Update the existing `scopes` declaration to include the new scope (it's now defined by the included module rather than `Scopes::Scoped`, so just leave the existing `scopes :visible, :containing_user` line as-is — `organizational_units`/`not_organizational_units` come from the module included above, not the `scopes` macro).

Replace the existing private `uniqueness_of_name` method with:

```ruby
  def uniqueness_of_name
    scope = Group.where(lastname: name).where.not(id: id || 0)

    # Regular groups must be globally unique. Organizational units (departments) only need to be
    # unique among their siblings: LDAP directories routinely repeat the same OU name on different
    # branches (e.g. OU=Support under both IT and HR), so we scope uniqueness to the parent.
    scope = if organizational_unit?
              scope.where_detail(organizational_unit: true, parent_id:)
            else
              scope.where_detail(organizational_unit: false)
            end

    errors.add(:name, :taken) if scope.exists?
  end
```

Add these two private validation methods alongside it:

```ruby
  def no_circular_parent
    if parent_id == id || descendant_ids.include?(parent_id)
      errors.add(:parent_id, :circular_dependency)
    end
  end

  def no_organizational_unit_mismatch
    parent = self.class.find_by(id: parent_id)
    return unless parent

    if organizational_unit? != parent.organizational_unit?
      errors.add(:parent_id, :organizational_unit_mismatch)
    end
  end
```

(`descendant_ids` is private on `Groups::Hierarchy`, but callable here since `no_circular_parent` is an instance method of the same class that includes the module.)

- [ ] **Step 6: Add the two locale error messages**

In `config/locales/en.yml`, under `activerecord: errors: models: group: attributes: parent_id:` (create the nesting if it doesn't exist — check where `activerecord: errors: models:` currently lives in this fork's file before adding):

```yaml
              circular_dependency: "would create a circular group hierarchy."
              organizational_unit_mismatch: "must have the same organizational unit setting as the group."
```

And under `activerecord: attributes:` add (or extend the existing `group:`/add a new `group_detail:` key):

```yaml
      group:
        parent: "Parent group"
        organizational_unit: "Organizational unit"
      group_detail:
        parent: "Parent group"
        organizational_unit: "Organizational unit"
```

(Check this fork's `en.yml` for an existing `activerecord: attributes: group:` block first — if `identity_url: "Identity URL"` is already there, add `parent`/`organizational_unit` as siblings rather than duplicating the `group:` key.)

- [ ] **Step 7: Run migration for the index and run specs**

```ruby
# db/migrate/20260809120002_add_group_detail_index_for_ous.rb
# frozen_string_literal: true

class AddGroupDetailIndexForOus < ActiveRecord::Migration[8.1]
  def change
    add_index :group_details, :organizational_unit
  end
end
```

Run: `bundle exec rails db:migrate && bundle exec rspec spec/models/group_spec.rb`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add app/models/groups/hierarchy.rb app/models/groups/scopes/organizational_units.rb app/models/group.rb spec/models/group_spec.rb spec/factories/group_factory.rb config/locales/en.yml db/migrate/20260809120002_add_group_detail_index_for_ous.rb db/schema.rb db/structure.sql
git commit -m "feat(departments): add Group hierarchy and organizational_units scope"
```

---

### Task 3: Wire `Principal` and `User` for the single-department attribute

**Files:**
- Modify: `app/models/principal.rb`
- Modify: `app/models/user.rb`
- Test: `spec/models/user_spec.rb` (or wherever this fork keeps user-attribute specs)

**Source:** `principal.rb` — one line from `31a2536f51e`/`deb52888365` (`include HasDetailsTable`). `user.rb` — `5e3be5cbb8b` (final, eager-loadable form of the association; supersedes the simpler `35bcf97ee08` version — port straight to the final form, don't replay the intermediate `groups.merge(...)` version), plus its spec coverage from `02942beff52`.

**Interfaces:**
- Consumes: `Group.organizational_units` (Task 2).
- Produces: `User#departments` (ActiveRecord association, eager-loadable via `User.includes(:departments)`), `User#department` (returns the single `Group` or `nil`). Tasks 8, 11, 12 depend on `User#department`.

- [ ] **Step 1: Write the failing spec**

Add to this fork's user spec file:

```ruby
describe "#department" do
  subject { user.department }

  let(:user) { create(:user) }

  context "when the user belongs to no department" do
    it { is_expected.to be_nil }
  end

  context "when the user belongs to a department" do
    let(:department) { create(:department, members: [user]) }

    before { department }

    it { is_expected.to eq(department) }
  end

  context "when eager-loaded via includes" do
    let(:department) { create(:department, members: [user]) }

    before { department }

    it "does not issue additional queries" do
      loaded_user = User.includes(:departments).find(user.id)

      expect { loaded_user.department }.not_to exceed_query_limit(0)
    end
  end
end
```

(Adjust to this fork's existing matcher/helper conventions if `exceed_query_limit` isn't available — check `spec/support/` for the query-count helper this codebase already uses elsewhere, e.g. for other N+1 regression specs.)

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/models/user_spec.rb -e "#department"`
Expected: FAIL — `NoMethodError: undefined method 'department'`.

- [ ] **Step 3: Wire `Principal`**

In `app/models/principal.rb`, add right after `include ::Scopes::Scoped`:

```ruby
  include HasDetailsTable
```

- [ ] **Step 4: Wire `User`**

In `app/models/user.rb`, add near the other `has_many` declarations (after `extend DeprecatedAlias`, before `has_many :watches`):

```ruby
  # Join association backing #departments. The group_users lifecycle is already
  # managed by the `groups` HABTM above, so no :dependent option is declared here.
  has_many :group_users, inverse_of: :user # rubocop:disable Rails/HasManyOrHasOneDependent
  # A user belongs to at most one department (an organizational unit group).
  # Modeled as a has_many because Rails forbids a has_one :through a collection
  # (group memberships). Use #department for the single value, and eager-load
  # with User.includes(:departments) to avoid N+1 queries in user lists.
  has_many :departments,
           -> { Group.organizational_units },
           through: :group_users,
           source: :group
```

If `User` already declares `has_many :group_users` elsewhere (check first — some forks alias this via the `groups` HABTM join model directly), don't duplicate it; just add the `has_many :departments` association pointing at the existing join association's `source:`.

Add the accessor method near the other simple attribute readers (e.g. after `def anonymous?`):

```ruby
  # The single organizational unit (department) the user belongs to, if any.
  def department
    departments.first
  end
```

- [ ] **Step 5: Run the spec to verify it passes**

Run: `bundle exec rspec spec/models/user_spec.rb -e "#department"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/models/principal.rb app/models/user.rb spec/models/user_spec.rb
git commit -m "feat(departments): add User#department and #departments association"
```

---

### Task 4: Group contracts + API v3 representer/endpoint

Exposes `organizational_unit` (read-only after create) and `parent` (writable) through the existing Groups API, and permits them through the create/update contracts used by both the API and the admin controller (Task 7).

**Files:**
- Modify: `app/contracts/groups/base_contract.rb`
- Modify: `app/contracts/groups/create_contract.rb`
- Modify: `lib/api/v3/groups/group_representer.rb`
- Modify: `lib/api/v3/groups/groups_api.rb`
- Test: `spec/contracts/groups/update_contract_spec.rb`
- Test: `spec/requests/api/v3/groups/group_resource_spec.rb`

**Source:** `56ee2395a28` (initial `attribute :parent_id`/`:organizational_unit` on base contract), `710eac52ba3` (final split: `organizational_unit` moves to `create_contract` only — not writable on update — plus the API representer/endpoint changes). Port directly to the `710eac52ba3` end state. **Excludes**: `7f77064488a`/`010de7f457a` (LDAP-managed contract locks — no LDAP module in scope).

**Interfaces:**
- Consumes: `Group#organizational_unit?`/`#parent`/`#parent_id` (Task 2).
- Produces: `organizational_unit` and `parent_id` as writable/readable attributes through `Groups::BaseContract`/`Groups::CreateContract`, used by Task 5 (`validate_users_not_in_other_department`) and Task 7 (controller's `permitted_params.group`).

- [ ] **Step 1: Write the failing specs**

Append the `organizational_unit` writability example to `spec/contracts/groups/update_contract_spec.rb` (from `710eac52ba3`):

```ruby
describe "organizational_unit" do
  it "is not a writable attribute" do
    expect(contract.writable_attributes).not_to include("organizational_unit")
  end
end
```

Append the API examples to `spec/requests/api/v3/groups/group_resource_spec.rb` (materialize the relevant `context` blocks from `git show 710eac52ba3:spec/requests/api/v3/groups/group_resource_spec.rb` — the "regular group"/"department with a parent" GET examples, the "creating a department" POST example, and the "department properties" PATCH `describe` block).

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/contracts/groups/update_contract_spec.rb spec/requests/api/v3/groups/group_resource_spec.rb`
Expected: FAIL — `organizational_unit`/`parent` not recognized as attributes, or missing JSON paths.

- [ ] **Step 3: Update the contracts**

In `app/contracts/groups/base_contract.rb`, add alongside the existing `attribute :name` / `attribute :lastname`:

```ruby
    attribute :parent_id
```

In `app/contracts/groups/create_contract.rb`, add alongside `attribute :type`:

```ruby
    attribute :organizational_unit
```

(`organizational_unit` is intentionally **not** added to `base_contract.rb` — it's settable only at creation, per `CreateContract`, and immutable afterward.)

- [ ] **Step 4: Update the API representer and endpoint**

In `lib/api/v3/groups/group_representer.rb`, add:

```ruby
        property :organizational_unit,
                 render_nil: true

        associated_resource :parent,
                            v3_path: :group,
                            representer: GroupRepresenter,
                            skip_render: ->(*) { represented.parent_id.nil? }
```

In `lib/api/v3/groups/groups_api.rb`, change the `after_validation` block's lookup to eager-load the detail:

```ruby
            after_validation do
              @group = Group.visible(current_user).includes(:group_detail).find(params[:id])
            end
```

- [ ] **Step 5: Run the specs to verify they pass**

Run: `bundle exec rspec spec/contracts/groups/update_contract_spec.rb spec/requests/api/v3/groups/group_resource_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/contracts/groups/base_contract.rb app/contracts/groups/create_contract.rb lib/api/v3/groups/group_representer.rb lib/api/v3/groups/groups_api.rb spec/contracts/groups/update_contract_spec.rb spec/requests/api/v3/groups/group_resource_spec.rb
git commit -m "feat(departments): expose organizational_unit and parent through Groups API"
```

---

### Task 5: Single-department-membership invariant

Enforces "a user belongs to at most one department" at both the contract layer (in-memory adds) and the service layer (the raw-SQL bulk-add path), since `Groups::AddUsersService` bypasses the contract for its bulk insert.

**Files:**
- Modify: `app/contracts/groups/base_contract.rb`
- Modify: `app/services/groups/add_users_service.rb`
- Modify: `config/locales/en.yml`
- Test: `spec/contracts/groups/update_contract_spec.rb`
- Test: `spec/services/groups/add_users_service_integration_spec.rb`
- Test: `spec/requests/api/v3/groups/group_resource_spec.rb`

**Source:** `50104b49009` in full — this commit is entirely about the single-department invariant with **no** propagation code in its diff (verified: its `add_users_service.rb` hunk only touches `persist`, not `after_perform`). Safe to port as-is.

**Interfaces:**
- Consumes: `Group.organizational_units` (Task 2).
- Produces: `Groups::BaseContract#validate_users_not_in_other_department` (contract-layer check), `Groups::AddUsersService#validate_department_membership` (service-layer check for the raw-SQL path). Task 6 (`Departments::AddUserService`) relies on this invariant already being enforced lower in the stack (it also has its own move-between-departments UX on top).

- [ ] **Step 1: Write the failing specs**

Materialize the "department user uniqueness validation" `describe` block into `spec/contracts/groups/update_contract_spec.rb` and the "department" contexts into `spec/services/groups/add_users_service_integration_spec.rb` and `spec/requests/api/v3/groups/group_resource_spec.rb`, from `git show 50104b49009` (shown in full above in the research — reproduce those exact `context`/`it` blocks).

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/contracts/groups/update_contract_spec.rb spec/services/groups/add_users_service_integration_spec.rb`
Expected: FAIL — no validation error raised when a user is added to a second department.

- [ ] **Step 3: Add the contract validation**

In `app/contracts/groups/base_contract.rb`, add the validation registration alongside the existing `validate :validate_unique_users`:

```ruby
    validate :validate_users_not_in_other_department
```

And add the private methods:

```ruby
    def validate_users_not_in_other_department
      return unless model.organizational_unit?

      new_user_ids = model.group_users.select(&:new_record?).map(&:user_id)
      return if new_user_ids.empty?

      users_already_in_departments(new_user_ids).each do |user_id, department_id|
        errors.add(:group_users, :user_already_in_department, user_id:, department_id:)
      end
    end

    def users_already_in_departments(user_ids)
      GroupUser
        .joins(:group)
        .merge(Group.organizational_units)
        .where(user_id: user_ids)
        .where.not(group_id: model.id)
        .pluck(:user_id, :group_id)
    end
```

- [ ] **Step 4: Add the service-layer guard**

In `app/services/groups/add_users_service.rb`, in the `persist` method, add a guard at the top (before the existing SQL insert):

```ruby
    def persist(call)
      validate_department_membership(call)
      return call unless call.success?

      sql_query = ::OpenProject::SqlSanitization
                    .sanitize add_to_group,
                              group_id: model.id,
                              user_ids: params[:ids]
      execute_query(sql_query)

      call
    end

    # The same validation exists in Groups::BaseContract, but it relies on in-memory
    # group_users that are new_record?. This service inserts group_users via raw SQL,
    # so the contract never sees them. We duplicate the check here against the params directly.
    def validate_department_membership(call)
      return unless model.organizational_unit?

      conflicts = users_already_in_departments(params[:ids])

      conflicts.each do |user_id, department_id|
        call.errors.add(:group_users, :user_already_in_department, user_id:, department_id:)
      end

      call.success = false if conflicts.any?
    end

    def users_already_in_departments(user_ids)
      GroupUser
        .joins(:group)
        .merge(Group.organizational_units)
        .where(user_id: user_ids)
        .where.not(group_id: model.id)
        .pluck(:user_id, :group_id)
    end
```

Leave `after_perform` and everything else in this file untouched — do not add the `model.ancestors.each { create_inherited_roles(ancestor) }` loop; that's the propagation behavior this plan deliberately excludes.

- [ ] **Step 5: Add locale strings**

In `config/locales/en.yml`, under `activerecord: errors: messages:` add:

```yaml
        user_already_in_department: "User %{user_id} is already a member of department %{department_id}."
```

Under `activerecord: attributes: group:` add:

```yaml
        group_users: "Group users"
```

- [ ] **Step 6: Run the specs to verify they pass**

Run: `bundle exec rspec spec/contracts/groups/update_contract_spec.rb spec/services/groups/add_users_service_integration_spec.rb spec/requests/api/v3/groups/group_resource_spec.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/contracts/groups/base_contract.rb app/services/groups/add_users_service.rb config/locales/en.yml spec/contracts/groups/update_contract_spec.rb spec/services/groups/add_users_service_integration_spec.rb spec/requests/api/v3/groups/group_resource_spec.rb
git commit -m "feat(departments): enforce one-department-per-user invariant"
```

---

### Task 6: `Departments::AddUserService` and `Departments::RemoveUserService`

Admin-UI-facing services (used by the controller in Task 7 and the user-edit form in Task 12) that wrap the single-user add/remove flow, including the "user is already in another department — move them?" UX.

**Files:**
- Create: `app/services/departments/add_user_service.rb`
- Create: `app/services/departments/remove_user_service.rb`
- Test: `spec/services/departments/add_user_service_spec.rb`
- Test: `spec/services/departments/remove_user_service_spec.rb`

**Source:** materialize directly from `d7bc648642c:app/services/departments/add_user_service.rb`, `d7bc648642c:app/services/departments/remove_user_service.rb`, `d7bc648642c:spec/services/departments/add_user_service_spec.rb`, `d7bc648642c:spec/services/departments/remove_user_service_spec.rb` — these are new, self-contained files verified to contain no propagation logic. They do reference `existing_department.ldap_managed?` / `model.ldap_managed?`; since Task 2 deliberately omits `Group#ldap_managed?` (no LDAP module to register a check), **strip those two conditional branches** per the adaptation below rather than porting them as-is.

**Interfaces:**
- Consumes: `Group.organizational_units` (Task 2), `Groups::UpdateService` (pre-existing in this fork, unmodified — verified it needs no changes for `add_user_ids:`/`remove_user_ids:` params, which it already supports generically for any group).
- Produces: `Departments::AddUserService.new(department, user:).call(user_id:, remove_from_previous_department:)`, `Departments::RemoveUserService.new(department, user:).call(user_id:)`. Task 7 (controller `add_user`/`remove_user` actions) and Task 12 (user-edit-form persistence) call these directly.

- [ ] **Step 1: Write the failing specs**

Materialize both spec files verbatim:

```bash
git show d7bc648642c:spec/services/departments/add_user_service_spec.rb > spec/services/departments/add_user_service_spec.rb
git show d7bc648642c:spec/services/departments/remove_user_service_spec.rb > spec/services/departments/remove_user_service_spec.rb
```

Check both files for any `ldap_managed?`/"managed" example groups (`context "when the department is LDAP-managed"` or similar) and delete those specific `context` blocks — they test behavior this plan is intentionally not porting.

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/services/departments/`
Expected: FAIL — `uninitialized constant Departments::AddUserService`.

- [ ] **Step 3: Write `Departments::AddUserService`**

```ruby
# app/services/departments/add_user_service.rb
# frozen_string_literal: true

module Departments
  class AddUserService < ::BaseServices::BaseContracted
    def initialize(department, user:, contract_class: AdminOnlyContract)
      self.model = department
      super(user:, contract_class:)
    end

    private

    def persist(call)
      user_id = params[:user_id].to_i
      existing_department = find_existing_department(user_id)

      if existing_department.nil? || existing_department.id == model.id
        add_user_to_department(model, user_id, call)
      else
        handle_existing_membership(existing_department, user_id, call)
      end

      call
    end

    def handle_existing_membership(existing_department, user_id, call)
      if params[:remove_from_previous_department]
        move_user(from: existing_department, to: model, user_id:, call:)
      else
        call.success = false
        call.result = existing_department
      end
    end

    def find_existing_department(user_id)
      GroupUser
        .joins(:group)
        .merge(Group.organizational_units)
        .where(user_id:)
        .first
        &.group
    end

    def add_user_to_department(department, user_id, call)
      result = Groups::UpdateService
        .new(user:, model: department)
        .call(add_user_ids: [user_id])

      call.add_dependent!(result)
    end

    def remove_user_from_department(department, user_id, call)
      result = Groups::UpdateService
        .new(user:, model: department)
        .call(remove_user_ids: [user_id])

      call.add_dependent!(result)
    end

    def move_user(from:, to:, user_id:, call:)
      Group.transaction do
        remove_user_from_department(from, user_id, call)
        raise ActiveRecord::Rollback unless call.success?

        add_user_to_department(to, user_id, call)
        raise ActiveRecord::Rollback unless call.success?
      end
    end
  end
end
```

(Note: the `handle_existing_membership` here is simplified from upstream — the `existing_department.ldap_managed?` branch and `reject_move_from_managed` method are omitted since no LDAP module can ever set that true in this fork's current scope.)

- [ ] **Step 4: Write `Departments::RemoveUserService`**

```ruby
# app/services/departments/remove_user_service.rb
# frozen_string_literal: true

module Departments
  class RemoveUserService < ::BaseServices::BaseContracted
    def initialize(department, user:, contract_class: AdminOnlyContract)
      self.model = department
      super(user:, contract_class:)
    end

    private

    def persist(call)
      result = Groups::UpdateService
        .new(user:, model:)
        .call(remove_user_ids: [params[:user_id].to_i])

      call.add_dependent!(result)
      call
    end
  end
end
```

(Simplified from upstream by dropping the `model.ldap_managed?` early-return branch, for the same reason as Step 3.)

- [ ] **Step 5: Run the specs to verify they pass**

Run: `bundle exec rspec spec/services/departments/`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/services/departments/add_user_service.rb app/services/departments/remove_user_service.rb spec/services/departments/add_user_service_spec.rb spec/services/departments/remove_user_service_spec.rb
git commit -m "feat(departments): add Departments::AddUserService and RemoveUserService"
```

---

### Task 7: `Admin::DepartmentsController` + routes + menu

**Files:**
- Create: `app/controllers/admin/departments_controller.rb`
- Modify: `config/routes.rb`
- Modify: `config/initializers/menus.rb`
- Test: `spec/controllers/admin/departments_controller_spec.rb`

**Source:** controller verbatim from `d7bc648642c:app/controllers/admin/departments_controller.rb` (already fully verified above — no propagation/LDAP calls beyond the harmless `ldap_managed?`-free logic already reflected in Task 6's simplified services; the controller itself never calls `ldap_managed?`). Routes/menu: final state from `df949c1ac20` + `4664b62bf3b` (the feature-flag add/removal nets out to the unconditional final form shown below — apply that final form directly).

**Interfaces:**
- Consumes: `Group.organizational_units`/`.with_detail` (Task 2), `Groups::UpdateService`/`Groups::CreateService`/`Groups::DeleteService` (pre-existing), `Departments::AddUserService` (Task 6), Task 8's `Admin::Departments::*Component` classes (referenced but not yet created — this task's controller spec will need Task 8's components to fully pass; see Step 6 note).
- Produces: routes `admin_departments_path`, `admin_department_path`, etc.; menu entry under Administration → Users and permissions.

- [ ] **Step 1: Write the failing spec**

```bash
git show d7bc648642c:spec/controllers/admin/departments_controller_spec.rb > spec/controllers/admin/departments_controller_spec.rb
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/controllers/admin/departments_controller_spec.rb`
Expected: FAIL — `uninitialized constant Admin::DepartmentsController`.

- [ ] **Step 3: Write the controller**

```ruby
# app/controllers/admin/departments_controller.rb
# frozen_string_literal: true

module Admin
  class DepartmentsController < ::ApplicationController
    include OpTurbo::ComponentStream
    include GroupsHelper

    layout :admin_or_frame_layout

    menu_item :departments

    before_action :require_admin
    before_action :find_group,
                  only: %i[show edit new_user add_user remove_user update destroy change_parent_dialog change_parent
                           create_memberships edit_membership destroy_membership]

    def index
      @groups = Group.with_detail.organizational_units.visible.order(:lastname)
    end

    def new_user
      @groups = Group.with_detail.organizational_units.visible.order(:lastname)
      @add_user = true
      render action: :index
    end

    def add_user # rubocop:disable Metrics/AbcSize
      result = ::Departments::AddUserService
        .new(@group, user: current_user)
        .call(
          user_id: params[:user_id],
          remove_from_previous_department: params[:remove_from_previous_department] == "true"
        )

      if result.success?
        flash[:notice] = I18n.t("departments.flash.user_added")
        redirect_to admin_department_path(@group), status: :see_other
      elsif result.result.is_a?(Group)
        respond_with_dialog(
          Admin::Departments::MoveUserDialogComponent.new(
            user: User.find(params[:user_id]),
            from_department: result.result,
            to_department: @group
          )
        )
      else
        flash[:error] = result.errors.full_messages.join("\n")
        redirect_to admin_department_path(@group), status: :see_other
      end
    end

    def new_department
      @group = Group.visible.with_detail.organizational_units.find(params[:parent_id]) if params[:parent_id].present?
      @groups = Group.with_detail.organizational_units.visible.order(:lastname)
      @add_subgroup = true
      render action: :index
    end

    def add_department
      service_call = ::Groups::CreateService
        .new(user: current_user)
        .call(permitted_params.group.merge(organizational_unit: true))

      respond_department_created(service_call)
    end

    def remove_user
      service_call = ::Groups::UpdateService
        .new(user: current_user, model: @group)
        .call(remove_user_ids: [params[:user_id]])

      if service_call.success?
        flash[:notice] = I18n.t("departments.flash.user_removed")
      else
        flash[:error] = service_call.errors.full_messages.join("\n")
      end
      redirect_to admin_department_path(@group), status: :see_other
    end

    def change_parent_dialog
      departments = Group.with_detail.organizational_units.visible.order(:lastname)
      respond_with_dialog(
        Admin::Departments::ChangeParentDialogComponent.new(department: @group, departments:)
      )
    end

    def change_parent
      new_parent_id = parse_new_parent_id(params[:new_parent_id])
      service_call = ::Groups::UpdateService
        .new(user: current_user, model: @group)
        .call(parent_id: new_parent_id)

      respond_parent_changed(service_call)
    end

    def edit_organization_name
      replace_via_turbo_stream(component: Admin::Departments::OrganizationNameFormComponent.new)
      respond_with_turbo_streams
    end

    def cancel_edit_organization_name
      replace_via_turbo_stream(component: Admin::Departments::OrganizationNameComponent.new)
      respond_with_turbo_streams
    end

    def update_organization_name
      ::Settings::UpdateService
        .new(user: current_user)
        .call(organization_name: params[:organization_name])

      replace_via_turbo_stream(component: Admin::Departments::OrganizationNameComponent.new)
      respond_with_turbo_streams
    end

    def show
      @groups = Group.with_detail.organizational_units.visible.order(:lastname)
      render action: :index
    end

    def edit; end

    def update
      service_call = ::Groups::UpdateService
                     .new(user: current_user, model: @group)
                     .call(permitted_params.group)

      if service_call.success?
        flash[:notice] = I18n.t(:notice_successful_update)
        redirect_to edit_admin_department_path(@group), status: :see_other
      else
        render action: :edit, status: :unprocessable_entity
      end
    end

    def destroy
      redirect_target = @group.parent

      ::Groups::DeleteService
        .new(user: current_user, model: @group)
        .call

      flash[:info] = I18n.t(:notice_deletion_scheduled)
      redirect_to redirect_target ? admin_department_path(redirect_target) : admin_departments_path, status: :see_other
    end

    def create_memberships
      membership_params = permitted_params.group_membership[:membership]

      service_call = ::Members::CreateService
                     .new(user: current_user)
                     .call(membership_params.merge(principal: @group))

      respond_membership_altered(service_call)
    end

    def edit_membership
      membership_params = permitted_params.group_membership

      @membership = Member.find(membership_params[:membership_id])

      service_call = ::Members::UpdateService
                     .new(model: @membership, user: current_user)
                     .call(membership_params[:membership])

      respond_membership_altered(service_call)
    end

    def destroy_membership
      member = Member.find(params[:membership_id])
      ::Members::DeleteService
        .new(model: member, user: current_user)
        .call

      flash[:notice] = I18n.t(:notice_successful_delete)
      redirect_to edit_admin_department_path(@group, tab: redirected_to_tab(member)), status: :see_other
    end

    private

    def admin_or_frame_layout
      return "turbo_rails/frame" if turbo_frame_request?

      "admin"
    end

    def redirect_target_for(department)
      department.parent || department
    end

    def find_group
      @group = Group.visible.organizational_units.includes(:members, :users, :group_detail).find(params[:id])
    end

    def parse_new_parent_id(input)
      return nil if input.blank?

      value = MultiJson.load(Array(input).first, symbolize_keys: true)[:value]
      value.presence
    end

    def respond_parent_changed(service_call)
      if service_call.success?
        flash[:notice] = I18n.t(:notice_successful_update)
        redirect_to admin_department_path(service_call.result.parent || service_call.result), status: :see_other
      else
        flash[:error] = service_call.errors.full_messages.join("\n")
        redirect_to admin_department_path(@group), status: :see_other
      end
    end

    def respond_department_created(service_call)
      if service_call.success?
        flash[:notice] = I18n.t("departments.flash.department_created")
        redirect_to admin_department_path(redirect_target_for(service_call.result)), status: :see_other
      else
        flash[:error] = service_call.errors.full_messages.join("\n")
        redirect_back_or_to(admin_departments_path)
      end
    end

    def respond_membership_altered(service_call)
      if service_call.success?
        flash[:notice] = I18n.t(:notice_successful_update)
      else
        flash[:error] = service_call.errors.full_messages.join("\n")
      end

      redirect_to edit_admin_department_path(@group, tab: redirected_to_tab(service_call.result))
    end

    def redirected_to_tab(membership)
      if membership.project
        "memberships"
      else
        "global_roles"
      end
    end
  end
end
```

- [ ] **Step 4: Wire the routes**

In `config/routes.rb`, inside the `namespace :admin do ... end` block, alongside the existing `resources :groups` (find that block — this fork already has one), add:

```ruby
    resources :departments,
              only: %i[index show edit update destroy] do
      member do
        get :new_user
        post :add_user
        delete "remove_user/:user_id" => "departments#remove_user", as: :remove_user
        get :change_parent, action: :change_parent_dialog
        post :change_parent

        # old routes for old group style management, might remove when new interface
        patch "/memberships:membership_id" => "departments#edit_membership", as: "membership_of"
        put "/memberships:membership_id" => "departments#edit_membership"
        delete "/memberships:membership_id" => "departments#destroy_membership"
        post "/memberships" => "departments#create_memberships", as: "memberships_of"
      end

      collection do
        get :new_department
        post :add_department
        get :edit_organization_name
        patch :cancel_edit_organization_name
        patch :update_organization_name
      end
    end
```

- [ ] **Step 5: Wire the admin menu**

In `config/initializers/menus.rb`, inside `Redmine::MenuManager.map :admin_menu do |menu|`, alongside the existing `menu.push :groups, ...`, add:

```ruby
  menu.push :departments,
            { controller: "/admin/departments" },
            if: ->(_) { User.current.admin? },
            caption: :label_departments,
            parent: :users_and_permissions
```

Add the locale key in `config/locales/en.yml` top-level `en:` block (alongside other `label_*` keys):

```yaml
  label_departments: "Organization"
```

- [ ] **Step 6: Run the spec**

Run: `bundle exec rspec spec/controllers/admin/departments_controller_spec.rb`
Expected: many examples will fail until Task 8's ViewComponents exist (the controller renders them for dialog/turbo-stream responses) — that's expected at this point. Confirm the failures are all `uninitialized constant Admin::Departments::*Component` (referencing components, not controller logic errors) before proceeding; that confirms this task's own code is correct and the remaining failures belong to Task 8.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/admin/departments_controller.rb config/routes.rb config/initializers/menus.rb config/locales/en.yml spec/controllers/admin/departments_controller_spec.rb
git commit -m "feat(departments): add Admin::DepartmentsController, routes, and menu entry"
```

---

### Task 8: Admin::Departments ViewComponents and views

**Files:**
- Create: all 12 files under `app/components/admin/departments/` (9 components × `.rb` + 4 with matching `.html.erb`, per the manifest below)
- Create: 6 files under `app/views/admin/departments/`
- Test: `spec/features/admin/departments_spec.rb`
- Test: `spec/support/pages/admin/departments.rb`

**Source:** all files below are new, self-contained (verified above: no calls into `Groups::CreateInheritedRolesService`/propagation methods; `ancestors`/`children`/`hierarchy_depth` calls are pure tree display; `ldap_managed?` calls degrade harmlessly since Task 2 didn't define that method — **see adaptation note below**). Materialize each verbatim from `d7bc648642c`:

| File | Lines |
|---|---|
| `app/components/admin/departments/page_header_component.rb` | 37 |
| `app/components/admin/departments/page_header_component.html.erb` | 44 |
| `app/components/admin/departments/organization_name_component.rb` | 47 |
| `app/components/admin/departments/organization_name_component.html.erb` | 54 |
| `app/components/admin/departments/organization_name_form_component.rb` | 45 |
| `app/components/admin/departments/organization_name_form_component.html.erb` | 68 |
| `app/components/admin/departments/hierarchy_layout_component.rb` | 115 |
| `app/components/admin/departments/hierarchy_layout_component.html.erb` | 88 |
| `app/components/admin/departments/blankslate_component.rb` | 54 |
| `app/components/admin/departments/detail_component.rb` | 92 |
| `app/components/admin/departments/detail_component.html.erb` | 98 |
| `app/components/admin/departments/detail_blankslate_component.rb` | 62 |
| `app/components/admin/departments/department_row_component.rb` | 129 |
| `app/components/admin/departments/user_row_component.rb` | 77 |
| `app/components/admin/departments/add_department_component.rb` | 46 |
| `app/components/admin/departments/add_department_component.html.erb` | 75 |
| `app/components/admin/departments/add_user_component.rb` | 60 |
| `app/components/admin/departments/add_user_component.html.erb` | 77 |
| `app/components/admin/departments/change_parent_dialog_component.rb` | 109 |
| `app/components/admin/departments/change_parent_dialog_component.html.erb` | 66 |
| `app/components/admin/departments/move_user_dialog_component.rb` | 49 |
| `app/components/admin/departments/move_user_dialog_component.html.erb` | 81 |
| `app/views/admin/departments/index.html.erb` | 3 |
| `app/views/admin/departments/edit.html.erb` | 36 |
| `app/views/admin/departments/_general.html.erb` | 34 |
| `app/views/admin/departments/_memberships.html.erb` | 165 |
| `app/views/admin/departments/new_department.html.erb` | 8 |
| `app/views/admin/departments/new_user.html.erb` | 8 |

**⚠️ Required adaptation — `ldap_managed?` references:** `change_parent_dialog_component.rb`, `department_row_component.rb`, `detail_blankslate_component.rb`, `detail_component.html.erb`, `hierarchy_layout_component.html.erb`, `move_user_dialog_component.html.erb`, and `user_row_component.rb` each call `department.ldap_managed?` (or `.ldap_managed?` on a related group) to toggle "managed by LDAP, read-only" UI treatment. Since Task 2 intentionally does not define `Group#ldap_managed?` (no LDAP module registers a check in this fork), calling it would raise `NoMethodError`. For each of these files, after materializing, replace every `<something>.ldap_managed?` call site with a literal `false` (e.g. `department.ldap_managed?` → `false`) rather than deleting the surrounding conditional — this keeps the component's structure identical to upstream (so future syncs stay easy) while making the "managed" branch permanently dead code until/unless the deferred LDAP module (see spec's Out of Scope section) is ported later.

**Interfaces:**
- Consumes: `Group#ancestors`, `#children`, `#hierarchy_depth`, `.organizational_units`, `.with_detail` (Task 2); `Admin::DepartmentsController`'s actions (Task 7) render/redirect to these; `Departments::AddUserService`'s `MoveUserDialogComponent` usage (Task 7 Step 3, `add_user` action).
- Produces: nothing consumed by later tasks — this is a leaf UI layer.

- [ ] **Step 1: Write the failing feature spec and page object**

```bash
git show d7bc648642c:spec/support/pages/admin/departments.rb > spec/support/pages/admin/departments.rb
git show d7bc648642c:spec/features/admin/departments_spec.rb > spec/features/admin/departments_spec.rb
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/features/admin/departments_spec.rb`
Expected: FAIL — missing view/component templates.

- [ ] **Step 3: Materialize every component and view file**

For each row in the manifest table above:

```bash
git show d7bc648642c:<path> > <path>
```

(37 files total: 21 component files + 6 test-support files already handled in Step 1 + the remainder from the view list. Create parent directories as needed — `mkdir -p app/components/admin/departments app/views/admin/departments`.)

- [ ] **Step 4: Apply the `ldap_managed?` adaptation**

For each of the 7 files listed in the adaptation note above, open it and replace every `.ldap_managed?` call with the literal `false`. Grep to confirm none remain:

```bash
grep -rn "ldap_managed" app/components/admin/departments/ app/views/admin/departments/
```

Expected: no matches.

- [ ] **Step 5: Run rubocop and erb_lint**

Run: `bundle exec rubocop app/components/admin/departments/ app/controllers/admin/departments_controller.rb`
Run: `erb_lint app/components/admin/departments/*.html.erb app/views/admin/departments/*.html.erb`
Fix any offenses (expect mostly none, since the source already passed upstream's own lint; the `false` literal substitutions are the most likely new offense source, e.g. an unused local variable left over from a removed conditional branch).

- [ ] **Step 6: Run the specs to verify they pass**

Run: `bundle exec rspec spec/features/admin/departments_spec.rb spec/controllers/admin/departments_controller_spec.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/components/admin/departments/ app/views/admin/departments/ spec/features/admin/departments_spec.rb spec/support/pages/admin/departments.rb
git commit -m "feat(departments): add admin ViewComponents and views for department management"
```

---

### Task 9: Departments locale block

**Files:**
- Modify: `config/locales/en.yml`

**Source:** `48b2ab7bcc8` (flash keys), `e74ae25d8e2` (label + description), plus the full `departments:` top-level block accumulated across the admin-UI commits (already assembled in full during research — reproduced complete below).

**Interfaces:**
- Consumes: nothing.
- Produces: all `departments.*` and `label_departments*` I18n keys used by Tasks 7–8 (already referenced there) and Task 12.

- [ ] **Step 1: Add the top-level `departments:` block**

In `config/locales/en.yml`, add a new top-level key (alphabetically near other short top-level namespaces, e.g. near `data_source:`/`errors:` — check this fork's existing ordering convention):

```yaml
  departments:
    edit: "Edit department"
    add_user: "Add user"
    add_department: "Add department"
    blankslate:
      heading: "Your organization has no departments"
      description: >
        Start by adding departments or users to the organization. Each department can be used to create
        a hierarchy below it, to navigate and create sub-department inside a hierarchy click on the created item.
      add_button: "Add"
    detail_blankslate:
      add_button: "Add"
      description: "Add departments or users to create sub-items inside another one."
      heading: "This department doesn't have any hierarchy level below"
    add_department_form:
      name_label: "Department name"
      name_placeholder: "Enter department name"
    move_user_dialog:
      title: "User already in a department"
      heading: "Move user to this department?"
      description: "%{user} is currently a member of %{from_department}. Moving them will remove them from that department."
      confirm: "Move user"
    context_menu:
      add_sub_department: "Add sub-department"
      add_user: "Add user"
    flash:
      user_added: "User was successfully added to the department."
      user_removed: "User was successfully removed from the department."
      department_created: "Department was successfully created."
    errors:
      move_user_failed: "Failed to move user between departments."
```

(Omitted from upstream's version: the `detail_blankslate.managed_*` and `move_user_dialog.managed_*` keys, which only render on the dead `false`-literal LDAP-managed branches per Task 8's adaptation — no harm in leaving them out since nothing references them anymore.)

- [ ] **Step 2: Add the `label_departments` keys**

In the top-level `en:` block, alongside other `label_*` keys:

```yaml
  label_departments: "Organization"
  label_departments_description_html: >
    Define your company's structure by creating departments and sub-departments in a hierarchical way. This allows you
    to reflect reporting lines and maintain a clear, structured overview of your organization within OpenProject.
```

(Omit upstream's trailing sentence about "LDAP group synchronisation" — that references the out-of-scope sync module.)

- [ ] **Step 3: Run a lint check on the YAML**

Run: `bundle exec i18n-tasks health` (or this fork's equivalent locale-lint rake task — check `package.json`/`Rakefile` for the exact command used elsewhere in this repo) to confirm no duplicate keys or missing-translation warnings were introduced.

- [ ] **Step 4: Commit**

```bash
git add config/locales/en.yml
git commit -m "feat(departments): add departments locale strings"
```

---

### Task 10: Demo data seeder

**Files:**
- Create: `app/seeders/demo_data/department_seeder.rb`
- Test: `spec/seeders/demo_data/department_seeder_spec.rb`

**Source:** materialize verbatim from `d7bc648642c:app/seeders/demo_data/department_seeder.rb` and `d7bc648642c:spec/seeders/demo_data/department_seeder_spec.rb` (`ef0686b427e`).

**Interfaces:**
- Consumes: `Groups::CreateService`/`Group.organizational_units` (Task 2), `Departments::AddUserService` (Task 6).
- Produces: nothing consumed elsewhere — leaf, dev/demo-only.

- [ ] **Step 1: Write the failing spec**

```bash
git show d7bc648642c:spec/seeders/demo_data/department_seeder_spec.rb > spec/seeders/demo_data/department_seeder_spec.rb
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/seeders/demo_data/department_seeder_spec.rb`
Expected: FAIL — `uninitialized constant DemoData::DepartmentSeeder`.

- [ ] **Step 3: Write the seeder**

```bash
git show d7bc648642c:app/seeders/demo_data/department_seeder.rb > app/seeders/demo_data/department_seeder.rb
```

Check whether this fork registers demo seeders in a central list (e.g. `config/initializers/seeders.rb` or `Gemfile`-adjacent `BasicData`/`DemoData` seeder array) and check `341ce9db4d7` (the seeder-registration merge commit) for that wiring — add the equivalent registration line for this fork's seeder-list mechanism if one exists.

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bundle exec rspec spec/seeders/demo_data/department_seeder_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/seeders/demo_data/department_seeder.rb spec/seeders/demo_data/department_seeder_spec.rb
git commit -m "feat(departments): add demo data seeder"
```

---

### Task 11: User profile attribute (briefcase icon) + hover card

**Files:**
- Modify: `app/components/users/profile/attributes_section_component.html.erb`
- Modify: `app/components/users/profile/section_attribute.rb`
- Modify: `app/components/users/profile/section_attributes.rb`
- Modify: `app/components/users/hover_card_component.html.erb`
- Modify: `app/models/user_custom_field_section.rb` (register `department` as a built-in attribute)
- Modify: `config/locales/en.yml`
- Create: `db/migrate/20260809120003_add_department_to_default_user_custom_field_section.rb`
- Test: existing specs for these components (extend, don't replace — check `spec/components/users/` for the fork's existing coverage)

**Source:** `1dd188e2c9a` (briefcase icon, profile section), `ecd2f5d874e` (hover card), `35bcf97ee08` (built-in attribute registration + locale label; the `#department` method changes from this commit are superseded by Task 3's final form — only take the `BUILT_IN_ATTRIBUTES`/locale parts here), `6de2181af41` (backfill migration).

**Interfaces:**
- Consumes: `User#department` (Task 3).
- Produces: nothing consumed elsewhere — leaf UI.

- [ ] **Step 1: Write/extend the failing specs**

Check this fork's existing specs for `Users::Profile::SectionAttributes` and `Users::HoverCardComponent` (or equivalent) and add an example asserting a user with a department shows the department name with a briefcase icon (profile) and in the hover card row. Base the assertions on the upstream examples if this fork has direct equivalents — search `spec/components/users/` first.

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/components/users/ -e department`
Expected: FAIL — department not rendered.

- [ ] **Step 3: Add the icon support to `SectionAttribute`**

In `app/components/users/profile/section_attribute.rb`:

```ruby
      attr_reader :label, :value, :icon

      def initialize(label:, value:, icon: nil)
        @label = label
        @value = value
        @icon = icon
      end
```

In `app/components/users/profile/section_attributes.rb`, in the method building a `SectionAttribute` for a built-in key:

```ruby
        SectionAttribute.new(label: User.human_attribute_name(key), value:, icon: built_in_icon(key))
      end

      def built_in_icon(key)
        :briefcase if key == "department"
      end
```

In `app/components/users/profile/attributes_section_component.html.erb`, in the row-rendering block, add an `elsif attribute.icon` branch before the plain `else`:

```erb
          elsif attribute.icon
            flex_layout(align_items: :center) do |value_row|
              value_row.with_column(mr: 1) { render(Primer::Beta::Octicon.new(icon: attribute.icon, color: :muted)) }
              value_row.with_column { attribute.value }
            end
```

- [ ] **Step 4: Add the hover card row**

In `app/components/users/hover_card_component.html.erb`, add a new row (placed to match upstream's position among the other rows):

```erb
    if @user.department
      flex.with_row do
        flex_layout(classes: "op-user-hover-card--department") do |f|
          f.with_column do
            render(Primer::Beta::Octicon.new(icon: :briefcase, color: :muted))
          end

          f.with_column do
            render(Primer::Beta::Text.new(data: { test_selector: "user-hover-card-department" })) do
              @user.department.name
            end
          end
        end
      end
    end
```

- [ ] **Step 5: Register `department` as a built-in user attribute**

In `app/models/user_custom_field_section.rb`, add `"department"` to `BUILT_IN_ATTRIBUTES`:

```ruby
  BUILT_IN_ATTRIBUTES = %w[login firstname lastname mail language department].freeze
```

- [ ] **Step 6: Write the backfill migration**

```ruby
# db/migrate/20260809120003_add_department_to_default_user_custom_field_section.rb
# frozen_string_literal: true

class AddDepartmentToDefaultUserCustomFieldSection < ActiveRecord::Migration[8.1]
  # Append the new built-in `department` attribute to the default section (the
  # first UserCustomFieldSection by position) where the other built-ins already
  # live. Idempotent: skips sections that already contain the key.
  def up
    execute(<<~SQL.squish)
      UPDATE custom_field_sections
      SET attribute_order = array_append(attribute_order, 'department')
      WHERE id = (
        SELECT id FROM custom_field_sections
        WHERE type = 'UserCustomFieldSection'
        ORDER BY position
        LIMIT 1
      )
      AND NOT ('department' = ANY(attribute_order))
    SQL
  end

  def down
    execute(<<~SQL.squish)
      UPDATE custom_field_sections
      SET attribute_order = array_remove(attribute_order, 'department')
      WHERE type = 'UserCustomFieldSection'
    SQL
  end
end
```

Run: `bundle exec rails db:migrate`

- [ ] **Step 7: Add the locale label**

In `config/locales/en.yml`, under `activerecord: attributes: user:` add:

```yaml
        department: "Department"
```

- [ ] **Step 8: Run the specs to verify they pass**

Run: `bundle exec rspec spec/components/users/ -e department`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add app/components/users/profile/ app/components/users/hover_card_component.html.erb app/models/user_custom_field_section.rb config/locales/en.yml db/migrate/20260809120003_add_department_to_default_user_custom_field_section.rb db/schema.rb db/structure.sql
git commit -m "feat(departments): show department on user profile and hover card"
```

---

### Task 12: User edit form + persistence

Admin-editable department select on the user edit form; read-only on the self-service My Account page; persisted through `Departments::AddUserService`/`RemoveUserService` from `UsersController#update`.

**Files:**
- Modify: `app/forms/users/form/attributes_form.rb`
- Modify: `app/forms/my/attributes_form.rb`
- Modify: `app/controllers/users_controller.rb`
- Test: existing specs for `Users::Form::AttributesForm` and `UsersController#update` (extend)

**Source:** `3497115ded6` (form rendering — port the non-LDAP parts only), `4c58a7c420c` (persistence in `UsersController`).

**Interfaces:**
- Consumes: `User#department` (Task 3), `Group.organizational_units`/`.in_tree_order`/`#hierarchy_depth` (Task 2), `Departments::AddUserService`/`RemoveUserService` (Task 6).
- Produces: nothing consumed elsewhere — leaf UI + controller action.

- [ ] **Step 1: Write/extend the failing specs**

Add request/controller specs asserting: (a) an admin can change a user's `department_id` via the edit form and it persists via `Departments::AddUserService`; (b) a non-admin's submitted `department_id` is ignored; (c) the My Account page renders the field as read-only. Base these on `4c58a7c420c`'s intent (shown in full above) — check this fork's existing `spec/requests/users_spec.rb` or `spec/controllers/users_controller_spec.rb` for the closest existing pattern to extend.

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec` against the file(s) modified in Step 1.
Expected: FAIL — department not rendered/persisted.

- [ ] **Step 3: Add department rendering to `Users::Form::AttributesForm`**

In `app/forms/users/form/attributes_form.rb`, in the method that dispatches built-in field rendering by key (the `when "language"` branch shown in research), add a sibling branch:

```ruby
        when "department"
          render_department(group)
```

Add the supporting private methods:

```ruby
      # A user belongs to at most one department (an organizational unit group).
      # The field is editable by administrators only.
      def render_department(group)
        group.select_list(name: :department_id,
                          label: User.human_attribute_name(:department),
                          include_blank: "--- #{I18n.t(:actionview_instancetag_blank_option)} ---",
                          input_width: :medium,
                          **department_editability) do |list|
          department_options.each do |department|
            prefix = "  " * (department.hierarchy_depth || 0)
            list.option(label: "#{prefix}#{department.name}",
                        value: department.id,
                        selected: @user.department&.id == department.id)
          end
        end
      end

      def department_options
        @department_options ||= Group.organizational_units.in_tree_order
      end

      def department_editable?
        User.current.active_admin?
      end

      def department_editability
        return {} if department_editable?

        { disabled: true }
      end
```

(Simplified from upstream: no `ldap_managed?` check or `department_ldap_managed_caption`, since Task 8's dead-branch approach doesn't extend to this file — there's no "managed" state possible here at all, so the conditional is dropped rather than stubbed.)

If `User#active_admin?` doesn't already exist in this fork (it wasn't found in Task 3's research — the fork's `user.rb` diff showed this method absent from the fork's baseline for unrelated reasons), add it to `app/models/user.rb`:

```ruby
  def active_admin?
    admin? && active?
  end
```

- [ ] **Step 4: Make the field read-only on My Account**

In `app/forms/my/attributes_form.rb`, add:

```ruby
  # Users cannot move themselves between departments; the field is always
  # read-only on the self-service account page.
  def department_editable?
    false
  end
```

- [ ] **Step 5: Persist the change in `UsersController#update`**

In `app/controllers/users_controller.rb`, in the `update` action, after the existing `call = ::Users::UpdateService...` success check, add the department reconciliation:

```ruby
    if call.success?
      department_result = update_department

      # ...(existing password/session logic unchanged)...

      respond_to do |format|
        format.html do
          if department_result&.failure?
            flash[:error] = department_result.errors.full_messages.join("\n")
          else
            flash[:notice] = I18n.t(:notice_successful_update)
          end
          redirect_to action: :edit
        end
      end
```

(Merge this into the existing method body rather than replacing it wholesale — the surrounding password-change and format-branch logic is pre-existing and must stay; only the `department_result` variable and the `flash[:notice]` conditional are new.)

Add the private helper methods:

```ruby
  # Reconciles the user's department membership with the submitted department_id.
  # Editing the department is restricted to administrators; the field is disabled
  # in the form for everyone else, and this guard prevents bypassing that.
  # Returns the ServiceResult of the membership change, or nil when nothing changed.
  def update_department
    return unless current_user.active_admin?
    return unless params[:user]&.key?(:department_id)

    target_id = params[:user][:department_id].presence&.to_i
    current = @user.department
    return if target_id == current&.id

    target_id ? assign_department(target_id) : remove_department(current)
  end

  def assign_department(department_id)
    department = Group.organizational_units.find_by(id: department_id)
    return unless department

    Departments::AddUserService
      .new(department, user: current_user)
      .call(user_id: @user.id, remove_from_previous_department: true)
  end

  def remove_department(department)
    return unless department

    Departments::RemoveUserService
      .new(department, user: current_user)
      .call(user_id: @user.id)
  end
```

`department_id` is deliberately read directly from `params[:user]` rather than added to the permitted-attributes list used by `::Users::UpdateService` — it's handled by a separate, admin-gated path.

- [ ] **Step 6: Add the locale label reference check**

Confirm `activerecord.attributes.user.department` (added in Task 11 Step 7) covers the `User.human_attribute_name(:department)` call here — no new locale key needed.

- [ ] **Step 7: Run the specs to verify they pass**

Run: `bundle exec rspec` against the files from Step 1.
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add app/forms/users/form/attributes_form.rb app/forms/my/attributes_form.rb app/controllers/users_controller.rb app/models/user.rb
git commit -m "feat(departments): add department select to user edit form"
```

---

### Task 13: Full verification pass

**Files:** none (verification only).

- [ ] **Step 1: Run the full department-related spec surface**

```bash
bundle exec rspec spec/models/group_spec.rb spec/models/user_spec.rb spec/models/concerns/has_details_table_spec.rb \
  spec/contracts/groups/ spec/services/groups/ spec/services/departments/ \
  spec/controllers/admin/departments_controller_spec.rb spec/features/admin/departments_spec.rb \
  spec/seeders/demo_data/department_seeder_spec.rb spec/requests/api/v3/groups/
```

Expected: all PASS.

- [ ] **Step 2: Run rubocop on all touched files**

```bash
bin/dirty-rubocop --uncommitted
```

Fix any offenses.

- [ ] **Step 3: Run erb_lint on all touched templates**

```bash
erb_lint app/components/admin/departments/*.html.erb app/views/admin/departments/*.html.erb
```

Fix any offenses.

- [ ] **Step 4: Confirm no regressions in adjacent Group/Member specs**

```bash
bundle exec rspec spec/models/group_spec.rb spec/services/groups/ spec/services/members/ spec/models/user_spec.rb
```

Expected: PASS — in particular, confirm `spec/services/members/` (untouched by this plan) still passes, verifying the deliberate exclusion of membership-propagation code introduced no regressions in the existing group/project-role membership flows.

- [ ] **Step 5: Manual smoke test**

Start the app (`bin/dev` or `bin/compose run`), sign in as an admin, and verify: Administration → Users and permissions → Organization shows the department tree; create a department, add a user, attempt to add the same user to a second department (expect the move-dialog), edit a user and change their department, confirm it shows on their profile and hover card.

- [ ] **Step 6: Update the design spec status**

In `docs/superpowers/specs/2026-08-09-department-field-design.md`, change `**Status:** Draft (pending approval)` to `**Status:** Implemented`.

```bash
git add docs/superpowers/specs/2026-08-09-department-field-design.md
git commit -m "docs(departments): mark design spec as implemented"
```
