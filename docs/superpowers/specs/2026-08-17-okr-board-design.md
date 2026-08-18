# OKR Board — Design

**Date:** 2026-08-17
**Status:** Draft (pending approval)

## Goal

Add a per-project, activatable **OKR Board** page: a filtered work
package table with two quick filters — **Organization Unit** and
**Version** — plus a 3-way scope toggle that expands the Organization
Unit selection up or down the department hierarchy. Generic across any
project (gated on the project actually having the fields configured),
not hardcoded to a single "Company OKRs" project.

## Motivating use case

Per `docs/customization/Company OKR Framework.md` and `Department and
Team OKR Process.md`: Objectives and Key Results are work packages,
each tagged with an Organization Unit (a `department`-format custom
field, see `2026-08-10-department-custom-field-design.md`) and a
Version representing the quarterly cycle (e.g. "2026 Q3"). Today,
slicing this data by department + quarter means manually building
filters in the work package table, or running
`scripts/create_okr_saved_views.rb` to pre-bake one static saved view
per department. Neither supports interactively switching between "just
my team", "my team and everything above it", or "my team plus its
sub-teams" — the three scopes department heads and executives actually
need for weekly check-ins vs. monthly reviews.

## Requirements (confirmed)

- **Not a Kanban board.** A filtered work package table (the full
  table-view infrastructure, not the read-mostly embedded-table macro —
  see "Why not the embedded-table macro" below), with the existing
  native filter/column panel still available underneath — the quick
  filters are a convenience layer, not a replacement.
