# Feature Specification: "Release" (OpenProject implementation)

> **Status:** Draft for implementation.
> **Supersedes / refines:** `fix_version_feature_specification.md` (generic Jira-style draft).
> This version is rewritten against OpenProject's actual data model and conventions so it
> can be implemented directly. Key change vs. the original draft: OpenProject already ships
> a `Version` model that is ~85% of Jira's "Fix Version". We **extend Version** rather than
> build a parallel entity.

---

## 0. Context & Key Decisions

### 0.1 What already exists in OpenProject (do not rebuild)
OpenProject's `Version` is functionally Jira's "Fix Version":

| Concern | Where it lives today | State |
| :--- | :--- | :--- |
| Version model (`name`, `description`, `status`, `start_date`, `effective_date`, `sharing`, `wiki_page_title`, custom fields) | [app/models/version.rb](../app/models/version.rb) | Complete |
| Status enum `open` / `locked` / `closed` | [version.rb:39](../app/models/version.rb#L39) (`VERSION_STATUSES`) | Complete |
| Cross-project sharing `none/descendants/hierarchy/tree/system` | [app/models/versions/project_sharing.rb](../app/models/versions/project_sharing.rb) | Complete |
| Work-package link (single `version_id`) | [work_package.rb:61](../app/models/work_package.rb#L61) | Complete |
| Roadmap / overview UI (progress %, open/closed counts) | [app/controllers/versions_controller.rb](../app/controllers/versions_controller.rb), [app/views/versions/](../app/views/versions/) | Complete |
| Project settings CRUD | [app/views/projects/settings/versions/show.html.erb](../app/views/projects/settings/versions/show.html.erb) | Complete |
| REST API v3 (CRUD + forms + available_in_projects) | [lib/api/v3/versions/](../lib/api/v3/versions/) | Complete |
| Services / contracts (`BaseServices` pattern) | [app/services/versions/](../app/services/versions/), [app/contracts/versions/](../app/contracts/versions/) | Complete |
| Query filters (versions + WP-by-version) | [app/models/queries/versions/filters/](../app/models/queries/versions/filters/), [app/models/queries/work_packages/filter/version_filter.rb](../app/models/queries/work_packages/filter/version_filter.rb) | Complete |
| Permission `:manage_versions` | [config/initializers/permissions.rb:228](../config/initializers/permissions.rb#L228) | Complete |
| Custom field of **format `version`** on work packages (single or multi-value) | [config/initializers/custom_field_format.rb:72](../config/initializers/custom_field_format.rb#L72), [app/models/custom_value/version_strategy.rb](../app/models/custom_value/version_strategy.rb) | Complete |

### 0.2 The local constraint: `version_id` is already "Sprint"
This deployment uses the native `version_id` (and the Backlogs module's `Sprint < Version`)
as **Sprint**. Therefore:

- **`version_id` MUST NOT change meaning.** Release cannot reuse `version_id`.
- A separate link from work package → Release is required.

### 0.3 Relationship to the in-flight `Agile::Sprint` refactor
The repo contains an early refactor moving Sprint to a first-class model
([agile/sprint.rb](../modules/backlogs/app/models/agile/sprint.rb), `sprints` table,
`sprint_id` on work packages, migrations dated 2026-02-02). It has model + services +
contracts + journaling + taskboard drag-drop, **but** sharing/visibility is stubbed
(`scope :visible, -> { all }`, TODO #71374/#71253), and it has **no API and no management UI**.

**Implication:** Release should **not** depend on `Agile::Sprint`. The native `Version`
already provides the mature sharing/API/UI/filters that `Agile::Sprint` still lacks, so
Release is best built on `Version`. (`Agile::Sprint` remains a useful reference pattern only.)

### 0.4 Chosen architecture (the decision this spec implements)
1. **"Release" is a `Version`** — reuse the existing model, sharing, API, roadmap, filters,
   and `:manage_versions` permission.
2. **Distinguish Release-versions from Sprint-versions** via a new `kind` attribute on
   `versions` (`generic` | `sprint` | `release`, default `generic`). This is the only
   net-new column.
3. **Work package → Release link** is a **`version`-format custom field**, scoped to
   `kind = release` versions. Multi-value = configurable (single by default; enabling
   multi-value yields Jira's many-to-many "Fix Version/s").
4. **Net-new behaviour** (release workflow + roll-forward, release notes generator,
   readiness dashboard) is layered onto the existing Version controller/views/services.

### 0.5 Resolved decisions
- **D1 — Cardinality: multi-value.** The Release work-package field is a **multi-value**
  `version`-format custom field (Jira-style many-to-many "Release/s"). A work package may be
  assigned to zero, one, or many releases.
- **D2 — UI naming: "Release".** The `kind = release` versions are presented as
  **"Release(s)"** throughout the UI/locales. Code/model stays `Version` (with `kind`);
  only the user-facing labels change. `kind = sprint`/`generic` versions keep their existing
  "Version"/"Sprint" labels.
- **D3 — Status vocabulary: keep `open/locked/closed`.** No Jira-style relabeling and no
  "Archived" state. Releases use the existing status enum and badges as-is.
- **D4 — "Affects Version": out of scope** for this iteration.

**Core principle (D2/kind):** Release and Sprint are **two separate selection sets**, both
stored in the `versions` table and distinguished by `kind`. A project admin can create
either a Release (`kind = release`) or a Version/Sprint from its respective screen. The
separation is enforced **at reference/selection time**: the Release field offers only
`kind = release` versions, and the Sprint/Version UI offers only its own kind. Names remain
**globally unique within a project** (across all kinds) — any duplicate name is rejected, as
today. (We do *not* allow a Release and a Sprint to share a name.)

---

## 1. Data Model

### 1.1 `versions.kind` (new)
Add a `kind` string column to `versions`:

```ruby
# db/migrate/<ts>_add_kind_to_versions.rb
add_column :versions, :kind, :string, null: false, default: "sprint"
add_index  :versions, :kind
# All pre-existing rows are backfilled to "sprint" by the default above
# (this deployment uses versions as sprints). No data backfill step needed
# beyond the column default, since the column is added NOT NULL with default "sprint".
```

- Allowed values: `sprint`, `release` (constant `Version::VERSION_KINDS`).
- **Default `sprint`** — both for backfill of existing rows and for new rows. This means the
  entire existing Version/Sprint stack (forms, services, API, roadmap) keeps producing
  `kind = sprint` versions with **zero code changes**; only the new Release flow sets
  `kind = release` explicitly.
- *(Optional, for upstream/vanilla compatibility: a third `generic` value could be added
  later. Not used in this deployment.)*

Model changes in [app/models/version.rb](../app/models/version.rb):
```ruby
VERSION_KINDS = %w(sprint release).freeze
validates :kind, inclusion: { in: VERSION_KINDS }

scope :releases, -> { where(kind: "release") }
scope :sprints,  -> { where(kind: "sprint") }
def release? = kind == "release"
def sprint?  = kind == "sprint"
```

> **Name uniqueness is unchanged.** Names stay globally unique within a project across all
> kinds — the existing model validation (`uniqueness: { scope: [:project_id] }`,
> [version.rb:42](../app/models/version.rb#L42)) and DB index
> `index_versions_on_project_id_and_LOWER_name` on `(project_id, LOWER(name))` are kept as-is.
> Separation between Releases and Sprints is enforced at selection time (§1.4), not via names.

### 1.2 Status vocabulary (D3 — unchanged)
Releases use OpenProject's existing `open` / `locked` / `closed` statuses and their existing
badges. **No** Jira-style relabeling (`Unreleased`/`Released`/`Archived`) and **no** separate
"Archived" state are introduced. The "Release" action (§3.1) transitions a release to
`closed`.

### 1.3 Work package → Release link
A **`WorkPackageCustomField` of `field_format: "version"`**, seeded/admin-created as
"Release":

- Selectable values resolve through [custom_field.rb:460 `deduce_versions`](../app/models/custom_field.rb#L460),
  which today returns `project.shared_versions`. **Add scoping by `kind`** so the Release
  field offers only `kind = release` versions (see §1.4).
- **`multi_value = true`** (D1) — a work package may reference many releases.
- `allow_non_open_versions` ([custom_field.rb:366](../app/models/custom_field.rb#L366)) controls
  whether closed/released versions remain selectable.
- Automatically integrates with WP detail panel, API custom-field values, and query filters
  ([custom_field_filter.rb:97](../app/models/queries/filters/shared/custom_field_filter.rb#L97)
  maps `version` → `ListOptional`).

### 1.4 Scoping the Release CF to `kind = release`
`deduce_versions` is currently global. Extend it so a version CF can constrain by kind.
Minimal approach — add an option threaded from the CF:

```ruby
# app/models/custom_field.rb (deduce_versions)
def deduce_versions(project, options: {})
  scope =
    if project&.persisted? then project.shared_versions
    elsif options[:scope] == :visible then Version.visible
    else Version.systemwide
    end
  options[:kind] ? scope.where(kind: options[:kind]) : scope
end
```

Then have the Release CF pass `kind: "release"`. Prefer a declared CF attribute
(e.g. a `version_kind` setting on the custom field) over hard-coding, so the mechanism is
reusable.

### 1.5 Keeping releases out of the Sprint/Version selectors (required)
Releases are stored as `Version` rows, so **without scoping they would also appear in the
native `version_id` (Sprint) selectors** — filters, the WP form, the project version
settings, the roadmap, and the Backlogs taskboard. To preserve the two-set separation, the
Sprint/Version side must be scoped to `kind = sprint` (i.e. exclude `kind = release`):

- **Native version selectors:** the WP `version_id` field options come from
  `project.shared_versions`. Scope these to `.sprints` where the field is presented as
  Sprint/Version (WP detail, bulk edit, version filter
  [version_filter.rb](../app/models/queries/work_packages/filter/version_filter.rb)).
- **Project version settings + roadmap** ([versions_controller.rb](../app/controllers/versions_controller.rb),
  [projects/settings/versions](../app/views/projects/settings/versions/show.html.erb)): list
  `Version.sprints` so releases don't show up on the existing Versions screen (they live on
  the new Releases screen, §2.1).
- **Backlogs:** `Sprint < Version` / `VersionSetting` queries should likewise be `.sprints`-scoped.

> This is the single biggest "don't forget" item: every place that today lists versions must
> declare which kind it wants. Audit checklist is in §9.

---

## 2. UI / UX

### 2.1 Releases management (project level)
Reuse the existing Version settings + roadmap, filtered to `kind = release`:

- **Entry point:** new "Releases" item in the project sidebar/settings, rendering the
  existing versions table component ([app/components/versions/table_component.rb](../app/components/versions/table_component.rb))
  scoped to `Version.releases`. Sprint/generic versions stay in their current screens.
- **Create/Edit form:** reuse [app/forms/versions/form.rb](../app/forms/versions/form.rb); set
  `kind = release` on create from this screen; expose `name`, `start_date`,
  `effective_date` (Release date), `description`, `sharing`, `wiki_page_title`.
- **Table:** reuse existing columns (name, status badge, progress, dates, actions). Map
  status labels per §1.2. Actions: Edit, **Release** (when `open`), Delete (§3).

### 2.2 Release hub page (readiness dashboard — in scope)
Extend the existing version `show` ([versions_controller#show](../app/controllers/versions_controller.rb),
[app/views/versions/show.html.erb](../app/views/versions/show.html.erb)), which already computes
`completed_percent`, `closed_percent`, `open_issues_count`, `closed_issues_count`
([version.rb:115-162](../app/models/version.rb#L115)). Add:

- **Progress bar** by issue count (exists) and optionally by story points
  (Backlogs already tracks `story_points`; reuse if Backlogs enabled).
- **Issue table** of work packages where the Release CF references this version
  (filter via the version CF, not `version_id`). Sortable/filterable by type, assignee,
  status — reuse work-package query infrastructure.
- **Status segments:** Done / In progress / To do mapped from status categories
  (`done_statuses`, open/closed) already available on the project.

### 2.3 Assigning work packages to a Release
- **WP detail panel:** the Release CF renders as a standard custom-field autocompleter
  (single or multi). No new code.
- **Bulk edit:** work packages already support bulk-editing custom fields; the version CF
  participates automatically. (Append/replace/clear semantics for multi-value follow the
  existing multi-value CF bulk behaviour.)

---

## 3. Release Lifecycle & Workflow (in scope)

### 3.1 "Release" action with roll-forward (net-new)
Implement as a dedicated service, mirroring the existing `Versions::UpdateService`
([app/services/versions/update_service.rb](../app/services/versions/update_service.rb)) and the
existing bulk `close_completed` action in [versions_controller.rb](../app/controllers/versions_controller.rb).

`Versions::ReleaseService` (new):
1. **Incomplete check:** find work packages whose Release CF references the target version
   and whose status category ≠ closed/done.
2. **Resolution strategy** (passed in by the dialog):
   - **Roll forward:** reassign the Release CF on incomplete WPs to another `open`
     release version.
   - **Decouple:** clear the Release CF value on incomplete WPs.
   - **Force:** leave them mapped.
3. **Transition:** set version `status = closed`; record release timestamp. OpenProject has
   no `actual_release_date` column — either reuse `effective_date` semantics or add
   `released_at` (small migration). **Recommendation:** add `released_at:datetime` for an
   accurate audit timestamp (the draft's `actual_release_date`).
4. Wrap in a `ServiceResult`; journal the changes.

Contract: `Versions::ReleaseContract` enforcing `:manage_versions` and a valid roll-forward
target. UI: a Primer dialog offering the three strategies + target-version selector.

### 3.2 Archive / Delete
- **Delete:** reuse [app/services/versions/delete_service.rb](../app/services/versions/delete_service.rb).
  `has_many :work_packages, dependent: :nullify` covers `version_id`; for the Release CF,
  add cleanup of `custom_values` referencing the deleted version (or offer "reassign to
  another release" like the draft's fallback route). Surface a destructive-action dialog
  when the version is referenced.
- **Archive:** only if Q3 confirms it's needed (see §1.2).

---

## 4. Release Notes Generator (in scope)

Net-new, but builds on the existing `wiki_page_title` link
([version.rb:164](../app/models/version.rb#L164)).

- **Source set:** work packages whose Release CF references the version **and** whose status
  category = done/closed.
- **Grouping:** by work-package type (Feature / Bug / Task …), then sorted.
- **Output:** rendered Markdown/HTML block on the Release hub page, with:
  - **Copy/Export** action, and
  - optional **"Write to wiki page"** that populates the linked `wiki_page` (reuse existing
    wiki integration), giving a persisted, versioned release-notes artifact.
- Implement as a presenter/component (e.g. `Versions::ReleaseNotesComponent`) reading from a
  work-package query; no schema change.

---

## 5. API (REST v3)

Reuse the existing versions API ([lib/api/v3/versions/](../lib/api/v3/versions/)):

- `kind` is exposed as a new property on
  [version_representer.rb](../lib/api/v3/versions/version_representer.rb) and writable via the
  existing create/update endpoints + schema
  ([version_schema_representer.rb](../lib/api/v3/versions/schemas/version_schema_representer.rb)).
- `GET /api/v3/versions?filters=[{"kind":{"operator":"=","values":["release"]}}]` to list
  releases (add a `kind` version filter under
  [app/models/queries/versions/filters/](../app/models/queries/versions/filters/)).
- The "Release" action maps to `PATCH /api/v3/versions/:id` with `status` + a
  `moveIncompleteWorkPackagesTo` semantic handled by `ReleaseService` (mirrors the draft's
  `moveIncompleteIssuesTo`).
- The Release link on a work package is read/written as a standard custom-field value in the
  work-package API (no new endpoint).

> Note: the draft's `/api/v1/...` paths do not match OpenProject. Use API v3.

---

## 6. Permissions
Reuse `:manage_versions` ([config/initializers/permissions.rb:228](../config/initializers/permissions.rb#L228))
for create/edit/release/delete. Viewing releases on work packages follows existing version
visibility (`:view_work_packages` + sharing). No new permission required unless Release
management must be separable from generic version management — if so, add
`:manage_releases` and gate the Release screens/services with it. **Recommendation:** start
with `:manage_versions`; split later only if requested.

---

## 7. Filtering / Query integration
- **Work packages by Release:** automatic via the version CF + `ListOptional` filter
  ([custom_fields/list_optional.rb](../app/models/queries/filters/shared/custom_fields/list_optional.rb)).
  Supports equals / not / all / none. (Status operators `o/c/l` exist for the *native*
  `version_id` filter; for the CF the equivalent is filtering by version status separately.)
- **Versions list by kind:** new `kind` filter (see §5).

---

## 8. Implementation Plan (phased)

**Phase 1 — Foundations (Release = kind of Version)**
1. Migration: `versions.kind` (NOT NULL, default `sprint`, + index) — backfills existing rows
   to `sprint` via the default; model `VERSION_KINDS`, `kind` validation, `releases`/`sprints`
   scopes. (Name uniqueness unchanged — see §1.1.)
2. Migration: `versions.released_at` (audit timestamp for the Release action).
3. Expose `kind` (and `released_at`) in API v3 representer + schema; add `kind` version filter.
4. Extend `deduce_versions` to accept a `kind` scope; add a `version_kind` setting to
   version-format custom fields.
5. Seed/admin a "Release" `version`-format WP custom field, **multi-value** (D1),
   scoped to `kind = release`.
6. **Scope all existing Sprint/Version selectors to `.sprints`** (§1.5) — WP version field,
   version filter, project version settings, roadmap, Backlogs — so releases don't leak in.

**Phase 2 — UI**
7. "Releases" project screen reusing the versions table, scoped to `kind = release`.
8. Release CF in WP detail panel + bulk edit (free; verify scoping to releases).
9. Release hub page = extended version `show` with the readiness dashboard (§2.2).

**Phase 3 — Workflow & notes**
10. `Versions::ReleaseService` + `ReleaseContract` + roll-forward/decouple/force dialog (§3.1).
11. Delete-with-reassign handling for the Release CF (§3.2).
12. Release notes generator component + copy/export + "write to wiki" (§4).

**Phase 4 — Hardening**
13. Specs: model (kind/scoping), service (release workflow strategies), request (API kind
    filter + release transition), feature (assign release, run release, generate notes).
14. Docs + translations (en.yml). Lint (rubocop / erb_lint / eslint).

**Out of scope (this iteration):** "Affects Version", quality/PR warnings, dependency on
`Agile::Sprint`.

---

## 9. Risks & Notes
- **Leak risk (biggest item):** because releases are `Version` rows, any version selector
  not scoped by `kind` will show both sets. The Release CF must be scoped to `kind = release`
  (§1.4) **and** all existing Sprint/Version selectors scoped to `kind = sprint` (§1.5).
  Implement both before exposing the Release field. Audit checklist of selectors to scope:
  WP detail `version_id` field, WP bulk edit, the version query filter, project version
  settings screen, the roadmap, and Backlogs `Sprint`/`VersionSetting` queries.
- **Separate selection sets (D-principle):** separation is enforced only at
  reference/selection time via kind scoping; names remain globally unique per project
  (unchanged — duplicates rejected regardless of kind).
- **`Agile::Sprint`:** if/when sprints fully migrate to `sprint_id`, `version_id` is freed and
  `kind = sprint` becomes redundant — revisit then, but no action needed now.
