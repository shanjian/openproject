# Speed up work-package relation-filter autocomplete (Epic, Parent, Blocks, …)

**Date:** 2026-08-23
**Status:** Implemented, with §3's migration reverted post-verification — see "Outcome" below

## Problem

The Epic filter's value picker in the Gantt/query filter bar is very slow to autocomplete.

`EpicFilterDependencyRepresenter#href_callback`
(`lib/api/v3/queries/schemas/epic_filter_dependency_representer.rb:46`) points the value
picker at the generic, full-fidelity `/api/v3/work_packages` collection endpoint, scoped
to epic-typed work packages but never to a single project — epics are deliberately
cross-project. `FilterSearchableMultiselectValueComponent`
(`frontend/src/app/features/work-packages/components/filters/filter-searchable-multiselect-value/filter-searchable-multiselect-value.component.ts:100`)
fires this once via `loadCollection('')` on init and caches it with `shareReplay(1)`.

The href hardcodes `&pageSize=-1`, which looks like "fetch every epic in the instance
unbounded" — that reading is wrong today. `addFiltersToPath`
(`frontend/src/app/core/apiv3/helpers/add-filters-to-path.ts`) overwrites `pageSize` with
whatever the caller passes, and `loadCollection` always passes
`MAGIC_FILTER_AUTOCOMPLETE_PAGE_SIZE` (100), so the real request today is always
`pageSize=100`. The actual failure mode: because the candidate pool is instance-wide
rather than per-project, Epic is the filter in this family most likely to exceed that
100-row cap on any non-trivial instance. Once it does,
`FilterSearchableMultiselectValueComponent.autocomplete()` (line 112) takes the
"request the matching API call" branch on **every keystroke**, each one paying full
`WorkPackage.visible` authorization plus `WorkPackageCollectionFromQueryService` →
`WorkPackageCollectionRepresenter` serialization (schema embed, every `_links`, custom
fields, permitted-actions per row) for up to 100 rows — to populate an id+label dropdown.

This is not Epic-specific. `EpicFilterDependencyRepresenter` is one of ~15 subclasses of
`ByWorkPackageFilterDependencyRepresenter`
(`lib/api/v3/queries/schemas/by_work_package_filter_dependency_representer.rb`) — Parent,
Blocks, Blocked, Duplicates, Duplicated, Follows, Includes, PartOf, Ancestor, Relates,
Precedes, Requires, Required, plus Id. They share the identical mechanism and would show
the same symptom once their (normally project-scoped, so usually smaller) candidate pool
exceeds 100 rows. Epic simply lost the project-scoping safety net by design, so it's the
first to expose an inefficiency baked into the whole family.

## Review findings (addressed below)

An external review of the first draft of this spec caught two real issues before any
code was written:

- **P1 (confirmed, design changed):** §2 originally proposed wiring `<op-autocompleter>`
  via its bare `[url]`/`[resource]` inputs. Verified against
  `op-autocompleter.component.ts:318-323` and `:486`: `OpAutocompleterComponent.ngOnInit()`
  only creates the `typeahead` `BehaviorSubject` when `getOptionsFn` or `defaultData` is
  set; with neither set, `autocompleteInputStream()` hits `if (!this.typeahead) return NEVER`
  before it ever reaches the `this.url` branch. The `[url]`-only path would never fetch
  anything, on init or on keystroke. Confirmed further that **no existing caller uses
  `[url]` as a bare template input anywhere in the frontend** — the one real consumer of
  `OpAutocompleterService.loadFromUrl`, `TimeEntriesWorkPackageAutocompleterComponent`
  (`frontend/src/app/shared/components/autocompleter/time-entries-work-package-autocompleter/time-entries-work-package-autocompleter.component.ts:133-144`),
  calls it from inside its own `getOptionsFn`, not through the component's built-in `url`
  branch. §2 below now follows that same precedent instead of depending on the dead path.
  This also removes the need for a separate `allowEmpty` input on
  `OpAutocompleterComponent` — `allowEmpty` becomes a plain literal argument in the
  wrapper function instead.
