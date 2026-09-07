# Label Governance — Design (v5)

Status: **implemented** — see PR #172. Divergences are recorded at the end.
History: **in review** (v2 after review settled retention and
ownership; v3 after "apply is scoped, see is not"; v4 after deferring shared prefixes;
v4.1 after review found three failure modes in the migration, copy and deletion paths;
v4.2 after review found the picker was only half-scoped, plus defaults, prefix copying and
an index race; v4.3 after a contract-lifecycle trace found the copy paths uncovered and
CopyProjectContract bypassing validation entirely; v4.4 specifies the validation algorithm,
target resolution, the cross-tier lock and the write-path rules; v4.5 adds the legacy bulk
picker path, option deletion cleanup, and resolves three internal contradictions; v4.6
separates the apply lookup from the read lookup, gates the shared concern, and specifies the
prefix, permission and configuration lifecycles; v4.7 makes the copy filter reach project
copy, the deletion code match its own prose, and the prefix screen implementable)
Date: 2026-09-06
Related: [label-governance-implementation-tasks.md](./label-governance-implementation-tasks.md),
PR #171 (project identifiers must be set deliberately at creation),
`custom_options`, `WorkPackageCustomField` named "Labels"

## Problem

Only system admins can create labels, so every request routes through them — including
project-specific ones. There is no process, so labels accumulate ad hoc with no naming
consistency.

"Label" is product language, not a codebase concept. There is no `Label` model, table or
controller. A label is a **row in `custom_options`** belonging to a single
`WorkPackageCustomField` named "Labels" with `field_format: "list"`, enabled across Task,
Milestone, Feature, Epic, Story, Bug, Record, Sub-task and Operation.

## Current state (verified)

- **No project scoping.** `custom_options` has `custom_field_id`, `position`,
  `default_value`, `value` and timestamps. There is no `project_id` — a label is global by
  construction, not by policy.
- **Admin-only creation.** `CustomFieldsController` is gated by
  `before_action :require_admin` (`app/controllers/custom_fields_controller.rb:38`), and
  `CustomFields::BaseContract` includes `RequiresAdminGuard`. Options are written as nested
  attributes through `CustomFields::UpdateService`, inheriting that guard.
- **Project admins can only tick.** The `select_custom_fields` permission
  (`config/initializers/permissions.rb:257`) exposes one screen toggling *which existing
  fields are active* in a project. It cannot create a value. This is the bottleneck.
- **No naming rules.** `CustomOption` validates only `value` presence and length ≤ 255.
- **Projects now have deliberate codes.** As of PR #171 an identifier must be typed when a
  project is created rather than slugged from its name. That is what makes a per-project
  prefix viable.

## Shape of the change

Two rules settle the design, and they pull in opposite directions on purpose:

- **Applying is scoped.** A user may only put a label on a work package if the *project*
  owns that label, or it is a system label everyone shares.
- **Seeing is not.** Anyone who can read a work package sees every label on it, whoever
  added it and whichever project it came from.

There are exactly two kinds of label in this version:

| Tier | Test | Created by |
|---|---|---|
| System | `project_id IS NULL` | system admin, shared by all |
| Project | `project_id = <project>` | project admin, prefixed with that project's code |

```
applicable(project) = project_id IS NULL  OR  project_id = project.id
```

Because a project owns exactly one prefix — its own — ownership and prefix say the same
thing, and the applicable set is a plain ownership test. The prefix is then purely a
**naming rule enforced at creation**, not an access mechanism. That is what makes this
version small.

### Retention

Because seeing is unrestricted while applying is not, the two must not fight. A work
package that moves between projects keeps its labels, and a project does not have its
existing work packages rewritten. Concretely, **only newly added labels are validated** —
already-stored values are left alone, or an unrelated edit to a moved work package would
silently drop them or fail outright.

This is not a new pattern. `validate_version_is_assignable`
(`app/contracts/work_packages/base_contract.rb:445`) opens with
`return unless model.version_id_changed?` for precisely this reason, and
`assignable_version_custom_field_values` keeps already-assigned versions selectable once
they are no longer offered.

## Data model

```ruby
# who owns a label. NULL = system-level, which is what every label is today.
add_reference :custom_options, :project, foreign_key: true, null: true, index: false
add_index :custom_options, %i[custom_field_id project_id]

# which list fields project admins may add values to at all. Off everywhere by default,
# so this cannot silently open every list field in the instance.
add_column :custom_fields, :allow_project_values, :boolean, default: false, null: false

# the naming rule, on the field so it can change without a deploy
add_column :custom_fields, :option_pattern,             :string
add_column :custom_fields, :option_pattern_description, :string
# all three need adding to CustomFields::BaseContract's attribute list and to
# PermittedParams#custom_field, or no admin can set them - see below

# the project's label prefix, seeded from its identifier and confirmed by an admin.
# This unique index DOES ship in phase 1, unlike the custom_options ones: the column is new
# and entirely NULL, and Postgres does not treat NULLs as equal, so it cannot fail on
# existing data.
add_column :projects, :label_prefix, :string
add_index  :projects, :label_prefix, unique: true
```

### Why the prefix is stored, not derived from the identifier

- **Identifiers are mutable.** Deriving live would silently change what a project's prefix
  means, leaving existing labels named after a code it no longer has.
- **They may contain the separator.** A hyphen separates prefix from name, so `web-ext`
  would make `WEB-EXT-Bounce` ambiguous — is the prefix `WEB` or `WEB-EXT`?
- **Not every identifier is a good prefix.** They run from two to a hundred characters.
  Seeding produces a *candidate* for an admin to confirm.

The unique index is deliberate: two projects sharing a prefix would make `ABC-Bounce`
ambiguous about ownership.

### Uniqueness of label values

**These indexes cannot ship in phase 1.** `CustomOption` validates only presence and length
today, and there is no uniqueness constraint of any kind on `custom_options` — the existing
indexes are a plain btree on `custom_field_id` and a GIN trigram index on `value`. Any
installation may therefore already hold exact duplicates or case-variants, and a unique
index migration would fail on them. That would also contradict the rollout's promise that
phase 1 needs no backfill and cannot fail.

The sequence is therefore:

1. **Phase 1 — model validation only.** Case-insensitive uniqueness scoped by tier,
   validated on create and on value change only, so existing duplicates do not block
   unrelated saves. New duplicates become impossible from this point.
2. **Phase 5 — preflight, then the index.** A report lists existing collisions per field
   and tier for someone to merge or rename. Merging rewrites `custom_values`, so it is a
   data change with an owner, not a migration.
