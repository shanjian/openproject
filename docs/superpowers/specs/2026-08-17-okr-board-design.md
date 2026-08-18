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
- **New module-scoped permission, `show_okr_board`**, `dependencies:
  :view_work_packages` (see Architecture below) — this superseded an
  earlier "no new permission" assumption once the module/authorization
  chain was specified; keeping both statements was a leftover
  contradiction from an earlier revision. Same shape as Boards'
  `show_board_views`: the permission gates the module/menu, the
  `view_work_packages` dependency is what actually determines whether
  a user can see any rows, so this still only narrows what a user with
  `view_work_packages` can already see — it does not grant new access
  to work package data.
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
| Permission | New `show_okr_board` permission, `permissible_on: :project`, `dependencies: :view_work_packages` — see "Permission default-role seeding and locale, precisely" below | `show_board_views`'s own `dependencies: :view_work_packages` declaration (`engine.rb:30-35`) |
| Controller action & authorization | Single `index` action (there is no per-record resource to enumerate/show separately — see "Controller action and bootstrap, precisely" below) with `before_action :authorize_work_package_permission, only: %i[index]` in addition to the module/permission check above | `Boards::BoardsController`'s `authorize_work_package_permission` and its comment "the boards permission alone does not suffice to view work packages" (`boards_controller.rb:12`) — reused for the same reason, attached to the action this design actually routes to |
| Availability gate | The **module** is what's admin-toggled (Project Settings → Modules) and gates the menu item; once enabled, the menu item always shows. **Page content** is gated separately, resolved server-side inside the `index` action itself (not client-side, not a separate API check) — see "Controller action and bootstrap, precisely" below for exactly what that action renders in each case. | Tone of the "Before you start" section in `docs/use-cases/okr-management/README.md` |
| Rails controller/route | New controller, route `/projects/:project_id/okr_board`, single `index` action — see "Controller action and bootstrap, precisely" below for what it renders | Existing `boards` controller/routing pattern, specifically `Boards::BoardsController#show` (not `#index` — see that section for why) |
| Angular routing | New `openproject-okr-board.routes.ts` registering a ui-router state `okr-board`, `parent: 'optional_project'`, `url: '/okr_board/?query_props'`, `params: { query_props: { type: 'opQueryString', dynamic: true } }`, `component: OkrBoardRootComponent` — mounted only once the `index` action has already decided to render the Angular layout (see below) | `openproject-boards.routes.ts`'s `boards` state (`parent: 'optional_project'`, `url: '/boards/?query_props'`, same `opQueryString` param type) |
| Hierarchy scope math | None — reuses `Group#self_and_ancestors`, `Group#children` (`app/models/groups/hierarchy.rb`) as-is | `Groups::Hierarchy` |
| Filter application | None — reuses the existing `department`-format CF filter (`Queries::Filters::Shared::CustomFields::Department`, `CfListOptional` strategy), which already supports an OR-of-many-IDs `values` array | Existing department CF filter |
| Frontend quick-filter bar | New Angular component, e.g. `OkrBoardFilterComponent`, built on the same live query-space mechanism Boards uses (`WorkPackageViewFiltersService` / `IsolatedQuerySpace`) rather than a one-shot `queryProps` input | `frontend/src/app/features/boards/board/board-filter/board-filter.component.ts` (assignee/version quick filter pattern) |
| Frontend table | The full work-package table view infrastructure (`wp-view-base`, the same one Boards embeds), **not** the `wp-embedded-table` macro component — see "Why not the embedded-table macro" below | Boards' own table view, not Project Overview's embedded-table widgets |
| Locale | New strings for the module name, page title, scope toggle labels | Existing `js.boards.quick_filters.*` |

### Permission default-role seeding and locale, precisely

A new permission with no default-role grants would leave the module
enableable but invisible to anyone until an admin manually edits every
role, which isn't how Boards ships. Mirror `modules/boards/app/seeders/common.yml`'s
`modules_permissions.boards` entry:

```yaml
modules_permissions:
  okr_board:
  - role: :default_role_non_member
    add:
    - :show_okr_board
  - role: :default_role_member
    add:
    - :show_okr_board
  - role: :default_role_reader
    add:
    - :show_okr_board
```

