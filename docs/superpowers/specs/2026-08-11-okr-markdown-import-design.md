# Markdown Work Package Import — Design

**Date:** 2026-08-11
**Status:** Draft (pending approval)

## Goal

Let a planning author paste a structured Markdown document into a
project and have its hierarchy created as work packages in one action —
with a preview of exactly what will be created before anything is
written.

The driving use case is quarterly OKR planning (see
`docs/customization/Company OKR Framework.md` and
`docs/customization/Department and Team OKR Process.md`), where each
quarter departments hand in Objectives and Key Results and someone has
to key them into the `Company OKRs` project one work package at a time.
A quarter's worth of OKRs is 3–5 Objectives per department, 2–5 Key
Results each, plus supporting Tasks — hundreds of manual form
submissions.

**The importer itself knows nothing about OKRs.** That is a deliberate
design constraint, argued in "Why generic, not OKR-specific" below.

## Motivating use case

The `Company OKRs` project is already configured in production with:

- Work package types: Strategic Initiative, Objective, Key Result, Task
- Versions as quarters (`FY2026 Q3`, `FY2026 Q4`, …)
- Custom fields: Organizational Unit (`department` format), OKR Health,
  Confidence, Baseline, Target, Current Metric, Progress %, Last
  Check-in
- Accountable (`responsible`) as the single-owner field

The hierarchy is `Strategic Initiative → Objective → Key Result → Task`.
Source documents currently arrive in assorted formats; departments will
be asked to adopt the Markdown template defined here.

## Requirements (confirmed)

- **Recurring**, every quarter, run by department leads themselves — not
  a one-off backfill and not a developer-only script.
- **Markdown** source, pasted as text. Departments will reformat their
  documents to the template rather than the importer guessing at prose.
- **Create-only, always new.** No duplicate detection, no upsert. A
  second run of the same document creates a second set of work packages;
  the result page records exactly what was created, and offers one-click
  removal to users who also hold delete rights (see "Undo").
- **Lenient lookups.** People may be written as an email address *or* a
  display name; org units as a full path *or* an unambiguous leaf name.
  Ambiguity is an error, not a silent guess.
- **Preview before write.** Nothing is created until the author confirms
  a rendered preview.
- **No type-nesting rules.** The document's structure is the hierarchy.

## Prerequisite