3. **After cleanup** — add the indexes, in their own migration.

   The model validation is not atomic, so two concurrent requests can each pass it and
   insert the same value. Between the duplicate report and the migration, labels stay
   writable, and a fresh collision would make the migration fail. The index step must
   therefore be **retryable and idempotent** rather than assumed to succeed:

   ```ruby
   # re-check immediately before, inside the same migration
   dupes = CustomOption.select(:custom_field_id, :project_id, "lower(value) AS v")
                       .group(:custom_field_id, :project_id, "lower(value)")
                       .having("count(*) > 1")
   raise "#{dupes.length} duplicate label(s) remain - re-run the cleanup" if dupes.any?
   ```

   Prefer `CREATE UNIQUE INDEX CONCURRENTLY` (`algorithm: :concurrently`, with
   `disable_ddl_transaction!`) so the build does not hold a write lock. But a concurrent
   build that fails **leaves an invalid index behind under the target name**, so a naive
   re-run then dies with "relation already exists" rather than retrying. The migration has
   to clear that itself:

   ```ruby
   def drop_invalid(name)
     invalid = select_value(<<~SQL.squish)
       SELECT 1 FROM pg_class c
       JOIN pg_index i ON i.indexrelid = c.oid
       WHERE c.relname = '#{name}' AND NOT i.indisvalid
     SQL
     remove_index :custom_options, name:, algorithm: :concurrently if invalid
   end
   ```

   So each index step is: drop it if it exists but is invalid, skip it if it exists and is
   valid, otherwise build it. That plus the duplicate re-check makes the migration genuinely
   re-runnable rather than merely described as such.

   A short maintenance window is the alternative if concurrent label creation is likely; on
   an instance where only admins can create labels until phase 4, it is not.

```ruby
add_index :custom_options, "custom_field_id, lower(value)",
          unique: true, where: "project_id IS NULL",     name: :index_custom_options_system_value
add_index :custom_options, "custom_field_id, project_id, lower(value)",
          unique: true, where: "project_id IS NOT NULL", name: :index_custom_options_project_value
```

The model validation is the enforcement; the indexes are the backstop that makes it true
under concurrency. Shipping them out of order turns a clean deploy into a failed one.

### Cross-tier collisions cannot be indexed

Neither index stops a project label shadowing a *system* label of the same name. The two
partial indexes cover system-vs-system and project-vs-project; the cross-tier case spans
both. A single unindexed `(custom_field_id, lower(value))` would not do either — it would
also forbid two *different* projects each owning a label of the same name, which is
legitimate.

So the shadowing rule is a model validation with no database backstop, and model validations
are not atomic: a system label and a project label with the same value, created
concurrently, both pass and both commit.

**Serialise creation per field with an advisory lock.** Label creation is rare and admin-
driven, so the cost is irrelevant and the correctness is not:

```ruby
# in the create/update/promote services, inside the transaction
ActiveRecord::Base.connection.execute(
  "SELECT pg_advisory_xact_lock(#{ADVISORY_LOCK_NAMESPACE}, #{custom_field_id})"
)
# then: shadowing check, uniqueness check, insert
```

The lock is released with the transaction, and it must wrap **every** writer that can create
a cross-tier collision — the project-admin service, the admin nested-attributes path, and
promotion. Leaving one out reintroduces the race for that path alone, which is the hardest
kind of bug to find later.

In practice the prefix rule makes a collision unlikely, since a project label must carry its
project's prefix and a system label would have to reuse it. Unlikely is not a concurrency
strategy.

### Deleting a project

**`dependent: :destroy` is the wrong mechanism here.** `CustomOption` carries
`before_destroy :assure_at_least_one_option` (`app/models/custom_option.rb:39`), which
aborts when the option is the last one on its field. Verified behaviour: `destroy` returns
`false` and the row survives.

With a foreign key on `custom_options.project_id`, an aborted child destroy leaves a row
pointing at the project being deleted, so the parent `DELETE` then violates the constraint
and project deletion fails. The failure is also conditional — it only bites when a field's
only remaining options are that project's — which makes it the kind of bug that passes
review and appears in production.

The callback's intent is a *field-level* invariant: a list field with zero options is
unusable. That is not a reason to block deleting a project. So deletion is explicit rather
than declarative:

```ruby
# Project, prepended so it runs before the FK is enforced
before_destroy :remove_owned_labels, prepend: true

def remove_owned_labels
  owned = CustomOption.where(project_id: id).pluck(:id, :custom_field_id)
  return if owned.empty?

  referenced, unreferenced = owned.partition { |option_id, cf_id| referenced_elsewhere?(option_id, cf_id) }

  # Still used by a work package in another project: promote rather than delete, or this
  # project's deletion would damage an unrelated project's data. The option id does not
  # change, so every stored value stays valid.
  CustomOption.where(id: referenced.map(&:first)).update_all(project_id: nil)

  # Used nowhere outside this project: delete it and its values. Field and value stay
  # PAIRED - two independent IN clauses form a cross product, so an integer custom field
  # holding the value 99 would be deleted merely because some field owned an option id 99.
  unreferenced.group_by(&:last).each do |custom_field_id, rows|
    CustomValue.where(custom_field_id:,
                      value: rows.map { |option_id, _| option_id.to_s }).delete_all
  end
  # delete_all, not destroy_all: bypasses assure_at_least_one_option deliberately
  CustomOption.where(id: unreferenced.map(&:first)).delete_all
end
```

#### Deleting an owner project breaks retention for other projects

Retention promises that a work package which moved between projects keeps its labels. This
callback breaks that promise for exactly one case: a work package now in project B, still
carrying a label owned by project A, loses that value when **A** is deleted. B's data is
damaged by an action taken on a project B has nothing to do with.

Deleting the option is right when nothing else references it, and wrong when something does.
So the callback promotes rather than deletes in that case:

```ruby
# an owned option still referenced by a work package outside this project becomes a system
# label instead of disappearing - retention wins over tidiness
```

Concretely: for each owned option, if any surviving `custom_value` belongs to a work package
in another project, set `project_id` to NULL and leave it; otherwise delete it and its
values as above. Promotion keeps every stored value valid, since the option id does not
change.

The cost is that deleting projects can quietly grow the system tier, and a promoted label
keeps a prefix belonging to a project that no longer exists. That is the lesser harm — the
alternative silently corrupts an unrelated project's work packages — but the promotion should
be reported, not silent, so an admin can rename or retire the label afterwards.

**Promotion can collide.** A system label of the same name may already exist, which the
shadowing rule normally forbids. Deleting a project must not fail because of it, and the two
options cannot be merged automatically — merging rewrites `custom_values` and is a data
decision. So the promoted label takes a disambiguating suffix (`ADT-Bounce (AdTech)`),
keeping its id and therefore every stored value, and the collision is reported alongside the
promotion for an admin to resolve. Suffixing violates the naming pattern deliberately: the
label is already legacy at that point, and the non-conforming report is exactly where it
should surface.

Use `pluck`, not `select(:id).map(&:to_s)` — the latter loads `CustomOption` records with
only `id` selected and then calls `CustomOption#to_s`, which reads `value` and raises
`ActiveModel::MissingAttributeError`.