- **P2 (confirmed, scope expanded, verification gate added):** the migration (§3) was
  originally just a single trigram index on `work_packages.subject`. Verified against
  `Queries::WorkPackages::Filter::TypeaheadFilter#where` (`typeahead_filter.rb:41-56`) and
  `Queries::Operators::Concerns::ContainsAllValues.sql_for_field`
  (`app/models/queries/operators/concerns/contains_all_values.rb:36-42`): the actual
  predicate per search token is
  `(work_packages.subject ILIKE '%t%' OR projects.name ILIKE '%t%' OR types.name ILIKE '%t%' OR statuses.name ILIKE '%t%' [OR id::varchar LIKE '%t%'])`,
  ANDed across whitespace-split tokens. A subject-only index provably helps just one
  disjunct of a four-table OR; whether Postgres's planner can exploit per-table indexes
  across an OR spanning a join at all (versus falling back to scanning/joining most of
  `work_packages` regardless) is a real open question, not something credibly settled
  by code reading alone. I tried to confirm with a live `EXPLAIN` against this checkout's
  dev database and couldn't get a response inside a reasonable timeout; a small/seed
  dataset wouldn't have been representative of production scale regardless. §3 below adds
  the second index this reasoning clearly calls for either way (`projects.name` — the
  other side of the join that can plausibly be large), explains why `types`/`statuses`
  don't need one, and turns the "does this actually get used by the planner" question into
  a required `EXPLAIN ANALYZE` gate during implementation rather than an assumption, naming
  "narrow the picker's search contract to subject+id" as the fallback if it doesn't.
  **Follow-up on the same finding:** the bracketed `id::varchar LIKE '%t%'` disjunct above
  is real, not a footnote — `TypeaheadFilter#where` adds it whenever a search token is
  purely numeric (`typeahead_filter.rb:50`), via `id_condition`
  (`typeahead_filter.rb:88-90`): `work_packages.id::varchar(20) LIKE '%#{string}%'`. Neither
  proposed index touches this — it's a substring match over a *cast expression*, which
  `gin_trgm_ops` on the raw columns can't serve, and my first pass at the EXPLAIN gate only
  specified "a representative multi-word search term," which would never exercise this
  branch at all (the numeric check only fires for tokens that are entirely digits). §3
  below now requires the gate to test a numeric term too, and names both real fixes if it's
  slow rather than picking one: a functional trigram index on `id::varchar(20)` (keeps
  today's substring-on-id semantics), or changing `id_condition` to an exact match
  (`work_packages.id = string.to_i`), which needs no new index at all since `id` already
  has its primary-key index (`work_packages_pkey`, confirmed in `db/structure.sql`) — exact
  match is arguably what a user typing a number actually wants, but `TypeaheadFilter` is
  shared well beyond this filter family (it backs work-package search-as-you-type
  generally), so narrowing its semantics is a product decision for the user, not something
  to pick unilaterally while implementing this.

## Key mechanism

The codebase already solves "cheap work-package lookup" elsewhere, and we can reuse it
instead of building anything new:

- `WorkPackageSqlRepresenter` (`lib/api/v3/work_packages/work_package_sql_representer.rb`)
  builds the JSON response directly in Postgres via `SqlRepresenterWalker` — no per-row
  Ruby representer instantiation, no schema embed, no custom-field processing unless
  selected. It activates whenever a request includes a `select=` param
  (`WorkPackageCollectionFromQueryService#collection_representer`,
  `app/services/api/v3/work_package_collection_from_query_service.rb:142`). Authorization
  is unaffected — `.visible` is already applied to the scope before either representer
  touches it; the fast path only changes what gets serialized.
- `OpAutocompleterService.createParams('work_packages')`
  (`frontend/src/app/shared/components/autocompleter/op-autocompleter/services/op-autocompleter.service.ts:63`)
  already requests exactly
  `select: 'elements/id,elements/subject,elements/author,elements/type,elements/project,elements/status'`
  for this purpose. `loadFromUrl` (line 108) takes an arbitrary schema-provided href plus
  a search term and applies that select automatically — the "custom URL" path already used
  by `TimeEntriesWorkPackageAutocompleterComponent` for exactly our situation: a
  schema-provided href that isn't a plain `apiV3Service.work_packages` shortcut. That
  component calls `loadFromUrl` from its own `getOptionsFn`, which is the pattern §2
  follows (see "Review findings" above — the component's *built-in* `[url]` input path is
  unused and does not work).
- `<op-autocompleter>` already renders a richer, purpose-built work-package option row
  (author avatar, colored type/status —
  `op-autocompleter.component.html:148-163`) whenever its `resource` input is
  `'work_packages'`. That binding is independent of how the data gets fetched, so it works
  the same whether fetching goes through `getOptionsFn` or the (unused) `url` input.

So the fix is: stop `FilterSearchableMultiselectValueComponent` from hand-rolling its own
fetch/serialize path for work-package-backed filters, and delegate to
`OpAutocompleterService.loadFromUrl` instead, the same way the time-logging picker already
does. The only backend touch is deleting a stray query param (§2a) and adding two indexes
(§3) — `epic_filter.rb` and the representer's type-scoping (shipped today, fixing a real
correctness bug) are otherwise untouched, and no new Ruby classes are introduced anywhere.