The `department` custom field format must be present. It is on
`origin/epic` (`config/initializers/custom_field_format.rb:79`, PR #102 /
#103) but was **not** in the local working copy at design time, which was
21 commits behind. Pull before implementing.

## Why generic, not OKR-specific

The obvious framing is "an OKR importer". The better one is "a Markdown
outline importer that happens to be used for OKRs", for three reasons:

1. **It is less code, not more.** An OKR-aware importer needs a table
   mapping "OKR Health" → custom field 7, "Baseline" → custom field 9,
   and so on, kept in sync with the instance by hand. A generic importer
   resolves attribute names against the project's actual custom fields
   and needs no such table.
2. **It survives configuration drift.** If Organizational Unit is
   re-created as a different format, or a new field is added to the OKR
   framework next year, the importer needs no change.
3. **It is reusable.** The same feature imports any work package
   hierarchy — project kickoff structures, migration backlogs — at no
   extra cost.

Consequently no OKR term appears anywhere in the implementation.

## Document format

Heading depth carries the hierarchy. An explicit type prefix makes each
line self-documenting and independent of heading level. A bullet block
immediately under a heading carries attributes; any remaining prose
becomes the description.

```markdown
---
Project: Company OKRs
Version: FY2026 Q3
---

# Strategic Initiative: Subscription Growth

## Objective: Increase subscriber retention
- Accountable: jane.doe@example.com
- Organizational Unit: Marketing / Retention
- OKR Health: On Track
- Confidence: 80%

We expect retention gains to come mainly from onboarding improvements.

### Key Result: Increase annual renewals from 65% to 75%
- Accountable: sam.lee@example.com
- Baseline: 65%
- Target: 75%
- Current Metric: 67%
- Progress: 20%
- OKR Health: On Track
- Confidence: 75%

#### Task: Rework the renewal reminder sequence
```

Rules:

- **Front matter** (optional) sets document-level defaults. `Version` is
  the common one. `Project` is an optional *assertion*, not a target
  selector — the target project always comes from the URL, since the
  controller is project-scoped. If present and it does not match the
  project being imported into, the import is rejected. This exists so a
  document written for one project cannot be pasted into another by
  accident.
- **Heading line** is `<Type name>: <Subject>`. The type must exist and
  be enabled in the target project.
- **Heading depth** determines parenthood. The first heading in the
  document establishes the root depth; all other depths are relative to
  it, so a document may start at `#` or `##` as long as it is internally
  consistent. Depth may not skip a level. Multiple roots in one document
  are allowed — e.g. several Strategic Initiatives.
- **Bullet block** directly under a heading is `Attribute: value`. It
  ends at the first non-bullet line.
- **Remaining prose** under the heading becomes `description`.
- **Inheritance:** front matter defaults, and any attribute set on an
  ancestor, flow downward unless overridden. This is what makes the
  format tolerable to write — `Version` and `Organizational Unit` are
  stated once, not on every line.

The document remains valid, readable Markdown, so it stays usable as a
document in any editor.

## Architecture

Six pieces, each independently testable.

### `WorkPackages::Import::OutlineParser`

Pure function: Markdown string in, array of nodes out. Each node carries
`level`, `type_name`, `subject`, `attributes` (hash of raw strings),
`description`, and `source_line`.

Touches no database and knows nothing about OpenProject. Every format
edge case is a fast unit test with no fixtures.

### `WorkPackages::Import::Resolver`

Takes parsed nodes plus a target project; returns resolved rows and
errors. This is where attribute *names* become real fields and attribute
*strings* become real records.

Name resolution, in order:

1. **Built-in labels** — Accountable → `responsible`, plus Assignee,
   Version, Status, Priority, Start date, Finish date.
2. **Custom field name** — any other attribute is matched against the
   custom fields enabled for that type in that project.

Value conversion is per format:

| Format | Accepted input |
|---|---|
| `department` | `Marketing / Retention` (full `ancestry_path`), or an unambiguous leaf name |
| `user` | email address, or an unambiguous display name |
| `list` | option value |
| `hierarchy` | `Parent / Child` path |
| `version` | version name within the project |
| `date` | ISO `YYYY-MM-DD` |
| `int`, `float` | numeric, tolerating a trailing `%` |
| `bool` | yes/no, true/false |
| `string`, `text` | verbatim |

**Department lookup builds its table once per import** via
`Group.organizational_units.in_tree_order`, the idiom already used by
`app/models/custom_field.rb:233` for this exact format. The
`organizational_units` scope is required, not optional: bare
`Group.in_tree_order` loads *all* groups including regular security
groups, which would produce false matches and spurious ambiguity errors
against names that are not org units at all. Scoping is safe because
`Group#no_organizational_unit_mismatch` forbids mixed-flag parentage, so
an org-unit tree never has a regular group as an ancestor.

`in_tree_order` returns the tree depth-first with `hierarchy_depth` set,
so paths are assembled in a single pass. Calling
`Groups::Hierarchy#ancestry_path` per row would issue two queries per
department per line — for a 200-line document, the difference between
one query and several hundred. User lookup is batched the same way.

**The resolver runs the real preparation pipeline, not just the
contract.** It calls `WorkPackages::SetAttributesService` against unsaved
records, which applies default attributes (priority, author, responsible,
status, start and due dates — `set_attributes_service.rb:178`) and
validates through `WorkPackages::CreateContract` in one step. Running the
contract alone would show the author a preview missing every defaulted
value, and creation would then produce work packages that differ from
what was approved.

Writability of built-in fields is left entirely to the contract rather
than re-implemented in the resolver. This matters for one field in the
OKR set: if "Progress %" is mapped to the built-in % Complete rather
than to a custom field, whether it accepts a written value depends on
the instance's progress calculation mode. The resolver does not try to
predict that — it offers the value and reports whatever the contract
says, so an unwritable field shows up as a normal preview error against
its source line instead of failing at creation time.

### `WorkPackages::Import::PreviewComponent`

Renders the resolved tree as it will be created — each row showing type,
subject, and every attribute with its matched record spelled out
(`Accountable: Jane Doe (jane.doe@example.com)`). Errors appear inline
against their source line.

**Three classes of value cannot be known before creation**, and the
preview marks them as computed rather than showing a value it cannot
guarantee:

1. **Type patterns.** `CreateService#create` calls `apply_patterns`
   *after* `save` (`create_service.rb:65`), and
   `Types::ApplyPatterns#apply_patterns` calls `pattern.resolve(model)`
   on the saved record. A subject pattern referencing the work package
   ID is unknowable pre-save by construction.
2. **Scheduling side effects.** `reschedule_related` and
   `multi_update_ancestors` run after each save and can shift dates on
   the record and its ancestors.
3. **Derived roll-ups** — `derived_done_ratio`,
   `derived_estimated_hours`, `derived_remaining_hours` are
   `writable: false` and computed from descendants that do not exist yet.

Fields in these categories render as "computed on creation" with the
pattern or rule named. Everything else in the preview is exact, because
it came through the same `SetAttributesService` that creation will use.

### `WorkPackages::ImportRun` (new table)

A durable record per import, created when the author confirms. Columns:

| Column | Purpose |
|---|---|
| `project_id` | Authorization scope for the result page |
| `user_id` | Who ran it; owner of the run |
| `status` | queued / running / succeeded / failed |
| `source` | The pasted Markdown, for diagnosis |
| `created_work_package_ids` | Array; populated on success |
| `failure` | jsonb: source line, message |

This exists because the asynchronous flow has nowhere else to keep its
results. `JobStatus::ApplicationJobWithStatus#store_status?` returns
`!status_reference.nil?`, so a job only gets a persisted status if it
supplies an ActiveRecord `status_reference` — and `job_statuses` carries
a **unique** index on `[reference_type, reference_id]`
(`modules/job_status/db/migrate/tables/job_statuses.rb:38`). Referencing
the Project would therefore permit exactly one import status per project
for all time. An import-run record is the natural reference.

The run is the `status_reference`, giving the standard job status dialog
for free. `JobStatus::Status` also has a `payload` jsonb column, but the
run record remains the source of truth: it must outlive job status
records, which `JobStatus::Cron::ClearOldJobStatusJob` prunes.

### `WorkPackages::Import::CreateJob`

GoodJob worker, `status_reference` = the import run. Walks the resolved
tree top-down calling `WorkPackages::CreateService` — not raw
ActiveRecord, so contracts, journals, and attribute patterns all behave
normally — with `send_notifications: false`. The whole walk runs in one
transaction; on success it writes the created IDs to the run, on failure
it records the offending source line and message and rolls back.

`send_notifications: false` is not optional: a 200-item import would
otherwise generate a notification storm for every watcher and assignee.
The API precedent is `notify_according_to_params`
(`lib/api/v3/work_packages/work_packages_api.rb:62`).

### `WorkPackages::ImportsController`

Project-scoped, four thin actions:

| Action | Behaviour |
|---|---|
| `new` | Page with one large textarea |
| `preview` (POST) | Parse + resolve, write nothing, render preview |
| `create` (POST) | Create the import run, enqueue the job, redirect to `show` |
| `show` | Result page for one run |

`show` authorizes on the run's `project_id` — the same project-scoped
`import_work_packages` check as every other action — so a run is not
readable from outside its project.

Guarded by a new permission `import_work_packages`, declared in
`config/initializers/permissions.rb` in the work-packages module
alongside `add_work_packages` (line 323), with `permissible_on: :project`
and:

```ruby
dependencies: %i[view_work_packages add_work_packages
                 manage_subtasks assign_versions]
```

All four are required, not defensive padding. `WorkPackages::BaseContract`
declares `attribute :parent_id, permission: :manage_subtasks` and
`attribute :version_id, permission: :assign_versions`. Since this
importer's entire purpose is creating a *hierarchy*, and the OKR
documents set `Version` on every item, a role holding only
`view_work_packages` and `add_work_packages` could not import the sample
document in this spec — every row below the root would fail on
`parent_id`, and every row would fail on `version_id`. The dependency
list makes the permission honest about what it actually needs.

## Error handling

Two classes of error, one gate.

**Parse errors** — unknown type name, heading depth skips a level,
attribute bullet before any heading, malformed front matter, duplicate
attribute key. Reported with source line number.

**Resolution errors** — unknown or ambiguous user, unknown org unit or
ambiguous leaf name, unknown version/status/priority, custom field not
enabled for that type in this project, value invalid for its format,
required field missing.

The preview is the only gate: all errors listed with line numbers,
confirm disabled while any remain. The author fixes the document and
re-pastes.

**Known limitation:** at preview time parents do not yet exist, so
parent-dependent contract validations cannot be fully evaluated. The
transaction covers that residue — if a contract rejects something
mid-tree, the entire run rolls back and the result page names the
offending line. A half-imported quarter is not a reachable state.

## Undo

Because the importer is create-only, running the same document twice
duplicates everything. Rather than build duplicate detection, the result
page reads `created_work_package_ids` off the import run and links to a
work package table filtered to exactly those IDs.
`WorkPackages::BulkController#destroy` deletes that selection in one
action.

**The link is conditional on `delete_work_packages`.** That permission
covers `"work_packages/bulk": %i[destroy reassign]` with
`require: :member` (`config/initializers/permissions.rb:434`), and
`import_work_packages` does not imply it. A user with import rights but
no delete rights still sees the full list of what was created — enough
to hand to someone who can remove it — but is not shown an undo control
that would fail.

Deliberately **not** done: adding `delete_work_packages` to the import
permission's dependencies, which would let anyone who can import delete
any work package in the project; and building an import-scoped delete
path that bypasses `delete_work_packages`, which would be a change to
the permission model smuggled in under a convenience feature. Undo is a
convenience here, not a requirement — the preview gate is the real
safeguard, and the run record preserves the evidence either way.

## Testing

Weighted toward the cheap end.

- **`OutlineParser`** — table-driven unit specs, no database. Most
  format edge cases are pinned here and run in milliseconds.
- **`Resolver`** — one spec per format converter, plus ambiguity cases
  (two users named Jane Doe; "Retention" appearing under two branches).
  Assert the department lookup issues one query, not N. **Include a
  regular security group whose name collides with an org unit** and
  assert it is never matched — this is the specific bug that bare
  `Group.in_tree_order` would introduce.
- **Preview fidelity** — the highest-value spec in the suite: run a
  document through preview, then through creation, and assert every
  previewed value matches the created work package except the three
  documented computed categories. This is what stops the preview from
  silently drifting from creation as `SetAttributesService` evolves.
- **`CreateJob`** — rollback on mid-tree failure leaves zero work
  packages and a `failed` run carrying the source line;
  `send_notifications: false` actually suppresses mail; a successful run
  records every created ID.
- **Permission specs** — a role with exactly
  `import_work_packages`'s declared dependencies can import the sample
  document from this spec end to end. This is a direct regression test
  for the `manage_subtasks` / `assign_versions` omission, and it fails
  loudly if a future contract change adds another permission-gated
  attribute.
- **Request specs** — 403 without `import_work_packages`; `preview`
  creates no records; `show` is not readable from another project; the
  undo link is absent without `delete_work_packages` and present with it.
- **One feature spec** end-to-end on the real shape: Strategic
  Initiative → Objective → Key Result → Task with a Department custom
  field, paste through to confirm.

## Out of scope

Each is a clean follow-up; none is needed for quarterly planning.

- File upload — paste only.
- Upsert / update of existing work packages.
- Scheduled or automated imports.
- Multi-project imports in one document.
- Spreadsheet formats (`.csv`, `.xlsx`).
- Enforcing OKR nesting rules.

## Translations

All user-facing strings go in `config/locales/en.yml`. No hard-coded
text, per project convention.