`delete_all` skips the callback deliberately, and that must stay commented or a later reader
will "fix" it back to `destroy_all`. The `custom_values` cleanup has to be explicit in any
case, because `custom_values` stores the option id as untyped `text` with no foreign key —
nothing at the database level will tidy up after it.

One accepted consequence: if a field's only options belonged to the deleted project, the
field is left with none and becomes unusable until an admin adds one. For "Labels" this
cannot happen in practice, since system labels exist; the design accepts it rather than
blocking a project deletion on a field-level concern.

## Where a prefix comes from

A project label must be named `<PREFIX>-Name`, where `<PREFIX>` is the project's own
`label_prefix`.

```
ArchTech   identifier at    → prefix AT     → AT-Migration
AdTech     identifier adt   → prefix ADT    → ADT-Trafficking
Auth       identifier auth  → prefix AUTH   → AUTH-SSO
```

### Who sets the prefix, and where

"An admin confirms it" is not a lifecycle. Nothing today can set `label_prefix`: it is absent
from `PermittedParams#project` and `#new_project` (`app/models/permitted_params.rb:284`),
absent from the project contracts, and the project settings screen shows it read-only by
design, since a project admin must not be able to grant themselves a prefix. So the feature
needs an explicit **system-admin** surface, and it has to cover four cases the happy path
does not:

| Case | Required behaviour |
|---|---|
| No usable candidate | An identifier like `台北報社設備` normalises to nothing. The prefix stays blank and the project simply cannot own labels until an admin sets one. The settings screen must say that, rather than showing an empty section. |
| Candidate collides | Two projects normalising to the same prefix — the column is unique, so the second must be reported for a human decision, not silently skipped. |
| Re-running | The seeder must be idempotent: fill blanks, never overwrite a confirmed prefix. |
| Projects created later | `Projects::CreateService` (`app/services/projects/create_service.rb:32`) generates no candidate, so every new project starts blank and inherits the "cannot own labels yet" state until an admin acts. |

Concretely, and this needs to be concrete or it is not implementable:

| Piece | Definition |
|---|---|
| Route | `resource :label_prefixes, only: %i[show update], controller: "admin/settings/label_prefixes"` under the existing `scope "admin/settings"` |
| Controller | `Admin::Settings::LabelPrefixesController < ::Admin::SettingsController`, inheriting its `require_admin` filter — this is a system-admin screen and must not be reachable through project settings |
| Action | `show` lists every project with identifier, current prefix and computed candidate; `update` accepts `projects: { <id> => { label_prefix: } }` and saves them in one transaction |
| Menu | An entry under the admin settings menu, beside the other instance-wide settings |
| Params | A new `PermittedParams` entry — `label_prefix` is deliberately absent from `#project` and `#new_project` so that no project-scoped path can ever set it |

**There is no candidate column, and there must not be one.** A rake task cannot write a
candidate into `label_prefix`, because a written value is by definition confirmed — the
column is what every validation reads. Candidates are therefore **computed on the fly** by
the admin screen and never persisted; the rake task reports, it does not write. That also
makes the whole thing idempotent for free: there is no state to re-apply.

**A blank candidate must be NULL, never `""`.** Postgres treats NULLs as distinct in a
unique index but two empty strings as equal, so the first project with no usable candidate
would silently block every other one. `label_prefix` is therefore normalised to NULL on
write, and a project with NULL simply cannot own labels — which the project settings screen
must say in words rather than rendering an empty section.

Seeding derives a candidate — `identifier.delete("-_").upcase` where that already satisfies
`\A[A-Z][A-Z0-9]{1,5}\z`, blank otherwise — for an admin to confirm. It is a review step,
not an automatic migration.

### Copying a project must not copy its prefix

`Projects::CopyService#skipped_attributes` is a fixed list —
`%w[id created_at updated_at name identifier active templated lft rgt]`
(`app/services/projects/copy_service.rb:128`) — and everything else is carried over from
the source. `label_prefix` is therefore copied, and because the column is unique the copy
either fails outright or, before the index exists, silently gives two projects the same
prefix.

`label_prefix` must be added to `skipped_attributes`. The copy is then left without a
prefix, which is the correct default: a new project has no labels yet, and its prefix is a
deliberate choice an admin confirms, exactly as at seeding.

**The one collision is resolved by renaming.** `AdTech` held identifier `ad`, colliding
with `AD-` as a future shared ad-operations prefix. It is renamed to `adt`, so its prefix
becomes `ADT`.

Renaming the identifier rather than only the prefix keeps the two consistent, but the cost
is larger than link rot. There is no slug history (`friendly_id` is configured
`use: :finders`, without `:history`), and four lookups resolve a project by identifier with
**no fallback**:

- repository auth and changeset sync (`app/controllers/sys_controller.rb:43` and `:54`)
- inbound email routing (`app/services/incoming_emails/handlers/base.rb:194`)
- resource links in formatted text
  (`lib/open_project/text_formatting/matchers/resource_links_matcher.rb:197`)
- export macros (`app/models/work_package/exports/macros/attributes.rb:136`)

Wiki cross-project links degrade gracefully — `app/models/wiki.rb:101` and
`lib/open_project/text_formatting/matchers/wiki_links_matcher.rb:100` fall back to matching on project *name*. Nothing stores a copy
of the identifier as a reference, so there is no data migration. Check whether the project
has a repository before renaming; if it does, the SCM side needs fixing in the same window.

### Renaming a project later

Nothing automatic, deliberately. `label_prefix` is independent of `identifier` once seeded,
so renaming a *project* leaves existing labels valid and correctly named.

Changing the *prefix* is different, and the design has to say which of two rules wins.
"A project label must carry its project's prefix" and "changing the prefix does not rewrite
existing labels" cannot both hold unchanged.

**Superseded — the implementation migrates the labels instead.** This section originally
made old-prefix labels an explicit legacy exception on the grounds that applicability is
decided by ownership, so nothing functional breaks.

Review found that reasoning incomplete. An old-prefix label is **unrenameable**: the naming
rule rejects its own current value, so editing it for any reason fails. And clearing a
prefix frees it for another project, which could then create colliding names in a namespace
that still holds labels.

So the shipped behaviour is: **labels move with the prefix**, renamed through normal
validation rather than `update_column`, and a rename that cannot succeed refuses the prefix
change and names the label that blocked it. Clearing a prefix is refused while the project
owns any labels.

## Naming convention

Two jobs worth separating: **shape** (every label parses the same way, so sorting clusters
domains and type-ahead narrows predictably) and **vocabulary** (which prefixes exist).

```
\A[A-Z][A-Z0-9]{1,5}-[A-Z][A-Za-z0-9]*\z    # <PREFIX>-Name
```

