# Label Governance Implementation Tasks

Status: **done** — implemented in PR #172. Phase 5 (cleanup and the unique
indexes) remains, and is operational rather than code.
Date: 2026-09-06
Design: [label-governance-design.md](./label-governance-design.md) (v4.7)

## Goal

Let project admins create labels for their own project without routing every request
through a system admin, while keeping the shared taxonomy under system-admin control.

- **System labels** (`custom_options.project_id IS NULL`) — created by a system admin,
  applicable everywhere.
- **Project labels** (`project_id` set) — created by a project admin, named
  `<PREFIX>-name` under that project's own prefix, applicable only in that project.
- **Applying** a label is scoped. **Seeing** one already on a work package is not.

## Before starting

The design carries two decisions that are **not settled**, and both change code that these
tasks touch:

1. **Which existing roles receive `manage_project_labels`** — **resolved: every role holding
   `edit_project`**, the people who already administer a project. Implemented as a data
   migration, because role permissions seed only on a fresh install.

Everything else in the design is settled.

## Traps

Seven review rounds produced thirty-seven defects. These are the ones that recurred, listed
here because each was found *after* a fix in the same area was believed complete:

- **Wrong target project.** Three separate places resolve a target and two got it wrong.
  Any test that copies or moves *within one project* passes regardless.
- **Cross-product deletes.** `custom_values.value` is untyped text shared by every format.
  Field and value must stay paired or an integer field's `99` is deleted because some
  project owns option id 99.
- **Fixing one path, not the paths that feed it.** The copy filter was correct and placed
  where project copy never reads it.
- **Changing a shared method.** `possible_values_options` serves filters as well as
  pickers; `AssignableCustomFieldValues` serves user and project contracts as well as work
  packages; `options_for_list` serves user and version formats as well as list.

## Phase 1 — Schema and model, dark

Nothing user-visible. `allow_project_values` is false everywhere, so every code path
behaves exactly as it does today. **This phase must be incapable of failing on existing
data.**

### Task 1.1: Migration

- `add_reference :custom_options, :project, foreign_key: true, null: true, index: false`
- `add_index :custom_options, %i[custom_field_id project_id]`
- `add_column :custom_fields, :allow_project_values, :boolean, default: false, null: false`
- `add_column :custom_fields, :option_pattern, :string`
- `add_column :custom_fields, :option_pattern_description, :string`
- `add_column :projects, :label_prefix, :string`
- `add_index :projects, :label_prefix, unique: true`

Acceptance criteria:

- Runs on a database with existing duplicate and case-variant `custom_options` values.
- **No unique index on `custom_options`.** Those are deferred to phase 5 — see task 5.3.
- The `projects.label_prefix` unique index *is* included and is safe: the column is new and
  entirely NULL, and Postgres does not treat NULLs as equal.

### Task 1.2: `CustomOption` ownership and scopes

- `belongs_to :project, optional: true`
- `scope :system_level` — `where(project_id: nil)`
- `scope :applicable_in(project)` — `where(project_id: [nil, project&.id])`

Acceptance criteria:

- `applicable_in` is the **only** definition of the applicable set. Every caller — picker,
  validation, copy filter — reads from it.
- `applicable_in(nil)` returns system labels only, and does not raise.

### Task 1.3: `CustomOption` validations

- Case-insensitive uniqueness scoped by tier, on create and on value change only.
- Cross-tier shadowing: a project label may not take the value of an existing system label.
- Naming: value matches the field's `option_pattern` when present, on create and on value
  change only.
- `default_value` may only be true when `project_id` is NULL.

Acceptance criteria:

- An existing duplicate does **not** block an unrelated save of either record.
- Renaming a label to a value that collides is rejected; leaving it unchanged is not.
- A project label cannot be flagged as a list default — see design, *Defaults must stay
  system-only*.

### Task 1.4: `Project#label_prefix`

The prefix expression is shared with `CustomOption`'s naming validation, and it is used in
two shapes: alone, and embedded before a hyphen. An unanchored constant is therefore a trap —
`/[A-Z][A-Z0-9]{1,5}/` matches a *substring*, so `TOOLONG` passes as a prefix by matching its
first six characters. Define the fragment once and derive both anchored forms, so no call
site has to remember:

```ruby
PREFIX_FRAGMENT = /[A-Z][A-Z0-9]{1,5}/
PREFIX_FORMAT   = /\A#{PREFIX_FRAGMENT}\z/                        # Project#label_prefix
LABEL_FORMAT    = /\A#{PREFIX_FRAGMENT}-[A-Za-z0-9]+(?:[-_][A-Za-z0-9]+)*\z/  # CustomOption#value
```

