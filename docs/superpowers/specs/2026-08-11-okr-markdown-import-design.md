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
  undo is covered by the result page (see "Undo").
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

Five pieces, each independently testable.

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
`Group.in_tree_order` (`app/models/groups/hierarchy.rb`), which returns
the whole tree depth-first with `hierarchy_depth` set; paths are
assembled in a single pass. Calling `Groups::Hierarchy#ancestry_path`
per row would issue two queries per department per line — for a
200-line document, the difference between one query and several hundred.
User lookup is batched the same way.

The resolver also runs `WorkPackages::CreateContract` against unsaved
records so required-field violations surface in the preview.

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

### `WorkPackages::Import::CreateJob`

GoodJob worker. Walks the resolved tree top-down calling
`WorkPackages::CreateService` — not raw ActiveRecord, so contracts,
journals, and attribute patterns all behave normally — with
`send_notifications: false`. The whole walk runs in one transaction.

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
| `create` (POST) | Enqueue the job |
| `show` | Result page |

Guarded by a new permission `import_work_packages`, declared in
`config/initializers/permissions.rb` in the work-packages module
alongside `add_work_packages` (line 323), with
`permissible_on: :project` and
`dependencies: %i[view_work_packages add_work_packages]` — the existing
DSL option used by every neighbouring permission, so a role cannot be
granted import without also being able to create work packages.

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
page links to a work package table filtered to exactly the IDs just
created. `WorkPackages::BulkController#destroy` already deletes a
selection in one action.

This gives a working undo with no new table, no new model, and no new
destroy path — reusing two things that already exist.

## Testing

Weighted toward the cheap end.

- **`OutlineParser`** — table-driven unit specs, no database. Most
  format edge cases are pinned here and run in milliseconds.
- **`Resolver`** — one spec per format converter, plus ambiguity cases
  (two users named Jane Doe; "Retention" appearing under two branches).
  Assert the department lookup issues one query, not N.
- **`CreateJob`** — rollback on mid-tree failure; `send_notifications:
  false` actually suppresses mail.
- **Request specs** — 403 without `import_work_packages`; `preview`
  creates no records.
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
