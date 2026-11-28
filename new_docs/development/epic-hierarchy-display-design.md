# Epic Hierarchy Display — Design (v2.1)

Status: **accepted — in implementation** (v2 after first review rejected server-side injection;
v2.1 after second review — pagination scope, parent tri-state, collapse
semantics, projection refinement)
Date: 2026-08-23
Related: [epic-link-implementation-tasks.md](./epic-link-implementation-tasks.md),
PR #155 (epic filter returns the epics themselves), `work_packages.epic_id`
(migration `20260308120000_add_epic_link_to_work_packages.rb`)

## Problem

A Gantt view filtered by epic should read like a Jira epic plan: the epic on
top, its linked work packages nested beneath it, and a bar on the epic row
spanning its children's dates.

What actually happened, in two stages:

1. **The epics did not appear at all.** The epic filter compiled to
   `work_packages.epic_id IN (...)`, which matches an epic's linked children
   but never the epic itself. Fixed by PR #155.
2. **The epics appear, but flat.** The epic is now a result row — but it
   renders as a sibling of its linked tasks, not their parent, and its date
   cells are empty. This document is about fixing that.

The underlying cause is structural: the fork's Epic link is a dedicated
`epic_id` column, deliberately independent of the parent/child hierarchy (see
[epic-link-implementation-tasks.md](./epic-link-implementation-tasks.md) —
"This link is independent of parent-child hierarchy"; decision 4: a work
package may carry both `parent` and `epic`). Every display mechanism that
produces nesting or spanning bars reads the hierarchy. Nothing bridges them.

## Context — how the relevant machinery works (verified in code)

### The hierarchy display pipeline

1. `work_package_hierarchies (ancestor_id, descendant_id, generations)` is a
   closure table maintained by the `closure_tree` gem (`has_closure_tree`,
   `app/models/work_package.rb:188`), populated **exclusively from
   `parent_id`**. The gem's `after_save` hook deletes a node's rows and
   reinserts them purely from `parent_id`, recursing into all children, on
   every create and reparent — foreign edges do not survive ordinary editing.
2. `WorkPackage::Ancestors::Aggregator`
   (`app/models/work_package/ancestors.rb`) reads the closure table; both API
   paths (single WP via `#visible_ancestors`, collections via
   `lib/api/v3/work_packages/eager_loading/ancestor.rb`) funnel through it.
3. The result is rendered as `_links.ancestors`
   (`work_package_representer.rb:335`, `uncacheable: true`). The **documented
   API contract** (`docs/api/apiv3/tags/work_packages.yml:30`) defines it as
   *"Array of all visible ancestors of the work package, with the root node
   being the first element"* — i.e. the real parent chain.
4. Frontend consumers of `_links.ancestors` (via `getAncestors()` /
   `ancestorIds`) — **at least four** (v1 of this document wrongly claimed
   one; two review rounds corrected it). Three behavioral, one auxiliary:
   - the fast-table **hierarchy machinery**
     (`hierarchy-render-pass.ts`, `single-hierarchy-row-builder.ts`);
   - the work-package **breadcrumb**
     (`wp-breadcrumb.component.ts:56`). Its template suppresses the *last*
     ancestor and renders the actual parent separately
     (`wp-breadcrumb.html:7`), so a synthetic final ancestor would not render
     as a link but would corrupt the hierarchy count/label state;
   - the **indent/outdent service**
     (`wp-view-hierarchy-indentation.service.ts:46`), whose `canIndent`
     reads `ancestorIds` while `canOutdent` reads `parent` — the two must
     agree;
   - auxiliary: the **additional-elements service**
     (`wp-view-additional-elements.service.ts:139`) collects `ancestorIds`
     of result rows to fetch ancestor rows missing from the result set —
     server-injected epics would have been fetched as "additional elements"
     in every hierarchy view.
5. Each table row renders exactly once, so the display is structurally a
   forest: one effective parent per node. Two parallel hierarchies are not
   representable.

### The `parent` link does not distinguish "none" from "invisible"

The representer emits `{href: nil}` for the `parent` link **both** when the
work package has no parent and when a real parent exists but is not visible
to the current user (`work_package_representer.rb:568-583`; the embedded
parent is likewise skipped). The raw HAL payload therefore does **not**
preserve the distinction — any client-side "has no parent" test built on
`_links.parent` alone is unsound. This constrains the recommended option
(see the tri-state rule below).

### Timeline bars, pagination, collapse