- Validate `label_prefix` against `PREFIX_FORMAT`.
- Normalise blank to NULL on write.

Acceptance criteria:

- `TOOLONG` is **rejected** as a prefix, and `TOOLONG-Bounce` as a label. A test asserting
  only that `AT` is accepted passes with the unanchored version and proves nothing.
- Two projects with no prefix both save. (`""` would collide on the unique index; NULL does
  not.)
- One fragment, two derived constants — not two hand-written expressions that can drift.

### Task 1.5: `Project#remove_owned_labels`

- `before_destroy :remove_owned_labels, prepend: true`
- Partition owned options into those referenced by work packages **in other projects** and
  those not.
- Referenced: `update_all(project_id: nil)` — promote, do not delete.
- Unreferenced: delete their `custom_values` **grouped by `custom_field_id`**, then
  `delete_all` the options.
- On promotion collision with an existing system label, suffix deterministically rather than
  merging, and never fail the deletion:
  - First attempt `"#{value} (#{project.identifier})"` — stable, and it says where the label
    came from, which is the information an admin needs to resolve it.
  - If that also collides, append ` 2`, ` 3`, … until free.
  - Do the whole check-and-write inside the same per-field advisory lock as label creation
    (task 4.3, rule 6). Without it, two concurrent project deletions can pick the same
    suffix and one insert loses.
  - Collect the promotions and return them in the service result, and log them at `warn`.
    "Report it" is not a mechanism; a caller that cannot see what happened cannot act on it.

Acceptance criteria:

- Deleting a project whose label is the last option on its field **succeeds**.
  `assure_at_least_one_option` aborts `destroy`, which is why this uses `delete_all`.
- Deleting project A does not remove a label value from a work package in project B.
- An integer custom field holding the value `99` survives the deletion of a project owning
  option id `99`.

## Phase 2 — Prefix administration

### Task 2.1: Admin screen

- Route: `resource :label_prefixes, only: %i[show update]` under the admin settings scope.
- `Admin::Settings::LabelPrefixesController < ::Admin::SettingsController` — inherits
  `require_admin`.
- `show` lists every project with identifier, current prefix, and a **computed** candidate.
- `update` saves `projects: { <id> => { label_prefix: } }` in one transaction.
- Admin settings menu entry.

Acceptance criteria:

- Not reachable from project settings, and `label_prefix` stays absent from
  `PermittedParams#project` and `#new_project`.
- Candidates are computed per request and **never persisted** — a written value is by
  definition confirmed.
- A collision between two candidates is reported for a human decision, not silently skipped.
- Re-running changes nothing already confirmed.

### Task 2.2: Candidate derivation

- `identifier.delete("-_").upcase` where the result matches `PREFIX`, otherwise blank.

Acceptance criteria:

- `at` → `AT`, `web-ext` → `WEBEXT`, `台北報社設備` → blank.
- A blank candidate leaves the project unable to own labels, and the project settings screen
  says so in words rather than rendering an empty section.

### Task 2.3: Rename AdTech (operational, not code)

- `ad` → `adt`, so its prefix is `ADT` and `AD` stays free for a future shared domain.

Acceptance criteria:

- Check `Project.find_by(identifier: "ad").repository` first. If non-nil, the checkout URL
  breaks and the SCM side must be fixed in the same window.
- Links to `/projects/ad` will 404 permanently — there is no slug history.

## Phase 3 — Scope what can be applied

Still invisible while no project labels exist, but **must land before phase 4**: afterwards,
every new label would be applicable everywhere until this ships.

### Task 3.1: `CustomField#applicable_values_options`

- Narrow only when `field_format == "list" && allow_project_values? && project`.
- **Delegate to `possible_values_options` in every other case.**

Acceptance criteria:

- `possible_values_options` and `possible_list_values_options` are unchanged. Filtering
  stays global.
- Bulk editing a **version** custom field still produces grouped options; a **user** field
  still works. Both register `edit_as: "list"`.

### Task 3.2: Scope `assignable_custom_field_values`

- Gate the `when "list"` branch on `allow_project_values?` **and** a resolvable project.
- Return applicable values **plus any option already stored on the record**.

Acceptance criteria:

- Editing a list-format **user** custom field is unchanged. `Users::BaseContract` has no
  project and must not receive an empty list.
- Editing a list-format **project** custom field is unchanged.

### Task 3.3: Contract validation

- In `WorkPackages::BaseContract`, validate the Labels custom values that are
  `new_record?` — and only those — against `applicable_in(project)`.

