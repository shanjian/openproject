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

- **Not a Kanban board.** A filtered embedded work package table, with
  the existing native filter/column panel still available underneath —
  the quick filters are a convenience layer, not a replacement.
- Two quick filters: **Organization Unit** and **Version**.
- Organization Unit quick filter lists **top-level departments only**
  (`Group.organizational_units.where_detail(parent_id: nil)`), matching
  `create_okr_saved_views.rb`'s existing scope. Sub-unit selection is
  out of scope for this iteration.
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
| Module registration | New project module (e.g. `okr_board`), togglable in Project Settings → Modules | `boards`, `meetings` module registration |
| Availability gate | Menu item + page only render when the project has ≥1 `department`-format `WorkPackageCustomField` enabled on an active type, and ≥1 `Version` exists; otherwise an empty-state pointing at setup steps | Tone of the "Before you start" section in `docs/use-cases/okr-management/README.md` |
| Controller/route | New controller, route `/projects/:project_id/okr_board` | Existing `boards` controller/routing pattern |
| Hierarchy scope math | None — reuses `Group#self_and_ancestors`, `Group#children` (`app/models/groups/hierarchy.rb`) as-is | `Groups::Hierarchy` |
| Filter application | None — reuses the existing `department`-format CF filter (`Queries::Filters::Shared::CustomFields::Department`, `CfListOptional` strategy), which already supports an OR-of-many-IDs `values` array | Existing department CF filter |
| Frontend quick-filter bar | New Angular component, e.g. `OkrBoardFilterComponent` | `frontend/src/app/features/boards/board/board-filter/board-filter.component.ts` (assignee/version quick filter pattern) |
| Frontend table | Reuses the existing embedded work-package table component | Embedded tables already used elsewhere (e.g. Project Overview widgets) |
| Locale | New strings for the module name, page title, scope toggle labels | Existing `js.boards.quick_filters.*` |

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
filter class or operator either. This is the core simplification versus
an initial assumption that hierarchy-aware filtering would need new
query-filter machinery: it doesn't, because the existing filter format
already treats its value as an arbitrary list of Group ids.

## Data flow

1. Admin enables the "OKR Board" module on a project (Project Settings
   → Modules), same as any other module.
2. If the project has no `department`-format CF enabled on any active
   type, or no Versions, the OKR Board menu item still appears (module
   is on) but the page shows an empty-state explaining what to
   configure — not a hard error.
3. On the page, `OkrBoardFilterComponent` discovers the project's
   active `department`-format CF (found generically by `field_format`,
   not by a hardcoded field name, consistent with
   `WorkPackageCustomField.where(field_format: "department")` already
   used in `app/services/work_packages/import/resolver.rb`) and loads
   its top-level values.
4. It loads the project's Versions the same way the existing board
   quick filter loads its version options.
5. User picks an Organization Unit → the scope toggle becomes enabled,
   defaulting to "Just this unit".
6. Selecting a scope computes the id array per the table above and
   updates the embedded table's query filter for the department CF
   (operator `"="`, the computed `values` array). Selecting a Version
   updates the `version_id` filter the same way the existing board
   quick filter does for `version`.
7. The full native filter/column panel remains available on the same
   table underneath the quick-filter bar, for anything beyond the two
   quick filters (type, status, etc.).

## Error handling

- **No department-format CF or no Versions configured:** graceful
  empty-state on the page (see step 2 above), not an error — module
  can be enabled ahead of configuring the fields.
- **Selected unit deleted while the page is open / bookmarked with
  stale state:** falls back to "no unit selected" (same graceful
  degradation the department CF filter itself already has for a
  deleted referenced Group — see
  `2026-08-10-department-custom-field-design.md`'s error handling
  section).
- **Project has multiple `department`-format custom fields:** unlikely
  given current usage, but if it occurs, the component picks the first
  one enabled on the active types; not a blocking scenario for this
  iteration.

## Testing

- Backend request/feature specs: module gating (menu item and page
  hidden/shown correctly), empty-state when fields aren't configured.
- Backend unit specs for the three scope computations against a seeded
  department tree: a root with no parent (verifies option 2 is a
  no-op), a root with children (verifies option 3), a root with no
  children (verifies option 3 degrades to just `[U.id]`).
- Frontend Jasmine specs for `OkrBoardFilterComponent`'s scope-to-values
  computation, mirroring existing `board-filter.component.ts` spec
  patterns.
- Capybara feature spec for the whole page, in the style of
  `modules/boards/spec/features/action_boards/version_board_spec.rb`.

## Open item to verify during planning

Whether the department CF's existing allowed-values loading is cleanly
reusable standalone from the frontend (the way `boardActions.get('version').loadAvailable(...)`
is reused here for Version), or whether a small read-only endpoint is
needed to fetch a CF's possible values outside the full WP-form/filter
autocompleter machinery. Not expected to be a large addition either
way, but not yet confirmed by reading the relevant Angular filter-value
loading code.

## Non-goals (this iteration)

- Sub-unit selection in the Organization Unit picker (top-level only).
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
6. **Keep `show_hierarchies` on by default** in the embedded table so
   the Strategic Initiative → Objective → Key Result → Task chain
   stays visible, reinforcing the docs' "alignment" principle.