- A row's solid bar comes from its own dates. The children-duration bar comes
  from `derivedStartDate`/`derivedDueDate` (`timeline-cell-renderer.ts:505`),
  computed at query time by the `include_derived_dates` scope — but the
  collection eager-loading wrapper (`work_package_eager_loading_wrapper.rb:103`)
  selects those columns **unconditionally for every collection response**, so
  a scope change is a global API change. The bar's documented meaning is
  *hierarchy* children duration.
- **Pagination is page-scoped rendering.** The filter guarantees inclusion in
  the *result set* (`epic_filter.rb:35`), pagination selects a page
  (`wp-view-pagination.service.ts:51`), and the table index contains only
  that page (`wp-fast-table.ts:83`). Nothing guarantees an epic and its
  children share a page.
- **Collapse hides rows from the timeline's displayed list.** The timeline
  keeps `workPackageIdOrder = orderedRows.filter(row => !row.hidden)`
  (`wp-timeline-container.directive.ts:199`) — a bar defined naively over
  "displayed" children would shrink or vanish when the epic is collapsed.
- `isLeaf` and related interactivity read `$links.children`
  (`work-package-resource.ts:194`) — a purely visual envelope must not
  affect them.

### The `epic` link is already in the API payload

The full representer renders an `epic` link with href and title
(`work_package_representer.rb:612`). Every table row already carries enough
data to identify its epic client-side. This is the load-bearing fact for the
recommended option.

### Who else reads the closure table (why writing to it is ruled out)

| Consumer | Effect of a foreign epic edge |
|---|---|
| `for_scheduling.rb` | epic becomes a scheduling parent; date propagation |
| `include_spent_time` / `costs/abstract_costs.rb` | task with parent *and* epic counted under both — double-counted hours and costs |
| `update_ancestors/loader.rb` | epic enters derived-work totals aggregation |
| `relatable.rb`, `moves_controller.rb` | relation candidates change; bulk-move limits consumed |

## Options considered

### Option 0 — Set the epic as the real parent (workaround)

Works today, zero code, per-task manual labor forever, and collapses the
distinction the epic link exists to preserve. Escape hatch, not a solution.

### Option A — Group by epic (exists, different job)

Already supported. Grouping and hierarchy are mutually exclusive
(`query.rb:146`); a group header is not a work package and can never carry a
bar. Right tool for epic *buckets*, not a tree.

### Option B — Write epic edges into `work_package_hierarchies` — REJECTED

Fights the table's owner and loses: `closure_tree` erases foreign edges on
every reparent, so keeping them alive means forking gem internals — a
permanent maintenance and upstream-sync hazard. And "everything for free"
includes what we don't want: double-counted costs and spent time, epic
participation in scheduling, totals changes, and a DAG shape the gem's
invariants don't contemplate.

### Option C — Unconditional server-side ancestor injection — REJECTED

Prepend the epic to `_links.ancestors` for every linked work package. Breaks
the forest invariant: a task with real parent P and epic E produces a chain
asserting P sits *inside* E (possibly false), and tasks under one parent
linked to different epics force that parent to render in only one subtree.

### Option D — Fallback-parent server-side injection (v1) — REJECTED IN REVIEW

v1 of this document recommended injecting the epic in
`Ancestors::Aggregator` only for work packages with no real parent. The
fallback rule itself survives (see Option E), but the server-side injection
point does not. Review findings, all verified:

1. `_links.ancestors` has at least four consumers, not one. Injection would
   corrupt the breadcrumb's hierarchy count/label state (the template
   suppresses the last ancestor and renders the real parent separately),
   desynchronize `canIndent` (ancestors-based) from `canOutdent`
   (parent-based), and cause the additional-elements service to fetch epics
   as extra rows in every hierarchy view.
2. `ancestors` is a documented public contract meaning the real parent chain.
   Injection makes the API factually wrong in every context, not just the
   Gantt.
3. Extending `include_derived_dates` globally changes every collection
   response via the eager-loading wrapper.
4. Reusing the children-duration bar for epic scope silently overloads its
   documented meaning.
5. PDF "parity" only holds when the epic is a result row; v1 overstated it.

A query-scoped server projection (e.g. `displayAncestors`) was considered as
a repair: rejected as mechanism because the per-WP representer has no query
context — threading query state into element payloads (or correlating a
collection-level side structure) is real machinery, and it creates a second
ancestors-shaped API surface that immediately becomes contract itself.

### Option E — Client-side effective-hierarchy projection *(recommended)*

> **Effective parent = real parent, falling back to the epic when the work
> package definitely has no real parent AND the epic's row is present in the
> current table page.** Built once per render as a page-scoped projection,
> consumed by all hierarchy renderers. Nothing is ever sent over the API that
> isn't true.