`show_okr_board` is purely a view permission (like `show_board_views`,
not `manage_board_views`), so it's granted to the same three default
roles Boards grants its own view permission to — no `manage_*`
counterpart is needed since this design has no create/edit/destroy
actions of its own. Locale keys mirror `modules/boards/config/locales/en.yml`
(`permission_show_board_views: "View boards"`,
`project_module_board_view: "Boards"`): add
`permission_show_okr_board` and `project_module_okr_board` (exact
English copy TBD during planning, e.g. "View OKR Board" / "OKR Board").

### Why not the embedded-table macro

`WorkPackageEmbeddedTableComponent` (`wp-embedded-table.component.ts`)
takes `queryProps` as an `@Input()` consumed once inside `loadQuery()` —
there's no reactive path that re-fetches when a parent changes it later,
so it has no contract for "update my filters after the user picks a
quick filter." It also defaults `withFilters: false` and
`showFilterButton: false` (`wp-table-configuration.ts:69,75`), and its
own template only renders the filter container
`@if (configuration.withFilters)`. **Those two flags are configuration
for this specific macro component** — they don't apply once we move to
the full table-view infrastructure below, so setting them is not the
fix. Boards doesn't use this macro — it uses the full table-view
infrastructure with a live, mutable query held in `IsolatedQuerySpace`,
which is what actually gives `board-filter.component.ts` a working
"change a filter, table updates" contract via
`WorkPackageViewFiltersService`. The OKR Board page adopts the same
infrastructure for the same reason. In that infrastructure, the filter
area isn't a boolean flag at all: `PartitionedQuerySpacePageComponent`
renders it as a dynamically-resolved component slot —
`work-packages-partitioned-query-space--filter-area` contains an
`<ndc-dynamic [ndcDynamicComponent]="filterContainerDefinition.component">`
(`partitioned-query-space-page.component.html:35-41`) wired up by
whatever page component supplies `filterContainerDefinition`. The OKR
Board's own root/page component needs to supply this the same way the
work-packages full view does, so the native filter/column panel is
part of the page by construction rather than a configuration flag to
remember to set.

### Controller action and bootstrap, precisely