The prefix half of that pattern is **the same expression the seeding step accepts**, and it
has to be: an earlier revision let seeding confirm `\A[A-Z][A-Z0-9]{1,5}\z` — two to six
alphanumerics — while the label shape allowed only two to four letters. A confirmed prefix
of `WEBEXT` or `AT12` would then have made every label that project could create invalid,
with the error pointing at the label rather than at the prefix that caused it. The two rules
are one rule, defined once:

```ruby
PREFIX = /[A-Z][A-Z0-9]{1,5}/      # used by both the prefix and the label validations
```

Six characters rather than four because the real identifiers require it: normalising
`web-ext` yields `WEBEXT`. Digits are allowed because nothing in the data rules them out and
forbidding them would reject a project code like `L10N`.

### Do not reuse `custom_fields.regexp`

`CustomValue#validate_format_of_value` (`app/models/custom_value.rb:103`) applies `regexp`
to the stored *value*. For a list field that value is the custom option's **id** — the
string `"17"` — not the label text. A pattern set there would reject every assignment.

This is why `show_regex_field?` (`app/forms/custom_fields/details_form.rb:260`)
deliberately excludes `list` from the formats offering the field. The exclusion is
load-bearing, not an oversight. Hence the separate `option_pattern` column.

`option_pattern_description` is not decoration: the existing failure message renders as
*"does not match the regular expression `\A(ML|AD)-[A-Z][A-Za-z0-9]*\z`"*, which is not
something to show a project admin.

### Four details that decide whether it holds

- **Anchor with `\A` and `\z`.** Ruby's `^`/`$` match line boundaries — the existing
  `text_regexp_multiline` help text documents that the current regexp runs in multi-line
  mode. A pattern anchored `^…$` would accept `"ML-Bounce\ninjected"`.
- **Fix the case.** The uniqueness indexes key on `lower(value)`, so `ML-Bounce` and
  `ml-bounce` already collide. Requiring an uppercase prefix makes the canonical form
  explicit rather than something admins discover through a confusing error.
- **Validate on create and value change only.** Running it on every save would make
  existing non-conforming labels unsaveable and break unrelated edits.
- **Guard the pattern itself.** Mirror `CustomField#validate_regex`: compile inside
  `rescue RegexpError`. Since it is admin-supplied and runs on every option save, pass a
  `timeout:` to `Regexp.new` (available on the pinned Ruby 3.4.7).

### What it will not do

The convention enforces *form*, not *meaning*. It will not stop `ML-Bounce` and
`ML-Bounced` coexisting, and it will not check that a prefix suits the work a project does.

## Ownership and permissions

A new project permission, `manage_project_labels` in `config/initializers/permissions.rb`,
`permissible_on: :project, require: :member`. It grants CRUD over that project's own labels
and nothing else.

**Existing installations need a data migration to grant it.** Role permissions are seeded
only on a fresh install: `BasicData::ModelSeeder#applicable?` is `model_class.none?`
(`app/seeders/basic_data/model_seeder.rb:74`), so it never runs where roles already exist.
Adding the permission to `config/locales/common.yml` therefore does nothing for anyone with
a running instance — the screen ships, and no role can reach it.

The migration must also state *which* roles receive it, and that is a judgement rather than a
lookup. Granting it to every role holding `edit_project` matches the intent — the people who
already administer a project — and is the recommendation. Granting it to `manage_categories`
holders instead would target the people who manage a project's existing taxonomy, which is a
defensible alternative; granting it to all members is not.

**Do not relax `RequiresAdminGuard` on `CustomFields::BaseContract`.** That contract governs
field format, `is_required`, `is_for_all`, regexp, section — the whole field definition.
Weakening it so a project admin can add one value would hand them the field itself, across
every project it is enabled in.

Add a separate, narrow path instead: `CustomOptions::CreateService` / `UpdateService` /
`DeleteService` with their own contracts. Each must enforce all six of these, because the
flag and the tier are not enforced anywhere else on this path:

1. **Authorise** on `manage_project_labels` for the option's project.
2. **Refuse system-tier records** — anything whose `project_id` is NULL belongs to the admin
   path, not this one.
3. **Refuse fields with `allow_project_values` false.** The flag needs an admin path before
   it can be enforced: `CustomFields::BaseContract` lists its writable attributes explicitly
   (`app/contracts/custom_fields/base_contract.rb:35` onwards) and `PermittedParams#custom_field`
   lists them again (`app/models/permitted_params.rb:498`). `allow_project_values`,
   `option_pattern` and `option_pattern_description` must be added to both, and rendered in
   `CustomFields::DetailsForm`, or the rollout asks admins to set fields they cannot reach. The flag is what keeps this feature
   scoped to Labels rather than every list field in the instance. Introducing it without
   checking it in the write path makes it decorative — the same mistake as a form field
   marked required in a system that will not enforce it.
4. **Reject any value not carrying the project's own prefix.**
5. **Delete the option's `custom_values` in the same transaction.** `CustomOption` has no
   dependent cleanup of its own; the existing admin path does it by hand, calling
   `delete_custom_values!` *after* `destroy` succeeds
   (`app/controllers/concerns/custom_fields/shared_actions.rb:125`). A `DeleteService` that
   only destroys the option leaves every work package holding a value pointing at a row that
   no longer exists — invisible until something tries to resolve it.

   **The existing admin path has the same defect and should be moved onto this service.** It
   destroys the option and only then deletes the values
   (`app/controllers/concerns/custom_fields/shared_actions.rb:125`), with nothing wrapping
   the two, so a failure in between leaves dangling values. Documenting that and leaving it
   in place would mean shipping a feature whose system-admin path is less safe than its
   project-admin path — for the same operation. One transactional service, both callers.
6. **Pin `project_id` and `custom_field_id` on update.** Both must be treated as immutable:
   a permitted-parameter slip that lets either through turns "edit my label" into "move this
   option into another project, or onto another field", which no other validation would
   catch — the option would still be perfectly valid in its new home.

`projects.label_prefix` is admin-only. If project admins could edit it, they could rename
their own prefix at will and the governance would be decorative.

### UI

A `Projects::Settings::LabelsController` alongside the existing project settings
controllers: the project's own labels with full CRUD, its prefix shown read-only, and
system labels listed for reference. Showing the system tier in the same view is what stops
project admins re-creating a label that already exists globally.

## What the code has to do

There are **three** picker paths, and the method they share with query filters cannot simply
be scoped — an earlier revision of this document said two, and then told the same method to
both honour and ignore its project argument.

The conflict is real, not editorial. `possible_values_options(project)` serves two different
questions: *what may be applied here* (pickers) and *what exists to filter by* (queries, at
`app/models/queries/filters/shared/custom_fields/base.rb:68`). This design says pickers are
scoped and filtering stays global, so one method cannot answer both.