Four contained changes:

1. **`EffectiveHierarchyProjection` (frontend).** A page-scoped structure
   built once from the current table rows (per second review's refinement),
   centralizing: epic presence on the page, the parent tri-state (below),
   pagination scope, and collapse behavior. Consumed by
   `hierarchy-render-pass.ts` and `single-hierarchy-row-builder.ts` in place
   of raw `getAncestors()`, and by the timeline for the epic-scope envelope —
   so the renderers never independently reconstruct the fallback.
2. **Parent tri-state (one additive API property).** Because
   `_links.parent` is `{href: nil}` for both "no parent" and "invisible
   parent" (verified), the fallback condition cannot be built client-side
   alone. Add an additive, user-independent, cacheable boolean property
   `hasParent` (`represented.parent_id.present?`) to the work-package
   representer, documented in `work_packages.yml`. Adoption requires
   `hasParent === false` — a task whose real parent is merely invisible is
   **never** adopted. (This reveals the *existence* of an invisible parent,
   not its identity; noted in the API docs.)
3. **Epic-scope bar (frontend).** For epic rows, compute the envelope from
   the epic's linked children **on the current page** — from table rows, not
   from the timeline's hidden-filtered display list — and render it as a
   visually distinct bar (own style + label). Semantics: "span of the
   page's linked children." Collapse-stable by construction (collapse is not
   filtering; the rows are still on the page). Strictly non-interactive: it
   must not alter `isLeaf`, parent editing, drag handles, or date-edit
   behavior, all of which continue to read real data.
4. **PDF parity (backend, one line + spec).** In the exporter's tree builder
   (`work_package_list_to_pdf.rb`), link nodes by `parent_id || epic_id` —
   the `infos_map` lookup naturally returns nil for an epic not in the
   result set, enforcing the same "present in results" condition as the
   screen.

API surface: **one additive documented property** (`hasParent`). No changes
to any existing property or link semantics. No schema changes. No scheduling
changes.

## Why Option E

1. **Scoped by construction, not by plumbing.** Nesting appears exactly where
   the tree can actually be drawn — pages where the epic row and its children
   co-appear. The epic filter guarantees **result-set inclusion, not
   same-page placement**: nesting is page-local, and an epic on page 2 does
   not adopt a child on page 1 (see consequence 2). No query-mode flag, no
   projection parameter, no cache-splitting.
2. **The API stays true.** `ancestors`, `parent`, and the derived-date
   columns keep their documented meanings everywhere. The one addition
   (`hasParent`) is a new fact, not a changed one.
3. **The four-consumer problem dissolves.** Breadcrumb, indentation, and the
   additional-elements service read real ancestors, which are untouched.
   `canIndent`/`canOutdent` stay mutually consistent.
4. **Invariants hold.** Forest invariant: a parented task — visible parent or
   not — is never adopted, so false chains are unproducible. Single-writer
   invariant: the closure table keeps its one owner. Everything except one
   additive property is render-time; rollback is deleting the code.
5. **Acyclicity by data model.** Fallback edges point source-type →
   Epic-type only; the contract gates `epic_id` writability to source types,
   so Epics carry no `epic_id` and adoption is depth-1 by construction.
6. **Bar semantics are honest and separate.** A distinct epic-scope bar
   cannot be confused with the hierarchy children-duration bar. Visibility
   filtering is inherited free — rows not on the page cannot leak dates.
7. **It fits the population that has the problem.** The flat tasks are flat
   *because* they are parentless; the rule adopts exactly them.

## Accepted consequences and limitations

| # | Consequence | Severity | Position |
|---|---|---|---|
| 1 | Nesting appears in **any** view where an epic row and its adoptable linked tasks co-appear on a page, not only epic-filtered Gantts. | Low | Intended: the tree is drawn wherever it is drawable. |
| 2 | **Nesting is page-local.** A child on page 1 whose epic sits on page 2 renders flat. With the Gantt's default page size (250) this is rare; an always-nested UX would need an anchor-row fetch or a different pagination model — deliberate non-goals for v1. | Medium | Stated plainly; pagination-split test mandatory. |
| 3 | A task whose real parent is invisible to the viewer is not adopted (correct) but also renders flat with no explanation. | Low | Correct behavior; the alternative (adoption) asserts a false hierarchy. |
| 4 | The epic-scope bar spans the page's linked children: it shrinks when children are filtered out or on another page. It is collapse-stable (computed from page rows, not displayed rows). | Medium | Accepted for v1; revisit only if users read the bar as full scope. |
| 5 | Drag & drop writes a real parent. Dragging an adopted task "out" sets `parent = null` — already true — so it snaps back under the epic. Dragging under the epic row creates a genuine parent relation. | Low | Permission-gated (`changeParent`), never destructive. Document. |
| 6 | An adopted task is visually nested but `canOutdent` is false (no real parent to remove) and `canIndent` behaves as root-level. | Low | Honest reflection of the data; document. |
| 7 | Epic's stored work totals stay empty: the scope bar spans, totals don't roll up. | Low | v1 limitation; a page-scoped displayed-children sum could follow the same pattern. |
| 8 | PDF nests only when the epic is a result row (automatic via `infos_map`); non-epic-filtered exports of adopted tasks stay flat. | Low | Matches the screen's own condition; stated, not hidden. |
| 9 | Breadcrumb of an adopted task shows no epic (real ancestors only). | None | Correct per review; the epic is visible in the work package's `epic` field. |
| 10 | `hasParent` reveals that an invisible parent *exists* (not which one). | Low | Documented in the API docs; identity is not exposed. |