- Two quick filters: **Organization Unit** and **Version**.
- Organization Unit quick filter lists **top-level departments only**
  (`Group.organizational_units.where_detail(parent_id: nil)`), matching
  `create_okr_saved_views.rb`'s existing scope. Sub-unit selection is
  out of scope for this iteration.
  **Known limitation, accepted for this iteration:** the department
  hierarchy allows OKRs to be tagged at any depth, including leaf/team
  nodes (`2026-08-10-department-custom-field-design.md`: "any node in
  the tree is selectable... no leaf-only restriction"). A team whose
  own node sits *below* a top-level department cannot select just its
  own node here — it can only be reached via its top-level ancestor +
  "this and one level down", which only surfaces it if the team is
  exactly one level below that ancestor. Teams nested two or more
  levels down are not directly reachable at all in this iteration. This
  is a real gap against the "weekly team check-in" use case for such
  teams, not just an "ancestors is a no-op" cosmetic detail — accepted
  as a scoping tradeoff, revisit if deeper org trees turn out to be
  common.
- **Exactly one `department`-format custom field must be enabled** on
  the project's active types for the board to activate. Custom field
  filter keys are per-field-instance (`cf_<id>`, see
  `CustomField#column_name`), not per-format, so if a project has zero
  or more than one such field enabled, the board shows a configuration
  error/empty-state rather than silently guessing which one to use.
- A 3-way scope toggle, enabled once a unit is selected:
  1. **Just this unit** — `[unit.id]`
  2. **This and everything above** — `unit.self_and_ancestors.ids`. For
     a top-level unit this is a **no-op**, identical to option 1, since
     nothing sits above a top-level department today. Kept visible
     rather than hidden: it becomes meaningful for free if the picker
     is ever widened to sub-units, at no extra cost now. This is a
     deliberate, documented tradeoff, not an oversight.
  3. **This and one level down** — `[unit.id] + unit.children.ids`
     (direct children only, not full descendants). The option that
     does real work today, given the top-level-only picker.
- **Generic across any project** — usable wherever a project has at
  least one `department`-format custom field enabled on its active
  types and at least one Version. Not hardcoded to one project or one
  set of work package type names.
- No new permission — reuses `view_work_packages`; this only narrows
  what a user can already see.
- Explicitly **not in this iteration**: OKR Health quick filter,
  staleness indicators, "My OKRs" personal filter, auto-defaulting
  Version to the current quarter, saved-view auto-seeding. See
  "Recommendations for later" below.

## Why a dedicated module, not the universal filter bar

Two structural options were considered:

- **Enhance the universal work-package filter sidebar** (used by every
  table in every project) to understand Organization Unit + scope.
  Rejected: it reaches more surfaces for free, but means changing
  shared filter UI that every project in the instance depends on, in
  service of a feature that only makes sense on OKR-shaped projects.
  Harder to gate cleanly, higher blast radius for the value delivered.
- **Static saved-view generation** (extend
  `create_okr_saved_views.rb` to pre-bake one view per department ×
  scope × version). Rejected: not an interactive quick filter, and
  combinatorially grows every quarter/department — doesn't scale and
  doesn't satisfy "quick filter switch."

**Chosen: a dedicated, per-project-activatable module and page**,
mirroring how Boards/Wiki/Meetings are already toggled per project.
Contained blast radius (new controller/route/component; nothing
existing changes), and naturally gated to only appear where it's
useful.

## Architecture

| Layer | New code | Mirrors / reuses |
|---|---|---|
| Module registration | New project module `okr_board`, `dependencies: :work_package_tracking`, togglable in Project Settings → Modules | `project_module :board_view, dependencies: :work_package_tracking` (`modules/boards/lib/open_project/boards/engine.rb:29`) |
| Permission | New `show_okr_board` permission, `permissible_on: :project`, `dependencies: :view_work_packages` | `show_board_views`'s own `dependencies: :view_work_packages` declaration (`engine.rb:30-35`) |
| Controller authorization | Explicit `before_action :authorize_work_package_permission` on the show action, in addition to the module/permission check above | `Boards::BoardsController`'s `before_action :authorize_work_package_permission, only: %i[show]` with its comment "the boards permission alone does not suffice to view work packages" (`boards_controller.rb:12`) |
| Availability gate | The **module** is what's admin-toggled (Project Settings → Modules) and gates the menu item; once enabled, the menu item always shows. **Page content** is separately gated: if the project has 0 or >1 `department`-format `WorkPackageCustomField` enabled on an active type, or no `Version`, the page renders an empty-state pointing at setup steps instead of the table. These are two different gates — module-enablement is binary and controls visibility, field/version-availability is a content-level empty-state, never a hidden menu item. | Tone of the "Before you start" section in `docs/use-cases/okr-management/README.md` |
| Controller/route | New controller, route `/projects/:project_id/okr_board` | Existing `boards` controller/routing pattern |
| Hierarchy scope math | None — reuses `Group#self_and_ancestors`, `Group#children` (`app/models/groups/hierarchy.rb`) as-is | `Groups::Hierarchy` |
| Filter application | None — reuses the existing `department`-format CF filter (`Queries::Filters::Shared::CustomFields::Department`, `CfListOptional` strategy), which already supports an OR-of-many-IDs `values` array | Existing department CF filter |
| Frontend quick-filter bar | New Angular component, e.g. `OkrBoardFilterComponent`, built on the same live query-space mechanism Boards uses (`WorkPackageViewFiltersService` / `IsolatedQuerySpace`) rather than a one-shot `queryProps` input | `frontend/src/app/features/boards/board/board-filter/board-filter.component.ts` (assignee/version quick filter pattern) |
| Frontend table | The full work-package table view infrastructure (`wp-view-base`, the same one Boards embeds), **not** the `wp-embedded-table` macro component — see "Why not the embedded-table macro" below | Boards' own table view, not Project Overview's embedded-table widgets |
| Locale | New strings for the module name, page title, scope toggle labels | Existing `js.boards.quick_filters.*` |

### Why not the embedded-table macro

`WorkPackageEmbeddedTableComponent` (`wp-embedded-table.component.ts`)
takes `queryProps` as an `@Input()` consumed once inside `loadQuery()` —
there's no reactive path that re-fetches when a parent changes it later,
so it has no contract for "update my filters after the user picks a
quick filter." It also defaults `withFilters: false` and
`showFilterButton: false` (`wp-table-configuration.ts:69,75`), and its
own template only renders the filter container
`@if (configuration.withFilters)` — so the "native filter/column panel
stays available underneath" requirement from this design's Requirements
section does **not** hold with this component's defaults. Boards
doesn't use this macro either — it uses the full table-view
infrastructure with a live, mutable query held in `IsolatedQuerySpace`,
which is what actually gives `board-filter.component.ts` a working
"change a filter, table updates" contract via
`WorkPackageViewFiltersService`. The OKR Board page adopts the same
infrastructure for the same reason, with `withFilters: true` and
`showFilterButton: true` set explicitly so the native panel is visible
by default (not relying on a default that currently points the other
way).

### Hierarchy scope semantics, precisely

Given a selected top-level unit `U`:

```text
Just this unit            → [U.id]
This and everything above → U.self_and_ancestors.ids   (== [U.id] today; U is top-level)
This and one level down   → [U.id] + U.children.ids
```

All three compute directly from already-existing `Groups::Hierarchy`
methods — no new backend hierarchy logic. The resulting ID array is
applied as the department CF's existing `"="` filter operator — no new
filter class or operator either. This is a real simplification versus
an initial assumption that hierarchy-aware filtering would need new
query-filter machinery: it doesn't, because the existing filter format
already treats its value as an arbitrary list of Group ids.

**Where the frontend gets the data to compute this.** `GroupRepresenter`
(`lib/api/v3/groups/group_representer.rb:42-48`) exposes a `parent`
link per Group but no `children` — so "one level down" cannot be
computed from a single Group resource alone. It also cannot be computed
from a list of *only* top-level departments, since children by
definition aren't in that list. The mechanism: `CustomField#possible_department_values`
is `Group.organizational_units.in_tree_order` — **every** organizational
unit at every depth, not just top-level ones (confirmed by reading
`app/models/custom_field.rb:232-234`). The frontend loads this full set
once (the same set the CF's own value picker already loads elsewhere in
the app), each entry carrying its `parent` link per `GroupRepresenter`,
and builds a client-side `parent_id → [child ids]` index from it. The
top-level dropdown then filters this same set down to entries with no
parent; "one level down" looks up the selected unit's id in the index.
No new backend endpoint is needed **if** this full-collection load is
confirmed reusable as a standalone call from `OkrBoardFilterComponent`
(as opposed to being embedded only inside a specific widget's internal
autocompleter logic) — this is the one item to confirm by reading the
relevant Angular loading code during planning/implementation, not a
design uncertainty about whether the data exists on the backend.

## Data flow

1. Admin enables the "OKR Board" module on a project (Project Settings
   → Modules), same as any other module. This always makes the menu
   item appear (module on/off is the only gate on the menu item).
2. Loading the page, the controller checks whether the project has
   **exactly one** `department`-format CF enabled on an active type,
   and at least one Version. If not (0 or >1 CFs, or no Versions), the
   page renders an empty-state explaining what to configure, instead of
   the table — the menu item stayed visible in step 1 regardless.
3. Otherwise, `OkrBoardFilterComponent` loads the full set of
   organizational units (`Group.organizational_units.in_tree_order`,
   every depth, via whatever standalone call reuses the CF's existing
   allowed-values loading — see "Where the frontend gets the data"
   above), builds a client-side `parent_id → children` index from the
   `parent` link each entry carries, and populates the Organization
   Unit dropdown with just the entries that have no parent.
4. It loads the project's Versions using `project.shared_versions`
   (the same scope the backend `VersionFilter` itself uses — see
   "Version scope" in Error handling below), not the boards-style
   project-owned-only versions call, so the quick filter's options
   and the filter's actual accepted values never diverge.
5. User picks an Organization Unit → the scope toggle becomes enabled,
   defaulting to "Just this unit".
6. Selecting a scope computes the id array per the table above (using
   the client-side index from step 3 for "one level down"; "everything
   above" needs no traversal since the picker is top-level-only) and
   writes it into the live query held in `IsolatedQuerySpace` via
   `WorkPackageViewFiltersService`, the same way `board-filter.component.ts`
   updates the `assignee`/`version` filters today — **not** a
   one-shot `queryProps` input, since that path only takes effect at
   initial load (see "Why not the embedded-table macro" above).
   Selecting a Version updates the `version_id` filter the same way.
7. Filter state round-trips through the URL the same way Boards' quick
   filters do: `$state.go('.', { query_props }, { custom: { notify: false } })`
   with the filter hash JSON-encoded, so reloading or bookmarking the
   page restores the selection. If a bookmarked/stale `query_props`
   references a unit id no longer in the loaded organizational-units
   set (e.g. the Group was deleted), the quick filter falls back to "no
   unit selected" rather than erroring — the underlying query filter's
   own value objects already degrade the same way (see Error handling).
8. The full native filter/column panel remains visible on the same
   table underneath the quick-filter bar (`withFilters: true`,
   `showFilterButton: true` set explicitly — see "Why not the
   embedded-table macro"), for anything beyond the two quick filters
   (type, status, etc.). The quick filter bar and the native panel
   read/write the same underlying query filters — there are not two
   separate sources of truth.

## Error handling

- **No department-format CF, or more than one, or no Versions
  configured:** empty-state on the page (see step 2 above), not an
  error — module can be enabled ahead of configuring the fields, and
  the empty-state's copy should say which of the two conditions
  (fields vs. versions) still needs fixing. Multiple department-format
  CFs on the active types is treated the same as zero: it is **not**
  resolved by picking the first one, since custom field filter keys
  are per-instance (`cf_<id>`, `CustomField#column_name`) and silently
  picking one could point the quick filter at a field the project
  doesn't actually intend to slice OKRs by.
- **Selected unit deleted while the page is open / bookmarked with
  stale state:** falls back to "no unit selected" (same graceful
  degradation the department CF filter itself already has for a
  deleted referenced Group — see
  `2026-08-10-department-custom-field-design.md`'s error handling
  section). The bookmarked `query_props` filter hash itself is left
  alone (not rewritten) — only the quick-filter UI's displayed
  selection resets, consistent with how `board-filter.component.ts`'s
  `selectedQuickFilter` already falls back to `QUICK_FILTER_ALL` when
  it can't match the current filter value to a known option.
- **Version scope:** the quick filter's Version options and the
  underlying `version_id` filter's accepted values must be the same
  set, to avoid a quick filter that offers versions the filter would
  then reject (or vice versa). Backend `VersionFilter#versions` is
  `project.shared_versions` (includes versions shared into this
  project from elsewhere, per the project's sharing settings; no
  status filtering, so closed/locked versions are included too — see
  `app/models/queries/work_packages/filter/version_filter.rb:95-105`).
  The quick filter loads the same scope, not `apiV3Service.projects.id(id).versions.get()`
  (project-owned versions only, what Boards' own version quick filter
  uses) — using the Boards approach here would silently omit shared
  versions that the underlying filter would otherwise accept.

## Testing

- Backend request/feature specs: module gating (menu item always shows
  once enabled, independent of field configuration), empty-state when
  0 or >1 department-format CFs are enabled, empty-state when no
  Versions exist, and authorization (a user without `view_work_packages`
  in the project is denied even with the module enabled — mirroring
  `Boards::BoardsController`'s explicit `authorize_work_package_permission`
  check, not just the module permission).
- Backend unit specs for the three scope computations against a seeded
  department tree: a root with no parent (verifies option 2 is a
  no-op), a root with children (verifies option 3), a root with no
  children (verifies option 3 degrades to just `[U.id]`).
- Backend spec confirming the Version quick filter's option set and the
  `VersionFilter`'s accepted values agree (same `project.shared_versions`
  scope, including a version shared in from another project).
- Frontend Jasmine specs for `OkrBoardFilterComponent`: scope-to-values
  computation (including building the `parent_id → children` index from
  a full organizational-units collection), and stale/deleted-unit
  fallback to "no unit selected".
- Capybara feature spec for the whole page, in the style of
  `modules/boards/spec/features/action_boards/version_board_spec.rb`,
  including reload-restores-selection via `query_props` and confirming
  the native filter/column panel is visible (not hidden by the
  embedded-table macro's defaults).

## Non-goals (this iteration)

- Sub-unit selection in the Organization Unit picker (top-level only —
  see the "Known limitation, accepted for this iteration" note under
  Requirements for the resulting gap against teams nested below a
  top-level department).
- OKR Health quick filter, staleness indicators, "My OKRs" personal
  filter, current-quarter auto-defaulting, saved-view auto-seeding —
  see "Recommendations for later" below.
- Any change to the universal work-package filter sidebar.
- Any change to the Boards module or its Kanban board types.

## Recommendations for later (not built in this iteration)

Raised per the request to think about OKR process impact, for a future
decision — not part of this design's scope:

1. **OKR Health quick filter / surfacing At Risk first** — the docs
   explicitly say department reviews "should focus primarily on At
   Risk and Off Track OKRs rather than spending equal time on every
   item."
2. **Staleness flag off "Last Check-in"** — flag items not updated in
   >7 days, directly answering the docs' monthly-review question
   "items that have not been updated recently."
3. **"My OKRs" personal quick filter** (Accountable = current user),
   mirroring the existing assignee quick filter's pin-current-user
   behavior in `board-filter.component.ts`.
4. **Auto-default Version to the current quarter** by matching today's
   date to a version's date range, removing a manual step every
   quarter.
5. **Auto-seed default OKR saved views** when the module is enabled,
   turning `create_okr_saved_views.rb` from a manual rails-runner
   script into a one-time automatic action.
6. **Keep `show_hierarchies` on by default** in the table so the
   Strategic Initiative → Objective → Key Result → Task chain stays
   visible, reinforcing the docs' "alignment" principle.