**Introduce a second method rather than changing the first.**
`CustomField#applicable_values_options(project)` narrows the list case and **delegates
everything else unchanged**. `possible_values_options` keeps its present meaning and
behaviour, and `possible_list_values_options` goes on ignoring its argument forever. Every
picker path moves to the new method; filters, exports and grouping are not touched.

The delegation is not optional politeness. `options_for_list` is reached for three formats,
not one: `user` and `version` both register `edit_as: "list"`
(`config/initializers/custom_field_format.rb:68` and `:75`), and `options_for_list` itself
branches on `custom_field.version?` to build grouped options. A list-only replacement would
strip version grouping and break user fields in the bulk edit form.

```ruby
def applicable_values_options(project = nil, options: {})
  if field_format == "list" && allow_project_values? && project
    applicable_list_values_options(project)
  else
    possible_values_options(project, options:)   # user, version, department, everything else
  end
end
```

The three paths:

- **The Angular work package form** reads the API schema, whose allowed values come from
  `list_schemas_values_callback` (`lib/api/v3/utilities/custom_field_injector.rb:410`) —
  one line: `represented.assignable_custom_field_values(custom_field)`. Scoping the method
  narrows this path.
- **The Primer work package create dialog** does not. `WorkPackages::Dialogs::CreateForm`
  includes `CustomFields::CustomFieldRendering`, which routes `list` to
  `CustomFields::Inputs::SingleSelectList` and `MultiSelectList`, and both enumerate
  `@custom_field.custom_options` directly (`app/forms/custom_fields/inputs/single_select_list.rb:66`,
  `app/forms/custom_fields/inputs/multi_select_list.rb:71`).
- **The legacy bulk edit and bulk move/copy forms** do not either, and reach the option list
  by a third route: `custom_field_tag_for_bulk_edit`
  (`app/helpers/custom_fields_helper.rb:74`) calls `options_for_list`
  (`app/helpers/custom_fields_helper.rb:143`), which calls
  `custom_field.possible_values_options(project)` — and `possible_list_values_options`
  ignores its argument entirely (`app/models/custom_field.rb:447`).

The third path needs both halves of the fix, and the second half is easy to miss.
`options_for_list` has to call `applicable_values_options` instead of
`possible_values_options` — **and the bulk move/copy form has to pass the right project**.
It currently passes the source:

```erb
<%= custom_field_tag_for_bulk_edit("", custom_field, @project) %>
```

(`app/views/work_packages/moves/new.html.erb:208`) while the same view uses `@target_project`
for assignee, responsible and budget on the lines just above. Scoping the lookup without
changing that line would filter a *move to another project* against the project the work
packages are leaving — the same class of mistake as resolving the copy filter's target from
the wrong key, and equally invisible in a test that only moves within one project.

Left as they are, the create dialog offers every private label in the instance and only
save-time validation rejects the choice — the worst outcome, since the user picks something
the form presented as valid.

The fix is to make the list inputs consistent with the version inputs, which already do the
right thing: `MultiVersionSelectList` builds its options from
`assignable_custom_field_values(@custom_field)`
(`app/forms/custom_fields/inputs/multi_version_select_list.rb:47`). The list inputs should
do the same, so all three picker paths and the validation read from one method.

| Path | Where | What changes |
|---|---|---|
| What can be applied | `app/contracts/concerns/assignable_custom_field_values.rb:37` | The `when "list"` branch returns bare `possible_values`. Must return the applicable set **plus any option already stored on the record** — but only for project-aware fields, see *Scope only project-aware fields*. |
| Enforcing it on save | `WorkPackages::BaseContract` | **Security.** Presentation is not enforcement — the API accepts any option id. A validation must reject *newly added* labels outside the applicable set and ignore stored ones — see *The validation algorithm*. |
| Primer list inputs | `.../inputs/single_select_list.rb:66`, `app/forms/custom_fields/inputs/multi_select_list.rb:71` | Build options from `assignable_custom_field_values`, as the version inputs already do, instead of enumerating `custom_options`. |
| Legacy bulk edit/move | `app/helpers/custom_fields_helper.rb:143` | `options_for_list` calls the new `applicable_values_options`, and `app/views/work_packages/moves/new.html.erb:208` must pass `@target_project`, not `@project`. |
| The applicable lookup | `CustomField#applicable_values_options` | New. Returns the applicable set for list fields. `possible_values_options` is left alone so filtering stays global. |
| The applicable set | `CustomOption.applicable_in(project)` | `project_id IS NULL OR project_id = ?`. One scope, used by both rows above so the picker and the validation cannot drift apart. |
| Option ownership | `CustomOption` | `belongs_to :project, optional: true`, tier scopes, shadowing validation, naming validation. |
| Narrow write path | `CustomOptions::*Service` | Create / update / delete authorising on `manage_project_labels`. |
| UI | `Projects::Settings::LabelsController` | Settings screen: the project's own labels with full CRUD, its prefix read-only, system labels for reference. |
| Copying a project | `app/services/projects/copy/work_packages_dependent_service.rb:159` | Drop project-owned labels from copied work packages — see below. |
| Deleting a project | `Project#remove_owned_labels` | Explicit `delete_all` of owned options and their `custom_values` — see above. |

Unchanged, and deliberately so:

- **Seeing a label.** Reading a stored value resolves the option by id and never consults
  the applicable set. Unrestricted display falls out for free.
- **Filtering and grouping.** Stays global — filtering is a read. If you can see a label on
  a work package you can filter by it. `possible_list_values_options` keeps ignoring its
  argument.

> The security row is the one to get right. Scoping `assignable_custom_field_values` only
> changes what the UI offers; the API still accepts any option id that exists. Without the
> contract validation, "a user may only apply labels his project has access to" is a
> suggestion, not a rule.

### Scope only project-aware fields

`AssignableCustomFieldValues` is not work-package-specific. It is included by
`WorkPackages::BaseContract`, `Projects::BaseContract` and `Users::BaseContract`
(`app/contracts/projects/base_contract.rb:34`, `app/contracts/users/base_contract.rb:33`),
so a naive change to the `when "list"` branch would alter every list custom field in the
product — project attributes and user attributes included.

Two things go wrong if it is not gated. `Users::BaseContract` has **no project at all**, so
the scoping has nothing to scope by and would either raise or silently return an empty list,
breaking every list-format user field. And project attributes would begin filtering their own
options by the project being edited, which means nothing for them.

The branch narrows only when both conditions hold:

```ruby
when "list"
  if custom_field.allow_project_values? && (project = customized_project)
    applicable_list_custom_field_values(custom_field, project)
  else
    custom_field.possible_values          # unchanged, for everything else
  end
```

`allow_project_values` earns a second job here. It was introduced to decide which fields
project admins may add values to; it doubles as the flag saying a field's values are
project-scoped at all. Both are the same question, and gating on it makes the default for
every existing field exactly today's behaviour.

### The validation algorithm

"Validate only newly added values" needs stating precisely, because the obvious
implementation validates the wrong set.