Correcting an inaccurate comparison from the previous revision:
`Boards::BoardsController#index` (`boards_controller.rb:19-21`) renders
a plain, **server-rendered** board list (`render "index"`) — no
Angular at all. It's `#show` (`boards_controller.rb:23-25`,
`render layout: "angular/angular"`) that bootstraps the Angular SPA,
for one specific board `id`. Boards has this split because there are
many boards per project; the OKR Board has no equivalent per-record
resource — there is exactly one page per project, not a collection of
them — so there's no natural index/show pair to mirror. The design
uses a single `index` action for `/projects/:project_id/okr_board`
(matching the route, since there's no `:id`), whose *behavior* is
modeled on Boards' `#show` (Angular-bootstrapping), not Boards'
`#index` (server-rendered list).

This single action is also where the availability gate resolves,
**server-side, synchronously, before choosing what to render** —
resolving the earlier contradiction between "the controller checks
configuration" and "the controller only renders a generic bootstrap":

- Gate fails (0 or >1 qualifying department-format CFs, or no
  Versions — see "Availability gate predicate, precisely" below): the
  action renders a plain server-rendered empty-state view. No Angular
  layout, no ui-router state activation, nothing shipped to the client
  about *why* — the empty-state copy itself, rendered server-side,
  says what to configure.
- Gate passes: the action renders `layout: "angular/angular"`, which
  boots the SPA and activates the `okr-board` ui-router state below.

Angular therefore never re-checks availability itself via a separate
API call — by the time it boots at all, the gate has already passed.
This also settles what data needs to reach Angular for the gate: none:
the CF id/version-existence check is consumed entirely server-side and
does not need to cross into the client at all.

### Angular routing, precisely

Once the gate above has passed and the Angular layout is rendered, a
Rails route alone still doesn't give the SPA anything to activate
against — `query_props` and `$state.go('.', { query_props })` are
ui-router concepts belonging to whichever state is active, and there is
no existing state for `/projects/:id/okr_board`. Modeled directly on
`openproject-boards.routes.ts`'s `boards` state:

```text
name: 'okr-board'
parent: 'optional_project'
url: '/okr_board/?query_props'
params: { query_props: { type: 'opQueryString', dynamic: true } }
component: OkrBoardRootComponent
```

`OkrBoardRootComponent` (new) plays the role `BoardsRootComponent` plays
for Boards: it owns the `IsolatedQuerySpace` for this page, initializes
the query from `query_props` (or a fresh default query filtered to
nothing selected) on load, and composes `OkrBoardFilterComponent`
alongside the full-view table/filter-area machinery described above.
It discovers the project's one qualifying department-format CF's id
via the normal schema/query-form loading path (the same way any query
form already reports which custom fields are available) — it does not
need the server to hand it that id out-of-band, since the gate above
already guarantees exactly one exists.

### Availability gate predicate, precisely

`Project#all_work_package_custom_fields` (`app/models/projects/work_package_custom_fields.rb:43-47`)
returns CFs that are either global (`for_all`) or explicitly associated
with the project via `custom_fields_projects` — but that table has
nothing to do with work package **types**. A CF can be associated with
a project yet not be activated on any of that project's active types,
and this method wouldn't catch it. Type-activation is `WorkPackageCustomField`'s
own `has_and_belongs_to_many :types` association (`app/models/work_package_custom_field.rb:35-37`,
join table `custom_fields_types`) — the association name is `:types`,
not `:custom_fields_types` (that's the join table, not a Rails
association on the model; a literal `.joins(:custom_fields_types)`
would fail). This is the same association the query filter system
itself joins through when deciding whether a CF is actually filterable
(`Queries::WorkPackages::Filter::CustomFieldContext#where_subselect_joins`,
`app/models/queries/work_packages/filter/custom_field_context.rb:56-77`,
joining the `custom_fields_types` table on `type_id`). The availability
gate needs the same two-part predicate the query filter effectively
relies on: CF is enabled for the project (`all_work_package_custom_fields`)
**and** CF is associated with at least one of the project's active
types, not just the first half:

```ruby
project
  .all_work_package_custom_fields
  .merge(WorkPackageCustomField.joins(:types).where(types: { id: project.types }))
```

(exact form to be finalized during planning; the point is `joins(:types)`,
not a bare join-table reference).

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
once, each entry carrying its `parent` link per `GroupRepresenter`, and
builds a client-side `parent_id → [child ids]` index from it. The
top-level dropdown then filters this same set down to entries with no
parent; "one level down" looks up the selected unit's id in the index.

This load must **not** go through the generic CF-value autocomplete
path a filter's value picker normally uses
(`FilterSearchableMultiselectValueComponent#loadCollection`,
`filter-searchable-multiselect-value.component.ts:105`), which requests
`pageSize: MAGIC_FILTER_AUTOCOMPLETE_PAGE_SIZE` — **100** — and only
loads further pages on-demand as the user types a search term
(`filter-searchable-multiselect-value.component.ts:155`, the
`autocomplete()` method's fallback branch). That path is built for "show
100 options, then search-as-you-type the rest" — it does not
transparently assemble a complete collection, so it cannot be used to
build a correct hierarchy index once a project has more than 100
organizational units (a level-down lookup for a unit whose children
happen to load past page 1 would silently see zero children). Instead,
`OkrBoardFilterComponent` must fetch the full collection explicitly via
`getPaginatedResults`/`getPaginatedCollections`
(`core-app/core/apiv3/helpers/get-paginated-results.ts`) with
`pageSize: MAGIC_PAGE_NUMBER` (`-1`, "resolve to the maximum value"),
which follows every page rather than stopping at the first 100.

## Data flow

1. Admin enables the "OKR Board" module on a project (Project Settings
   → Modules), same as any other module. This always makes the menu
   item appear (module on/off is the only gate on the menu item).
2. Loading the page, the controller's single `index` action checks
   server-side whether the project has **exactly one** `department`-format
   CF enabled on an active type, and at least one Version (see
   "Controller action and bootstrap, precisely"). If not (0 or >1 CFs,
   or no Versions), it renders a plain server-rendered empty-state
   explaining what to configure — no Angular layout, no ui-router state
   activated — the menu item stayed visible in step 1 regardless. If
   the gate passes, it renders `layout: "angular/angular"` instead,
   which is what actually boots the SPA and reaches step 3.
3. Otherwise, `OkrBoardFilterComponent` loads the full set of
   organizational units (`Group.organizational_units.in_tree_order`,
   every depth) via `getPaginatedResults`/`getPaginatedCollections`
   with `pageSize: MAGIC_PAGE_NUMBER` — **not** the CF's normal
   100-row autocomplete path, which would silently truncate the
   hierarchy index (see "Where the frontend gets the data" above) —
   builds a client-side `parent_id → children` index from the `parent`
   link each entry carries, and populates the Organization Unit
   dropdown with just the entries that have no parent.
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
   set (e.g. the Group was deleted), `OkrBoardFilterComponent`
   **actively clears the department-CF filter from the live query**
   (`WorkPackageViewFiltersService`, same call path as a normal quick
   filter change) and rewrites `query_props` to drop it, then shows the
   quick filter as "no unit selected" — the display and the live
   filter change together. This is a deliberate departure from
   `board-filter.component.ts`'s own `selectedQuickFilter`: that method
   only recomputes what the dropdown *displays* from the current
   filter and never calls `boardFilters.setTemporary` itself, so an
   unrecognized filter value there leaves the underlying live filter
   untouched while the dropdown shows "All" — i.e. Boards' own
   assignee/version quick filters have this exact latent mismatch
   today. The OKR Board's stale-unit handling intentionally does not
   copy that pattern.
8. The full native filter/column panel remains visible on the same
   table underneath the quick-filter bar (via the page's own
   `filterContainerDefinition`, not a boolean flag — see "Why not the
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
  stale state:** clears the department-CF filter from the **live**
  query (not just the displayed dropdown value) and rewrites
  `query_props` accordingly, then shows "no unit selected" — see Data
  flow step 7. Copying `board-filter.component.ts`'s own
  `selectedQuickFilter` fallback verbatim was considered and rejected:
  that method only resets what the dropdown displays and never touches
  the live filter, so on Boards today a stale assignee/version filter
  value would leave the table filtered by a dead id while the dropdown
  shows "All" — usually a silently-empty result set. The department CF
  filter's own value-object degradation
  (`2026-08-10-department-custom-field-design.md`'s error handling
  section) is a separate, unrelated concern: it's about how a *stored
  work package's* dangling custom value renders (e.g. "not found"
  label), not about clearing a stale *filter* value from a live query.
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
  0 or >1 *qualifying* department-format CFs are enabled — including
  the case where a CF is associated with the project but not activated
  on any of its active types, which must count as "0 qualifying", not
  "1" (this is the specific gap the availability-gate predicate closes,
  see "Availability gate predicate, precisely") — empty-state when no
  Versions exist, and authorization (a user without `view_work_packages`
  in the project is denied even with the module enabled — mirroring
  `Boards::BoardsController`'s explicit `authorize_work_package_permission`
  check, not just the module permission).
- Backend integration spec seeding a department tree (a root with
  children, a root with no children) and Objective/Key Result work
  packages tagged across those units, asserting that applying each of
  the three scopes' resulting `cf_<id>` value lists as a `"="` filter
  returns exactly the intended rows — the scope *computation* itself is
  client-side (see below), so this is about confirming the backend
  filter behaves correctly given those IDs, not about re-testing the ID
  computation in Ruby.
- Backend spec confirming the Version quick filter's option set and the
  `VersionFilter`'s accepted values agree (same `project.shared_versions`
  scope, including a version shared in from another project).
- Frontend Jasmine specs for `OkrBoardFilterComponent`: fetching the
  full organizational-units collection via `getPaginatedResults`
  (including a case with >100 units, to catch a regression back to the
  100-row autocomplete path), building the `parent_id → children` index
  from it, scope-to-values computation from that index (root with no
  parent, root with children, root with none), writing the computed
  values into the live query via `WorkPackageViewFiltersService`, and
  stale/deleted-unit handling clearing both the live filter and
  `query_props` (not just the displayed selection).
- Capybara feature spec for the whole page, in the style of
  `modules/boards/spec/features/action_boards/version_board_spec.rb`,
  including reload-restores-selection via `query_props` and confirming
  the native filter/column panel is visible via the page's
  `filterContainerDefinition`.

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