## Design

### 1. Detect work-package-backed filters generically

`FilterSearchableMultiselectValueComponent` already special-cases resource kind by
inspecting the value schema's type string — `isVersionResource`/`isUserResource`
(`filter-searchable-multiselect-value.component.ts:215-223`). Add the same style of
getter:

```typescript
private get isWorkPackageResource() {
  const type = _.get(this.filter.currentSchema, 'values.type', null) as string;
  return type && type.indexOf('WorkPackage') > 0;
}
```

This covers every `ByWorkPackageFilterDependencyRepresenter` subclass, because they all
expose `type => "[]WorkPackage"` (`by_work_package_filter_dependency_representer.rb:49`)
unless overridden, and none of the subclasses override it.

Replace the current `ngOnInit` special case
(`if (this.filter.id === 'id') { this.resourceType = 'work_packages'; }` — narrower and,
since `getOptionsFn` always wins over `resource` today, currently inert) with
`this.resourceType = this.isWorkPackageResource ? 'work_packages' : null;`.

### 2. Wrap `OpAutocompleterService.loadFromUrl` in `getOptionsFn` (revised per P1)

Inject `OpAutocompleterService` into `FilterSearchableMultiselectValueComponent`
(constructor already has `apiV3Service` and `halResourceService`, the two dependencies
`OpAutocompleterService` needs — instantiate it the same way `OpAutocompleterComponent`
itself does: `private readonly opAutocompleterService = new OpAutocompleterService(this.apiV3Service, this.halResourceService);`).

Change `autocompleterFn` to branch on `isWorkPackageResource`:

```typescript
autocompleterFn = (searchTerm:string):Observable<HalResource[]> =>
  this.isWorkPackageResource
    ? this.opAutocompleterService.loadFromUrl(this.allowedValuesLink, searchTerm, 'work_packages', [], 'typeahead', true)
    : this.autocomplete(searchTerm);
```