## Decisions

Following the Q&A convention of the original epic-link doc:

1. Fallback rule — adopt the epic as display parent only when there is no
   real parent?
   A: **yes** (agreed 2026-08-23)
2. Injection point — server (`_links.ancestors` / projection) or client
   (table renderer)?
   A: **client-side, as a page-scoped `EffectiveHierarchyProjection`**
   (v2 after first review; projection form per second review, 2026-08-23)
3. Bar semantics — span of the page's linked children (client-side,
   filter-sensitive) or all linked children (server-side opt-in,
   filter-stable)?
   A: **page's linked children, as a distinct epic-scope bar** (2026-08-23)
4. Drag-and-drop snap-back: document, or guard?
   Recommended: document — permission-gated, non-destructive, and a guard
   would also block intentional real-nesting under an epic.
   A: **document** (agreed 2026-08-23)
5. Collapse behavior of the epic-scope bar — hide with the children, or stay
   stable?
   Recommended: **stable** — collapse is presentation, not filtering; the
   children are still on the page. Achieved by computing the envelope from
   table rows rather than the timeline's hidden-filtered list.
   A: **stable** (agreed 2026-08-23)
6. Parent tri-state signal — additive `hasParent` boolean property, or
   accept misadoption when a real parent is invisible?
   Recommended: **`hasParent`** — the raw HAL link demonstrably does not
   preserve the distinction, and misadoption asserts a false hierarchy.
   A: **`hasParent`** (agreed 2026-08-23)

## Mandatory test list (both reviews, adopted)

- Ordinary hierarchy and API behavior unchanged (`_links.ancestors`,
  breadcrumb, indent/outdent, additional-elements — request + unit specs).
- Epic-filtered Gantt nesting (feature spec: adopted tasks nest, epic on top).
- Parented linked tasks: nest under their real parent, still count toward the
  epic filter; epic-scope bar per decision 3.
- **Visible epic + child whose real parent is invisible: child is NOT
  adopted** (tri-state test).
- **Pagination split: epic and child on different pages ⇒ child renders
  flat, no errors; same page ⇒ nested** (page-local test).
- Invisible / cross-project children: absent from the page ⇒ absent from
  nesting and from the epic-scope bar (no date leakage).
- **Collapse: epic-scope bar per decision 5; collapse/expand does not alter
  `isLeaf`, drag handles, or date editing on any row.**
- Drag & drop on adopted subtrees (snap-back behavior documented and
  asserted).
- PDF parity: adopted task nests in the exported tree when the epic is a
  result row; flat otherwise.

## Implementation sketch

| Change | Files | Kind |
|---|---|---|
| `EffectiveHierarchyProjection` (page-scoped; epic presence, tri-state, adoption map, epic envelope) | new service under `wp-fast-table/` | TS + unit specs |
| Renderer + row builder consume the projection | `hierarchy-render-pass.ts`, `single-hierarchy-row-builder.ts` | TS |
| Epic-scope bar (distinct style + label, non-interactive, envelope from projection) | `timeline-cell-renderer.ts` | TS + unit specs |
| `hasParent` additive property | `work_package_representer.rb`, `docs/api/apiv3/tags/work_packages.yml` | Ruby + representer spec |
| PDF fallback (`parent_id \|\| epic_id` in tree linking) | `app/models/work_package/pdf_export/work_package_list_to_pdf.rb` | Ruby + export spec |
| Feature spec: epic-filtered Gantt (incl. pagination split, invisible parent) | `spec/features/work_packages/...` | Ruby |

Backend surface: one additive representer property + the PDF exporter. TDD
throughout; branch off `epic`.