`SetAttributesService#set_custom_values_to_validate`
(`app/services/base_services/set_attributes.rb:69`) marks the **whole field** for
validation whenever that field appears in the params. So a contract that simply reads the
work package's label values sees every value the record now holds, including ones it already
had — and would reject an unrelated edit to a work package that moved projects, which is
exactly what retention is meant to prevent.

The split it needs is already made for it, one layer down. `custom_field_values=` routes to
`assign_new_values` (`lib_static/plugins/acts_as_customizable/lib/acts_as_customizable.rb:496`):

```ruby
(new_values - existing_cv_by_value.keys).each do |new_value|
  add_custom_value(custom_field_id, new_value)
end
```

Values that are genuinely new are **built as new records**; values the record already held
keep their persisted `CustomValue` rows; removed ones are marked for deletion. So:

> Validate the custom values for the Labels field that are `new_record?`, and only those.
> Each must be in `CustomOption.applicable_in(project)`. Persisted values are never checked.

That gives all the required behaviour from one rule: a moved work package stays editable,
adding one label to a field already holding an inapplicable one validates only the addition,
and removing an inapplicable label always works. It also makes the "unrelated edit" test a
genuine regression test rather than a formality — a naive implementation passes every other
case and fails that one.

### Defaults must stay system-only

A list field's default is built from the options flagged `default_value`
(`app/models/custom_field.rb:100`), and new work packages receive it automatically through
`acts_as_customizable`. That lookup has no project awareness, so a project label flagged as
default becomes the default **in every project** — assigning an inapplicable label
everywhere, or failing work package creation once the applicable-set validation is in place.

`CustomOption` therefore validates that `default_value` may only be true when `project_id`
is NULL. A project admin cannot set it at all, since the narrow write path refuses anything
but its own project's options; the validation is there to stop a system admin doing it by
hand, and to make the rule explicit rather than implied.

Making defaults project-aware instead — a per-project default label — is a larger feature
and deliberately out of scope.

### Copying: two paths, one filter, and one contract that never fires

Copying carries list option ids across **verbatim**, on both paths, and neither is covered
by the ordinary create/update lifecycle.

**Project copy.** `WorkPackagesDependentService#custom_value_attributes`
(`app/services/projects/copy/work_packages_dependent_service.rb:159`) special-cases exactly
one format — it nulls a *user* value when that user is not in the target project — and
copies everything else unchanged:

```ruby
source_work_package.custom_value_attributes.to_h do |id, value|
  if user_cf_ids.include?(id) && !target.users.detect { |u| u.id.to_s == value }
    [id, nil]
  else
    [id, value]      # list option ids land here
  end
end
```

**Work package copy**, single or bulk. `WorkPackages::CopyService#copied_attributes`
(`app/services/work_packages/copy_service.rb:84`) merges
`"custom_field_values" => work_package.custom_value_attributes` with no filtering at all.
`Bulk::CopyService` routes through the same method, so a cross-project bulk copy carries the
source project's labels into the target.

**Decision: drop project-owned labels that the target cannot apply, on both paths.** Keep
system labels. This is not only a scoping fix — a copy lands in a project with a different
prefix, so `AT-Bounce` in a project prefixed `ADT` is wrong by the naming rule too.

Put the filter in **one** helper — `WorkPackage#custom_value_attributes_for(target_project)`
— but understand that it has to be **called from both places**, because filtering only
`CopyService` does not reach project copy at all.

`copied_attributes` merges the source's values and then merges the caller's overrides on top:

```ruby
.merge("custom_field_values" => work_package.custom_value_attributes)
.merge(overwritten_attributes)          # the override wins
```

and `WorkPackagesDependentService#copy_work_package_attribute_overrides`
(`app/services/projects/copy/work_packages_dependent_service.rb:139`) supplies exactly that
key from its own `custom_value_attributes`. So a filter applied only in `CopyService` is
overwritten on every project copy — the path where no contract validation runs to catch it.
Both call sites must pass through the helper, or the filter must run after the merge.

**The helper must be field-aware, not value-aware.** `custom_value_attributes` is a bare
`custom_field_id => value` map and `custom_values.value` is untyped text shared by every
format. Dropping "values that look like inapplicable option ids" would delete an integer
custom field holding `99` because some project owned an option with id 99 — the same
cross-product mistake as the deletion cleanup, in a different place. The helper resolves the
field first, acts only on `list` fields whose `allow_project_values` is true, and leaves
every other format untouched:

```ruby
def custom_value_attributes_for(target_project)
  custom_value_attributes.to_h do |custom_field_id, value|
    field = available_custom_fields.find { |cf| cf.id == custom_field_id }
    next [custom_field_id, value] unless field&.field_format == "list" && field.allow_project_values?

    [custom_field_id, Array(value).select { |v| applicable_ids(field, target_project).include?(v.to_s) }]
  end
end
```

**The helper must resolve the target itself**, because the two callers name it differently.
Project copy builds attributes carrying a `project` object; bulk copy carries a
`project_id`, threaded from the move/copy form through `Bulk::CopyService`
(`app/services/work_packages/bulk/copy_service.rb:107` shows the same params being read as
`params[:project_id]`) into `WorkPackages::CopyService`. A helper that only understands one
form silently filters against the *source* project on the other path — which looks correct
in tests written for project copy and leaks on every bulk copy.

```ruby
def copy_target_project(attributes)
  attributes[:project] ||
    (attributes[:project_id] && Project.find_by(id: attributes[:project_id])) ||
    project   # unchanged: a copy within the same project
end
```

The `project` fallback matters as much as the other two: a same-project copy overrides
neither key, and must keep its labels rather than lose them to a nil target.

#### The contract cannot be relied on here

`WorkPackages::CopyProjectContract` (`app/contracts/work_packages/copy_project_contract.rb:45`)
overrides `valid?` to return `true` unconditionally and sets `validate_model? = false`:

```ruby
def valid?(_context = nil)
  # For project copying, we want to preserve the exact state
  # even if copied work packages would normally be invalid
  true
end

def validate_model? = false
```

So during a **project** copy, no contract validation runs at all. An earlier revision of this
document said the validation would reject an unfiltered copy; that is false on this path.
**The filter is the only protection**, and it needs a regression test that would fail if
someone removed it.

Work package copy is different: `WorkPackages::CopyService` defaults to
`WorkPackages::CopyContract`, which inherits `CreateContract` and does validate. There, an
unfiltered cross-project copy would *fail* rather than leak — a loud failure, but still a
broken feature, so the same filter applies.

Cloning the source project's label *definitions* into the target under its own prefix
(`AT-Bounce` → `ADT-Bounce`) is a plausible future convenience and deliberately out of
scope: it needs a rename strategy, a collision rule against existing target labels, and an
answer for what happens when the target has no prefix yet.

## The picker