The `true` in the last position is `allowEmpty` — passed as a literal, not a new
`@Input()` (see "Review findings" P1) — preserving today's "open the filter, see a
browsable list immediately" behavior. No template change is needed:
`[resource]="resourceType"` has been bound on `<op-autocompleter>` in this template since
2023 (`git blame` on that line: `76ad986aff5`, an upstream OpenProject commit, predating
this fork's epic-filter work entirely) — it was inert for Epic/Parent/etc. only because
`resourceType` itself was never set to anything but `null` for them. §1's broader
`isWorkPackageResource` detection is what activates the richer work-package option row for
this whole family; the binding it feeds was already there. (An earlier draft of this spec
incorrectly claimed this binding needed to be added — corrected after review.)

`addFiltersToPath` (used internally by `loadFromUrl`) already merges the `typeahead`
filter it builds with whatever `filters=` the href embeds (concat, not overwrite) and
overwrites plain params like `select` — this is the same merge behavior the current code
already relies on. The Epic filter's embedded `type` constraint therefore keeps ANDing
correctly with the typeahead search term.

The non-work-package branch (Version, User, plain string-list filters) is unchanged:
`autocomplete()`/`loadCollection()`/`matchingItems()` stay exactly as they are today and
keep serving those cases.

Guard `ngOnInit`'s `initialRequest$` setup with the same branch: today it unconditionally
builds `this.loadCollection('').pipe(shareReplay(1))`. In the work-package branch nothing
ever subscribes to it, and the observable is cold (HttpClient + `shareReplay` fire nothing
without a subscriber), so leaving it would not actually issue the old heavy request — but
skip creating it anyway so the next reader doesn't have to re-derive that, and so a future
subscriber can't silently resurrect the slow path.

### 2a. Remove `pageSize=-1` — required, not cosmetic, once §2 lands

Today `&pageSize=-1` in `EpicFilterDependencyRepresenter#href_callback` is inert: the old
frontend flow always calls
`.filtered(filters, { pageSize: MAGIC_FILTER_AUTOCOMPLETE_PAGE_SIZE })`, and
`addFiltersToPath` overwrites any existing `pageSize` with that value.
**`OpAutocompleterService.createParams('work_packages')` does not set a `pageSize` key at
all**, so once §2 switches Epic onto that path, nothing overwrites the href's `-1` any
more — it would reach `WorkPackageCollectionFromQueryService#calculate_resulting_params`
(`app/services/api/v3/work_package_collection_from_query_service.rb:81`) as a real,
provided `pageSize` param and override the default. `-1` is not literally unbounded:
`resolve_page_size` (`lib/api/utilities/url_props_parsing_helper.rb:37-38`) treats it as
a magic number for `Setting.apiv3_max_page_size` — default **1000**. Still: every picker
request would fetch up to 1000 rows, 10× what the old flow fetched and far beyond what a
dropdown page needs — a serving of the very regression this design removes, reintroduced
by the frontend change itself. This must ship together with §2, not as a follow-up.

The fix is to delete the `pageSize` param from the href entirely, not replace it with a
different hardcoded number. With it gone, `calculate_default_params`
(`lib/api/decorators/query_params_representer.rb:91`) supplies
`pageSize: Setting.per_page_options_array.first` — the same system-configurable default
every other filter in the family already relies on implicitly (their hrefs never set
`pageSize` either). This makes Epic consistent with its siblings instead of pinned to a
magic number that would drift from `per_page_options` if an admin ever changes it. Keep
the `filters=` type-scoping query param — that part is load-bearing and must stay.

### 3. Migration: trigram indexes, plus a required EXPLAIN gate (revised per P2)

No index currently backs `work_packages.subject` or `projects.name` (confirmed against
`db/structure.sql` — `pg_trgm` is enabled instance-wide for other columns like
`custom_values.value` and `journals.notes`, but not either of these). Once Epic/Parent/
etc. route real search terms to the server on every keystroke instead of filtering a
client-side cache, `TypeaheadFilter`'s `ILIKE '%term%'` predicate across `subject`,
`projects.name`, `types.name`, and `statuses.name` (see "Review findings" P2) becomes
load-bearing in a way it mostly wasn't before (today, `count === total` most of the time
only because the pool is small enough to fit one page — the search barely ever leaves the
browser for these filters currently).

Index the two columns that can plausibly grow large — `work_packages.subject` and
`projects.name` — the same way:

```ruby
class AddTrigramIndexesForTypeaheadSearch < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :work_packages, :subject,
              using: :gin,
              opclass: :gin_trgm_ops,
              algorithm: :concurrently,
              name: "index_work_packages_on_subject_trigram"

    add_index :projects, :name,
              using: :gin,
              opclass: :gin_trgm_ops,
              algorithm: :concurrently,
              name: "index_projects_on_name_trigram"
  end
end
```

`algorithm: :concurrently` avoids locking the tables on production-sized instances;
requires `disable_ddl_transaction!`.

**Deliberately not indexing `types.name` / `statuses.name`:** both are small,
admin-curated lookup tables (typically single- to low-double-digit row counts, bounded by
how many work types/statuses an instance administrator configures — not by data volume
like work packages or projects). A sequential scan there costs nothing at any realistic
size, so an index would add write overhead for no read benefit.

**Required verification gate, not an assumption:** indexing `subject` and `projects.name`
individually does not by itself prove Postgres's planner can use either index for this
specific shape of query — a single `WHERE` clause ORing conditions across four tables
joined together. Before this migration is considered done, run
`EXPLAIN ANALYZE` on the actual `TypeaheadFilter` query against a realistic (production-
scale, or a synthetic approximation of one) work-package table, with **two** representative
search terms, not one:

1. A multi-word term (e.g. a real epic subject fragment) — exercises the
   `subject`/`projects.name`/`types.name`/`statuses.name` OR this migration's indexes
   target.
2. A purely numeric term (e.g. `"42"`) — exercises `id_condition`'s
   `id::varchar(20) LIKE '%42%'` (`typeahead_filter.rb:88-90`), which neither index above
   covers at all, since it's a substring match over a cast expression rather than a plain
   column.