Acceptance criteria:

- An unrelated edit (changing the subject) to a work package moved between projects
  succeeds, and keeps its labels.
- Adding one label to a multi-value field already holding an inapplicable one validates only
  the addition.
- Creating via the API with an inapplicable option id is rejected. The API accepts any id;
  the picker is not the enforcement point.

### Task 3.4: Picker paths

Three, all of which must move to `applicable_values_options`:

- API schema — `list_schemas_values_callback` already routes through
  `assignable_custom_field_values`, so task 3.2 covers it.
- Primer inputs — `single_select_list.rb` and `multi_select_list.rb` currently enumerate
  `custom_options` directly.
- Legacy bulk edit — `options_for_list`, **and**
  `app/views/work_packages/moves/new.html.erb:208` must pass `@target_project`, not
  `@project`.

Acceptance criteria:

- A bulk **move to another project** offers the target's labels, not the source's. A test
  that moves within one project passes either way and proves nothing.

### Task 3.5: Copy filter

- `WorkPackage#custom_value_attributes_for(target_project)`.
- Called from **both** `WorkPackages::CopyService#copied_attributes` and
  `WorkPackagesDependentService#custom_value_attributes`.
- Resolve the target from `project`, then `project_id`, then the work package's own project.
- Act only on `list` fields with `allow_project_values?`; leave every other format untouched.

Acceptance criteria:

- Project copy drops source-owned labels. The dependent service's override wins the merge in
  `copied_attributes`, so a filter applied only in `CopyService` never runs on this path.
- A cross-project **bulk** work package copy drops them too.
- A same-project copy keeps its labels — the target resolves to the current project, not nil.
- An integer custom field whose value equals a project label's option id survives.
- `CopyProjectContract#valid?` returns `true` unconditionally, so **the filter is the only
  protection on project copy**. This test is the regression test for that.

## Phase 4 — Permission and project UI

### Task 4.1: Permission and data migration

- `manage_project_labels` in `config/initializers/permissions.rb`,
  `permissible_on: :project, require: :member`.
- **Data migration granting it to existing roles.** `BasicData::ModelSeeder#applicable?` is
  `model_class.none?`, so seeding never runs where roles already exist.

Acceptance criteria:

- On an instance with existing roles, a project admin can reach the new screen after
  migrating. Without this, the feature ships unreachable.

### Task 4.2: Custom field configuration

- Add `allow_project_values`, `option_pattern` and `option_pattern_description` to
  `CustomFields::BaseContract`, `PermittedParams#custom_field`, and
  `CustomFields::DetailsForm`.
- Validate that `allow_project_values` may only be true when `option_pattern` is present.
- **Validate that `option_pattern` compiles.** It is admin-supplied free text passed to
  `Regexp.new`, so an unbalanced bracket saved here raises `RegexpError` later, at label
  creation, in a completely different screen. Mirror `CustomField#validate_regex`: compile
  inside `rescue RegexpError` and add an error on the attribute.
- Pass a `timeout:` to `Regexp.new` at the point of use — the pattern runs on every option
  save, and Ruby 3.4 supports bounding it.

Acceptance criteria:

- An admin can set all three from the custom field admin screen.
- Enabling the flag without a pattern fails with a validation error.
- Saving `option_pattern` as `\A(ML|AD-` is rejected **on that screen**, not hours later
  when someone tries to create a label.
- A catastrophically backtracking pattern does not hang a request.
- **Set the pattern on the Labels field before enabling the flag** — the validation makes
  the reverse order impossible to execute.

### Task 4.3: Option services — two layers, not one

An earlier draft had a single set of services that both refused `project_id IS NULL` **and**
served the system-admin delete path, which manages exactly those. Those cannot both hold.
What the two paths share is the *cleanup*, not the *authorisation*.

**Layer 1 — `CustomOptions::DestroyService`.** Tier-agnostic, no authorisation of its own.
Deletes an option and its `custom_values` in one transaction. Called by the project-admin
service below **and** by the existing admin `delete_option` path.

**Layer 2 — `CustomOptions::ProjectLabels::{Create,Update,Delete}Service`.** The
project-admin path, enforcing:

1. Authorise on `manage_project_labels` for the option's project.
2. Refuse records whose `project_id` is NULL — a system label is not this path's business.
3. Refuse fields whose `allow_project_values` is false.
4. Reject values not carrying the project's own prefix.
5. Pin `project_id` and `custom_field_id` on update.
6. Take the per-field advisory lock around the shadowing check and the write.