`CustomFields::Inputs::MultiSelectList#list_items`
(`app/forms/custom_fields/inputs/multi_select_list.rb:71`) maps **every** option of the
field into the rendered list — no search, no pagination, no scoping.

Under an earlier revision, where every label was applicable everywhere, this was the
feature's biggest hazard: 500 projects with 20 labels each would have put a 10,000-item
list on every work package form. **Scoping application fixes it as a side effect** — the
list is bounded by the shared taxonomy plus one project's own vocabulary.

One residual: retention means a work package can carry labels outside the applicable set,
and those must still render as selected without becoming re-selectable once removed.
Returning `applicable + already stored` from one method handles it.

## Existing labels

Every current option becomes a system label automatically: the new column defaults to NULL.
No backfill, no behaviour change, nothing to coordinate on deploy.

The taxonomy that accumulated ad hoc is a separate, deliberate cleanup. Two read-only
reports make it tractable:

- **Non-conforming labels** — options failing the pattern, with usage counts.
- **Duplicate values** — options colliding case-insensitively within a field and tier.
  These block the unique indexes and must be merged or renamed before those can be added.
- **Demotion candidates** — options whose `custom_values` all sit on work packages in a
  single project. These are project labels that only ever *looked* global.

Renaming rewrites nothing in `custom_values`, since values reference option ids. Merging
two options does, and needs a value-rewrite step.

**Promotion is a one-way door, and it must not be raw SQL.** Promoting a project label to
system-level moves it between tiers, so it has to clear the shadowing check, the
case-insensitive uniqueness check for the system tier, and the system-only rule for
`default_value`. `UPDATE custom_options SET project_id = NULL` skips all three: before the
unique indexes exist it silently creates a cross-tier duplicate, and afterwards it raises a
bare `RecordNotUnique` from the database with nothing to show the admin.

Promotion is therefore a small service — set `project_id` to nil, run validations, save in a
transaction — that reports a collision as *"a system label named ADT-Bounce already exists"*
rather than failing at the database. No `custom_values` are rewritten either way, so it
remains a button rather than a migration.

The reverse is not symmetric, though not as severely as an earlier revision claimed.
Demoting a system label to one project **orphans nothing**: the option id does not change,
so every stored value stays valid, resolvable and visible, exactly as retention requires.
What changes is that the label becomes inapplicable everywhere else — other projects can no
longer add it, and once a user removes it from a work package they cannot put it back.

That is a real loss of function, so demotion still needs the usage report first. But it is a
narrowing, not a data-integrity event, and describing it as orphaning contradicts the
retention rule the rest of the design depends on.

## Rollout

1. **Schema and model, dark.** Migration (the unique index on `projects.label_prefix` is
   included and safe, being a new all-NULL column; the `custom_options` unique indexes are
   **not** — see *Uniqueness of label values*), `CustomOption` ownership, the `applicable_in` scope, the
   shadowing, uniqueness and naming validations, and `Project#remove_owned_labels`.
   `allow_project_values` stays false everywhere, so every label is system-level and every
   existing path behaves as it does today. This phase must be incapable of failing on
   existing data.
2. **Seed and confirm prefixes.** Generate a candidate `label_prefix` per project and have
   an admin confirm. No labels change.
3. **Scope what can be applied.** The `assignable_custom_field_values` change and the
   contract validation, with retention. Must land *before* the permission — afterwards,
   every new label would be applicable everywhere until this shipped.
4. **Permission and project UI.** `manage_project_labels` plus the data migration granting
   it, the narrow services, the settings screen. Enable `allow_project_values` on the Labels
   field. The bottleneck goes.

   **Set `option_pattern` first — it is a prerequisite of this phase, not part of phase 5.**
   `CustomField` validates that `allow_project_values` may only be true when `option_pattern`
   is present, so enabling the flag without it does not merely risk unconstrained labels: it
   fails. An earlier revision left the pattern in phase 5 and added the validation, which
   made the stated order impossible to execute rather than merely unwise. Configure the
   pattern and its description on the Labels field, then enable the flag, both inside this
   phase.
5. **Cleanup.** The pattern is already set (phase 4 cannot run without it). Run the
   non-conforming and duplicate reports, so admins can see what is already unsaveable-on-edit
   and what needs merging.
   Then set `option_pattern`, resolve the duplicates, and only afterwards add the unique
   indexes in their own migration — built concurrently, re-checking for duplicates first,
   and safe to re-run if a fresh collision appears in the window.

## Test coverage

The ordinary lifecycle is sound and needs only ordinary tests: `SetAttributesService`
validates the contract before `CreateService` / `UpdateService` save with `validate: false`,
so a contract validation added to `WorkPackages::BaseContract` is reached on every normal
create and update.

The cases worth naming are the ones that bypass or invert that path:

| Case | What it proves |
|---|---|
| Create via API with an inapplicable label | The contract, not the picker, is the enforcement point — the API accepts any option id. |
| Create via the Primer dialog | `WorkPackages::Dialogs::CreateForm` renders its own inputs; this fails if only the API schema was scoped. |
| Adding one label to a multi-value field that already holds an inapplicable one | Only the *added* value is validated. The naive implementation validates the whole set and rejects a legitimate edit. |
| An unrelated edit to a work package moved between projects | Retention. Changing the subject must not drop or reject labels the project can no longer apply. |
| Cross-project bulk work package copy | `WorkPackages::CopyService` merges custom values unfiltered; `CopyContract` would reject the result. |
| Project copy with a source-owned label | **The regression test that matters most.** `CopyProjectContract#valid?` returns `true`, so nothing else catches an unfiltered copy. If someone deletes the filter, only this test fails. |
| Deleting a project whose label is the last option on its field | Deletion **succeeds** and removes the owned options and their `custom_values`. This is the fixed behaviour, not the bug: `remove_owned_labels` uses `delete_all` precisely so `assure_at_least_one_option` cannot abort and leave a row for the foreign key to trip over. A test asserting the deletion fails would enshrine the defect. |
| Bulk move to another project, with a label the target cannot apply | The third picker path is scoped **and** the move form passes `@target_project`. A test that moves within one project passes either way. |
| Deleting a project label directly | The `custom_values` go with it, in one transaction, **paired by field** so an unrelated field's value with the same numeric text is untouched. |
| Deleting a project whose label is used by a work package in another project | The label is promoted, not deleted. Retention holds across the deletion of a project the work package does not belong to. |
| Editing a user or project custom field of list format | Unchanged behaviour. The `assignable_custom_field_values` gate keeps every non-project-aware field exactly as it is. |
| Filtering by a label the current project cannot apply | Still possible. Filtering reads `possible_values_options`, which the scoping deliberately does not touch. |
| Bulk editing a **user** or **version** custom field | Unchanged. Both register `edit_as: "list"`, so `applicable_values_options` must delegate for them — version grouping included. |
| Copying a work package carrying an integer custom field whose value equals a project label's option id | The copy filter is field-aware. The integer survives. |
| Project copy specifically, not just work package copy | The override in `WorkPackagesDependentService` wins the merge, so a filter applied only in `CopyService` would not run here at all. |
| Promoting on project deletion into an existing system label of the same name | The deletion succeeds, the option keeps its id, and the collision is reported rather than merged. |
| Rejecting a project option on a field with `allow_project_values` false | The flag is enforced, not decorative. |
| Updating an option with a foreign `project_id` or `custom_field_id` in the params | Both are pinned; an option cannot be moved between projects or fields. |
| Promoting a label whose name collides with an existing system label | Promotion runs validations rather than raw SQL. |