Confirm the plan uses bitmap/index scans rather than sequential-scanning a large fraction
of `work_packages` or `projects` for **both** cases. **If the multi-word case fails**, the
fallback is narrowing the picker's search contract — e.g. a variant of `typeahead` that
only matches `subject` and `id` for filter-value pickers specifically, dropping
project/type/status name matching for this use case — rather than adding more indexes
speculatively. **If the numeric case fails**, the two fixes are a functional trigram index
on `id::varchar(20)` (preserves today's substring-on-id behavior) or changing
`id_condition` to an exact match against the already-indexed primary key (`id = string.to_i`,
needs no new index, and is arguably the more sensible behavior for a number a user typed).
Either multi-word or numeric fallback is a product-visible behavior change — the numeric
one doubly so, since `TypeaheadFilter` is shared by work-package search-as-you-type
generally, not just this filter family — so both should go back to the user as their own
decision if they become necessary, not something to decide unilaterally mid-implementation.

### 4. Tests

- `filter-searchable-multiselect-value.component.spec.ts` (new, none exists today per
  codegraph's "no covering tests found"): `isWorkPackageResource` detection for an
  Epic/Parent-shaped schema vs. a Version/User-shaped one; `autocompleterFn` calls
  `opAutocompleterService.loadFromUrl` with `allowEmpty=true` for the work-package case
  and falls through to the existing `autocomplete()` for the Version/User case.
- `epic_filter_dependency_representer_spec.rb`: href contains no `pageSize` param at all
  (not just "not `-1`" — asserting its absence is what guarantees the system default
  applies instead of a hardcoded stand-in); still contains the epic-type `filters=`
  constraint.
- Migration spec confirming both trigram indexes exist.
- **The EXPLAIN ANALYZE gate from §3, for both a multi-word and a numeric search term** —
  not optional, run against realistic data volume before claiming this design fixes
  server-side search performance, with the two fallbacks named above (search-contract
  narrowing; exact-ID matching or a functional index) if either case fails.
- Manual verification in the browser (per CLAUDE.md UI-change guidance): open the Epic
  filter's value picker in a Gantt view on an instance with >100 visible epics across
  projects, confirm the dropdown opens with a visible initial list, typing narrows results
  server-side, and Network tab shows the `select=` param and a much smaller response
  payload than before. Also load a **saved** query that already has epic-filter values and
  confirm the selected chips render and stay clearable: setting `[resource]="'work_packages'"`
  switches the chip template to `{{ item.type?.name }} #{{ item.id }} {{ item.subject || item.name }}`
  (`op-autocompleter.component.html:223-237`), and saved values are minimal HalResources
  (self href + title) — verified that `item.id` derives from the href and `item.subject`
  falls back to `item.name` (= the link title), so chips should render as `#123 Epic name`,
  but this is exactly the kind of claim the browser has to confirm. The chip format change
  itself is intentional — part of the approved richer-row adoption.

## Outcome

§1/§2/§2a shipped as designed and are the real fix: Epic's own picker query runs in
~217-249ms against a 100k-row synthetic table (down from the original full-representer,
unbounded-fetch behavior), verified via `EXPLAIN ANALYZE` on the actual `Query::Results`
pipeline (not a hand-built approximation — see the implementation plan's Task 5 for the
methodology and full plans).

§3's required verification gate did its job, but the answer came back negative. Across 5
`EXPLAIN ANALYZE` plans — three with Epic's own `type_id = Epic` co-filter present, two
without — Postgres never once chose either trigram index. The reason is structural, not a
missed opportunity a bigger table or a different search term would fix: `Query::Results`
composes the query as `<filters> AND EXISTS(<visibility CTE>)`, and Postgres's plan always
fully materializes the visibility CTE across every visible row before evaluating the
`ILIKE` typeahead conditions as a late join filter. An index on `subject`/`projects.name`
is therefore unreachable by this query shape regardless of scale. Epic's queries stayed
fast anyway only because its separate `type_id` filter is independently selective and
reuses a pre-existing, unrelated index (`index_work_packages_on_type_id`) — masking the
gap rather than the trigram indexes closing it. Without a comparable co-filter (the
"no selective co-filter" run), the same search took ~1000ms by fully materializing and
late-filtering the visible set.

Per the project owner's explicit decision, the migration was reverted rather than shipped
as dead weight — an index Postgres never uses costs write overhead and disk with no read
benefit. This does not touch §1/§2/§2a, which remain the shipped fix. The open question
this leaves — whether a filter in this family that genuinely lacks a selective co-filter
(a global, cross-project typeahead search with no type or project constraint) needs a
different mitigation — was not resolved and was not pursued further; it would require
changing how `Query::Results` composes the visibility check with a filter's `WHERE`
clause, a materially larger change than anything in this design.

## Out of scope

- Any change to `epic_filter.rb`'s own `where`/`epic_typed_values` query-application logic
  (applying the filter to Gantt *results*) — this spec is about the value *picker* only,
  a separate code path from applying an already-chosen filter value.
- Migrating Version- or User-backed filters (or any other non-`[]WorkPackage` schema) onto
  the `OpAutocompleterService`-backed path. Not reported as slow, different resource shape
  (`groupByFn`/`withMeValue` special-casing in `FilterSearchableMultiselectValueComponent`
  stays exactly as it is for these).
- `AvailableEpicCandidatesAPI` / `AvailableRelationCandidatesAPI` (the work-package form's
  own "pick an epic" / "add relation" pickers) — already reasonably fast (`pageSize: 10`
  default) and a separate UI surface from the query filter bar. Not touched.
- New backend representer classes or endpoints of any kind. The whole point of this
  design is that the existing SQL fast path already does what's needed — the only Ruby
  edits anywhere in this design are the one-line param removal in §2a and the migration in
  §3.
- Fixing `OpAutocompleterComponent`'s dead `[url]`-only input path (P1). It's a real latent
  bug, but out of scope here since §2 sidesteps it entirely by following the
  already-precedented `getOptionsFn`-wrapping pattern; fixing the framework component
  itself would be a separate, independently-reviewable change.
- Narrowing the typeahead search contract to subject+id only. Named as the fallback in §3
  if the EXPLAIN gate fails, but not pre-emptively adopted — it's a product behavior
  change that should be a deliberate decision, not a default.