Deletion delegates to layer 1 for the actual removal.

Acceptance criteria:

- `CustomFields::BaseContract`'s `RequiresAdminGuard` is untouched, and a system admin can
  still create, rename and delete **system** labels through the existing admin screen.
- The admin `delete_option` path uses `DestroyService`, so its cleanup becomes
  transactional — today it destroys the option and only then deletes values, with nothing
  wrapping the two.
- A project admin cannot reach a system label through layer 2.
- Params claiming a different `project_id` or `custom_field_id` on update are ignored, not
  honoured.

#### Deleting the last remaining option

`CustomOption` aborts `destroy` when it is the final option on its field. Project deletion
deliberately bypasses that with `delete_all` (task 1.5), because a field-level invariant must
not block deleting a project. **A deliberate single deletion is the opposite case and should
respect it:** the user is choosing to remove one label, nothing else is at stake, and
silently leaving a list field with no options makes it unusable.

So layer 1 uses `destroy`, surfaces the existing "At least one option needs to be available"
error, and the project settings screen shows it. Only the cascade path bypasses.

Acceptance criteria:

- Deleting a project's only label, on a field with no system labels, is **rejected** with
  that message.
- The same option is removed without complaint once any other option exists.
- Deleting the *project* still succeeds in both cases (task 1.5).

### Task 4.4: Project settings screen

- `Projects::Settings::LabelsController` — own labels with full CRUD, prefix read-only,
  system labels listed for reference.

Acceptance criteria:

- A project with no prefix sees an explanation, not an empty section.
- System labels are visible but not editable, so a project admin can see a name is taken.

## Phase 5 — Cleanup

The pattern is already set; phase 4 cannot run without it.

### Task 5.1: Reports

- Non-conforming labels, with usage counts.
- Duplicate values, case-insensitive, within a field and tier.
- Demotion candidates — options whose values all sit in a single project.

### Task 5.2: Cleanup

- Merge or rename duplicates. Merging rewrites `custom_values`; renaming does not, since
  values reference option ids.

### Task 5.3: Unique indexes

- Partial unique indexes on `custom_options` for each tier.

Acceptance criteria:

- The migration re-checks for duplicates and aborts with a readable message if any remain.
- Built `CONCURRENTLY`, with `disable_ddl_transaction!`.
- **Detects and drops an invalid index of the same name before building.** A failed
  concurrent build leaves one behind, and a naive re-run then fails with "relation already
  exists".
- Safe to re-run.

## Test coverage

| Case | What it proves |
|---|---|
| Create via API with an inapplicable label | The contract, not the picker, enforces. |
| Create via the Primer dialog | The dialog renders its own inputs. |
| Adding one label to a multi-value field already holding an inapplicable one | Only the addition is validated. |
| Unrelated edit to a moved work package | Retention. |
| Bulk move to another project | The third picker path, and `@target_project`. |
| Cross-project bulk work package copy | `CopyService` merges custom values unfiltered. |
| Project copy with a source-owned label | **The most important one.** `CopyProjectContract#valid?` returns `true`, so nothing else catches an unfiltered copy. |
| Same-project copy | Target resolution falls back to the current project, not nil. |
| Integer field whose value equals an option id, on copy and on project deletion | Field/value pairing, in both places it matters. |
| Deleting a project whose label is the last option on its field | Succeeds, and cleans up. |
| Deleting a project whose label is used elsewhere | Promoted, not deleted. |
| Promotion colliding with an existing system label | Suffixed deterministically, returned in the result, and the deletion still succeeds. |
| Two concurrent project deletions promoting the same label value | The advisory lock serialises them; both get distinct names and neither insert is lost. |
| `TOOLONG` as a prefix, and `TOOLONG-Bounce` as a label | Both rejected — the expression is anchored. |
| Saving a malformed `option_pattern` | Rejected on the custom field screen, not at label creation. |
| System admin creating, renaming and deleting a **system** label | Still works. The project-admin services refuse system labels; the admin path is layer 1 plus the existing contract. |
| Deleting a project's only label on a field with no other options | Rejected with the existing "at least one option" message — unlike project deletion, which bypasses it. |
| Deleting a project label directly | Values go with it, in one transaction. |
| Bulk editing a user or version custom field | Unchanged; both register `edit_as: "list"`. |
| Editing a list-format user or project custom field | Unchanged; the concern is shared. |
| Filtering by a label the current project cannot apply | Still possible; filtering is a read. |
| Project option on a field with `allow_project_values` false | The flag is enforced. |
| Update with a foreign `project_id` or `custom_field_id` | Both pinned. |