The first two and the last three each cover a place where an earlier revision of this
document was wrong. They are cheap to write and they are the ones that would have caught the
mistakes.

## Open decisions

**What happens the first time two projects want the same label?** Without shared prefixes,
a label meaning "bounce handling" needed by two projects has to exist twice, as `AT-Bounce`
and `ADT-Bounce`, or be promoted to a system label. Promotion is the intended answer, but it
routes through a system admin — the bottleneck this project set out to remove, reappearing
for exactly the cases shared prefixes were meant to cover.

Ship two tiers and count how often promotion is requested. That number decides between the
two extensions below, and it does not exist yet.


## What the implementation changed

Recorded so a reader can tell where the shipped code departs from the design above, and
why. Each came out of review of the code rather than of this document.

**Prefix changes migrate their labels** rather than leaving them as a legacy exception. See
the superseded section above.

**Cross-tier shadowing is symmetric.** This document said collisions must be blocked; the
first implementation checked only the project-onto-system direction, leaving an admin free
to rename a *system* label onto an existing project label. Both directions are now checked.

**The structural label format is enforced separately from `option_pattern`.** `LABEL_FORMAT`
was specified here and then never applied, so a permissive pattern — or none — accepted
`AT-` and `AT-lower`. It is now checked independently of the admin-configurable rule.

**Disabling `allow_project_values` is refused while owned options exist.** Turning it off
does not merely stop new labels: existing owned options stay attached to their project while
applicability falls back to every option, so one project's private labels became applicable
everywhere, and the screen that could remove them hid the field. Same shape as clearing a
prefix, and refused for the same reason.

**Lock ordering is part of the contract, not just lock presence.** The design specified a
per-field advisory lock. It did not say that a label write also needs the owning project row
— to read a committed prefix — nor that the two must be taken in one global order. Taking
the field lock first produced a `field → project` versus `project → field` cycle. The order
is now project row, then field lock, everywhere, and a spec asserts it.

**The advisory lock lives on `CustomOption`, not in the services.** There is more than one
writer: the project-admin services, the system-admin nested-attributes path, promotion
during project deletion, and seeds. Guarding the services alone left the race open for the
rest.

**`Project.new.destroy` had to be guarded.** `where(project_id: id)` with a nil id selects
`project_id IS NULL` — the system options — so building a project and discarding it deleted
the shared taxonomy. Not a scenario this document considered.

**Only the projects whose prefix actually changes are locked.** The admin screen submits
every project, so locking everything submitted took a row lock on the whole table to change
one prefix.

## Considered alternatives

### Making Labels a built-in work package field

The registry of built-in fields is the API schema representer:
`calculate_default_work_package_form_attributes` derives the whole type and form attribute
list from `WorkPackageSchemaRepresenter.representable_attrs` (`app/models/type/attributes.rb:123`).
A built-in is not a column — it is an entry threaded through every enumerated path.

The **Epic** field is this team's own built-in, added in commit `6488344`. It is the closest
available estimate, and an optimistic one, since Epic is a single-value foreign key where
Labels is multi-value: **35 files, 1,115 lines inserted, 5+ follow-up commits**, and one
loss to an upstream sync (commit `68df135`: "recover Epic link API/UI/backend implementation
… after branch sync removed the feature files").

What it would buy: structural scoping, an honest permission model, naming as a real model
validation, room for colour and description, and shedding inapplicable custom-field
semantics.

What it would cost:

- **No groupable or sortable many-to-many built-in exists.** Every entry in
  `property_selects` is a single foreign key column. The one many-to-many built-in,
  `watcher_id`, is filterable but absent from that registry — not groupable, not sortable.
  Custom fields already solve this: `app/models/custom_field/order_statements.rb` supplies
  `group_by_statement` / `group_by_join_statement` / `group_by_select_statement`, and
  `app/models/query/results/group_by.rb:135` already decodes concatenated multi-value group
  keys such as `"1.3"`. Going built-in means rebuilding working machinery, or shipping
  labels that cannot be grouped or sorted.
- **A data migration with user-visible breakage.** Values live in `custom_values`, and saved
  queries store filters, columns, sort criteria and grouping as serialised text referencing
  `cf_<id>` / `customField<id>`.
- **Loss of generic behaviour.** Journalling covers every custom field in one line;
  built-ins are enumerated by hand. Form configuration auto-includes custom fields.
- **Permanent merge exposure.** A built-in touches precisely the files upstream churns most.

The request is about governance. A built-in buys nothing for governance that a nullable
`project_id` does not, while adding a migration, saved-view breakage, a grouping rebuild
with no precedent, and recurring conflict exposure. The trigger to revisit is **capability,
not permissions**: if labels later need colour, description, ownership metadata or a
lifecycle, that is when `custom_options` genuinely runs out.

## Out of scope

- **A first-class `Label` entity.** See above.
- **Hierarchical labels.** `CustomField::Hierarchy::Item` already models parent/child values
  and carries a `short` column that would express the prefix natively. It is Enterprise-gated
  (`app/controllers/custom_fields_controller.rb:81`) and would mean converting the field
  format and migrating every value.
- **Letting one project apply another's labels.** Deferred, but the mechanism is chosen.
  Because `label_prefix` is unique per project, prefix and project are interchangeable, so a
  grant is expressed project-to-project — `label_grants(grantee_project_id,
  granting_project_id)` — and the applicable set widens from an ownership test to the same
  test plus a subquery. It stays one scope, nothing stored changes, and no migration is
  needed, which is why deferring costs nothing architecturally.

  Two things to settle if built. The prefix would describe an *owner* rather than a
  *domain*: `AT-Bounce` applied in AdTech reads as ArchTech's label, so genuinely shared
  vocabulary is still better served by promoting to a system label. And granted labels
  remain owned by the granting project, so `dependent: :destroy` would take them — and the
  grantee's stored values — when that project is deleted.
- **Per-role label permissions.** One project permission, held by project admins.
- **Retrofitting other list fields.** The `allow_project_values` flag makes it possible per
  field, but only Labels gets enabled.
- **Confidentiality.** Project labels are owned by one project and visible to all. This is a
  consequence of the visibility decision, not an oversight.
