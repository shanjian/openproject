# Work-Package Filter Autocomplete Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Epic/Parent/Blocks/etc. filter value pickers in the query filter bar fast, by routing their autocomplete through the codebase's existing cheap work-package lookup path instead of the full-fidelity work-packages table representer.

**Architecture:** Frontend-only behavior change (delegate `FilterSearchableMultiselectValueComponent`'s work-package-backed autocomplete to `OpAutocompleterService.loadFromUrl`, the same call the time-logging picker already uses) plus two small backend touches (delete a stray query param, add two trigram indexes). No new backend classes.

**Tech Stack:** Angular/TypeScript (frontend), Ruby/Rails + RSpec (backend), PostgreSQL migration.

**Spec:** `docs/superpowers/specs/2026-08-23-work-package-filter-autocomplete-perf-design.md`

## Global Constraints

- No new backend representer classes or endpoints — reuse `OpAutocompleterService.loadFromUrl` and the existing SQL fast path (`WorkPackageSqlRepresenter`).
- `epic_filter.rb`'s own `where`/`epic_typed_values` logic (applying the filter to Gantt results) is untouched — this plan only changes the value *picker*.
- Version- and User-backed filters keep using `FilterSearchableMultiselectValueComponent`'s existing `autocomplete()`/`loadCollection()`/`matchingItems()` path unchanged.
- Migrations use `algorithm: :concurrently` + `disable_ddl_transaction!` (production-safe, no table lock).
- Any further search-contract narrowing (dropping project/type/status/id matching from `typeahead`) is a product decision for the user, not something a task in this plan decides unilaterally — Tasks 5 names it only as a documented fallback if verification fails.

---

## File Structure

- Modify `frontend/src/app/features/work-packages/components/filters/filter-searchable-multiselect-value/filter-searchable-multiselect-value.component.ts` — generalize resource-type detection (Task 1), delegate to `OpAutocompleterService` for work-package-backed filters (Task 2). The sibling `.html` template needs no change — `[resource]="resourceType"` has been bound there since 2023 (upstream commit `76ad986aff5`); it just does nothing for Epic/Parent/etc. until Task 1 makes `resourceType` resolve to `'work_packages'` for them too.
- Create `frontend/src/app/features/work-packages/components/filters/filter-searchable-multiselect-value/filter-searchable-multiselect-value.component.spec.ts` — first test coverage for this component (Tasks 1 and 2 each add cases).
- Modify `lib/api/v3/queries/schemas/epic_filter_dependency_representer.rb` — drop the stray `pageSize=-1` (Task 3).
- Modify `spec/lib/api/v3/queries/schemas/epic_filter_dependency_representer_spec.rb` — assert its absence (Task 3).
- Create `db/migrate/20260823120000_add_trigram_indexes_for_typeahead_search.rb` — the two trigram indexes (Task 4).
- Create `spec/db/indexes_spec.rb` — asserts both indexes exist (Task 4).
- Task 5 (EXPLAIN ANALYZE gate) and Task 6 (browser verification) are manual verification tasks — no new files, they validate Tasks 1-4's output against realistic conditions.

---

### Task 1: Generalize work-package-filter detection in `FilterSearchableMultiselectValueComponent`

**Files:**
- Modify: `frontend/src/app/features/work-packages/components/filters/filter-searchable-multiselect-value/filter-searchable-multiselect-value.component.ts`
- Create: `frontend/src/app/features/work-packages/components/filters/filter-searchable-multiselect-value/filter-searchable-multiselect-value.component.spec.ts`

**Note:** the `.html` template in this same directory is NOT touched by this task. It already has `[resource]="resourceType"` bound on `<op-autocompleter>` — confirmed via `git blame` (line dates to commit `76ad986aff5`, 2023, upstream). That binding has simply had no effect for Epic/Parent/etc. because `resourceType` was never set to anything but `null` for them; this task's `.ts` change is what activates it, with zero template edit required.

**Interfaces:**
- Consumes: `QueryFilterInstanceResource.currentSchema.values.type` (existing HAL schema shape; already read the same way by `isVersionResource`/`isUserResource` at `filter-searchable-multiselect-value.component.ts:215-223`).
- Produces: `private get isWorkPackageResource():boolean` and `resourceType:'work_packages'|null` — Task 2 reads both.

- [ ] **Step 1: Write the failing test**

Create the spec file:

```typescript
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { NO_ERRORS_SCHEMA } from '@angular/core';
import { of } from 'rxjs';
import { FilterSearchableMultiselectValueComponent } from './filter-searchable-multiselect-value.component';
import { HalResourceService } from 'core-app/features/hal/services/hal-resource.service';
import { ApiV3Service } from 'core-app/core/apiv3/api-v3.service';
import { I18nService } from 'core-app/core/i18n/i18n.service';
import { CurrentProjectService } from 'core-app/core/current-project/current-project.service';
import { CurrentUserService } from 'core-app/core/current-user/current-user.service';
import { HalResourceNotificationService } from 'core-app/features/hal/services/hal-resource-notification.service';
import { QueryFilterInstanceResource } from 'core-app/features/hal/resources/query-filter-instance-resource';

describe('FilterSearchableMultiselectValueComponent', () => {
  let fixture:ComponentFixture<FilterSearchableMultiselectValueComponent>;
  let component:FilterSearchableMultiselectValueComponent;

  function filterWithType(type:string, href = '/api/v3/work_packages?filters=%5B%5D'):QueryFilterInstanceResource {
    return {
      id: 'epic',
      values: [],
      currentSchema: {
        values: {
          type,
          allowedValues: { href },
        },
      },
    } as unknown as QueryFilterInstanceResource;
  }

  beforeEach(() => {
    TestBed.configureTestingModule({
      declarations: [FilterSearchableMultiselectValueComponent],
      schemas: [NO_ERRORS_SCHEMA],
      providers: [
        { provide: HalResourceService, useValue: { createHalResource: () => ({}) } },
        {
          provide: ApiV3Service,
          useValue: {
            collectionFromString: () => ({
              filtered: () => ({
                get: () => of({ elements: [], count: 0, total: 0 }),
              }),
            }),
          },
        },
        { provide: I18nService, useValue: { t: (key:string) => key } },
        { provide: CurrentProjectService, useValue: {} },
        { provide: CurrentUserService, useValue: { isLoggedIn$: of(false), user$: of(null) } },
        { provide: HalResourceNotificationService, useValue: {} },
      ],
    });

    fixture = TestBed.createComponent(FilterSearchableMultiselectValueComponent);
    component = fixture.componentInstance;
  });

  describe('resourceType detection', () => {
    it('resolves to "work_packages" for a []WorkPackage-typed filter (Epic, Parent, Blocks, ...)', () => {
      component.filter = filterWithType('[]WorkPackage');
      component.ngOnInit();
      expect(component.resourceType).toBe('work_packages');
    });

    it('stays null for a []Version-typed filter', () => {
      component.filter = filterWithType('[]Version');
      component.ngOnInit();
      expect(component.resourceType).toBeNull();
    });

    it('stays null for a []User-typed filter', () => {
      component.filter = filterWithType('[]User');
      component.ngOnInit();
      expect(component.resourceType).toBeNull();
    });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && CHROME_BIN=/usr/bin/google-chrome npx ng test --watch=false --include='**/filter-searchable-multiselect-value.component.spec.ts'`
Expected: FAIL — `resourceType` is `null` for the `[]WorkPackage` case too, because `ngOnInit` currently only special-cases `this.filter.id === 'id'`, and the test's stub filter has `id: 'epic'`.

- [ ] **Step 3: Add the `isWorkPackageResource` getter and generalize `ngOnInit`**

In `filter-searchable-multiselect-value.component.ts`, add the getter next to the existing `isVersionResource`/`isUserResource` getters (after line 223):

```typescript
  private get isWorkPackageResource() {
    const type = _.get(this.filter.currentSchema, 'values.type', null) as string;
    return type && type.indexOf('WorkPackage') > 0;
  }
```

Replace the `ngOnInit` body (currently lines 100-110):

```typescript
  ngOnInit():void {
    this.resourceType = this.isWorkPackageResource ? 'work_packages' : null;

    this.initialRequest$ = this
      .loadCollection('')
      .pipe(
        shareReplay(1),
      );
  }
```

(The `initialRequest$` line stays unconditional for now — Task 2 guards it once the work-package branch stops needing it.)

No template change is needed: `[resource]="resourceType"` is already bound on
`<op-autocompleter>` in `filter-searchable-multiselect-value.component.html` (confirmed
via `git blame` — that line dates to commit `76ad986aff5`, 2023, upstream, predating this
fork's epic-filter work entirely). It has simply had no effect for Epic/Parent/etc.
because `resourceType` was never set to anything but `null` for them until this step.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd frontend && CHROME_BIN=/usr/bin/google-chrome npx ng test --watch=false --include='**/filter-searchable-multiselect-value.component.spec.ts'`
Expected: PASS (all three `resourceType detection` cases).

- [ ] **Step 5: Lint**

Run: `cd frontend && npx eslint src/app/features/work-packages/components/filters/filter-searchable-multiselect-value/`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/app/features/work-packages/components/filters/filter-searchable-multiselect-value/
git commit -m "Detect work-package-backed filters generically in the searchable multiselect

Generalizes the resourceType special-case (previously only set for the
'id' filter, and inert since getOptionsFn always won anyway) to every
filter whose value schema is a []WorkPackage collection -- Epic, Parent,
Blocks, and the rest of that family. The template's existing (2023,
upstream) [resource]=\"resourceType\" binding on <op-autocompleter> starts
having an effect for them as a result, activating its richer
work-package option/chip template -- no template edit needed."
```

---

### Task 2: Delegate work-package autocomplete to `OpAutocompleterService.loadFromUrl`

**Files:**
- Modify: `frontend/src/app/features/work-packages/components/filters/filter-searchable-multiselect-value/filter-searchable-multiselect-value.component.ts`
- Modify: `frontend/src/app/features/work-packages/components/filters/filter-searchable-multiselect-value/filter-searchable-multiselect-value.component.spec.ts`

**Interfaces:**
- Consumes: `isWorkPackageResource` and `resourceType` from Task 1; `OpAutocompleterService.loadFromUrl(url:string, matching:string|null, resource:TOpAutocompleterResource, filters?:IAPIFilter[], searchKey?:string, allowEmpty = false):Observable<HalResource[]>` (`op-autocompleter/services/op-autocompleter.service.ts:108` — existing, unmodified).
- Produces: `autocompleterFn` now branches; `readonly opAutocompleterService` instance property other code in this file (or a future subclass) can reach, matching the same public-field convention `OpAutocompleterComponent` itself uses.

- [ ] **Step 1: Write the failing tests**

Add to `filter-searchable-multiselect-value.component.spec.ts`, inside the existing `describe('FilterSearchableMultiselectValueComponent', ...)` block, after the `resourceType detection` block:

```typescript
  describe('autocompleterFn', () => {
    it('delegates to OpAutocompleterService.loadFromUrl for a work-package-backed filter', () => {
      const href = '/api/v3/work_packages?filters=%5B%7B%22type%22%3A%7B%22operator%22%3A%22%3D%22%2C%22values%22%3A%5B%221%22%5D%7D%7D%5D';
      component.filter = filterWithType('[]WorkPackage', href);
      component.ngOnInit();
      const loadFromUrlSpy = spyOn(component.opAutocompleterService, 'loadFromUrl').and.returnValue(of([]));

      component.autocompleterFn('epi').subscribe();

      expect(loadFromUrlSpy).toHaveBeenCalledWith(href, 'epi', 'work_packages', [], 'typeahead', true);
    });

    it('falls back to the existing HAL-collection autocomplete for a non-work-package filter', (done) => {
      component.filter = filterWithType('[]Version');
      component.ngOnInit();

      component.autocompleterFn('').subscribe((result) => {
        expect(result).toEqual([]);
        done();
      });
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd frontend && CHROME_BIN=/usr/bin/google-chrome npx ng test --watch=false --include='**/filter-searchable-multiselect-value.component.spec.ts'`
Expected: FAIL on the first new case — `component.opAutocompleterService` doesn't exist yet (`autocompleterFn` always calls `this.autocomplete(searchTerm)` today), so the spy is never called and `loadFromUrlSpy` records zero calls.

- [ ] **Step 3: Inject `OpAutocompleterService` and branch `autocompleterFn`**

In `filter-searchable-multiselect-value.component.ts`, add the import and the instance property (mirroring how `OpAutocompleterComponent` itself constructs the service — not through Angular DI, since `OpAutocompleterService` has no `providedIn: 'root'`):

```typescript
import { OpAutocompleterService } from 'core-app/shared/components/autocompleter/op-autocompleter/services/op-autocompleter.service';
```

Add the property (near `resourceType`):

```typescript
  readonly opAutocompleterService = new OpAutocompleterService(this.apiV3Service, this.halResourceService);
```

Replace the `autocompleterFn` property (currently line 62):

```typescript
  autocompleterFn = (searchTerm:string):Observable<HalResource[]> => (
    this.isWorkPackageResource
      ? this.opAutocompleterService.loadFromUrl(this.allowedValuesLink, searchTerm, 'work_packages', [], 'typeahead', true)
      : this.autocomplete(searchTerm)
  );
```

- [ ] **Step 4: Guard `initialRequest$` so the work-package branch never fires the old heavy load**

Replace `ngOnInit` again (this is the version that supersedes Task 1's):

```typescript
  ngOnInit():void {
    this.resourceType = this.isWorkPackageResource ? 'work_packages' : null;

    if (!this.isWorkPackageResource) {
      this.initialRequest$ = this
        .loadCollection('')
        .pipe(
          shareReplay(1),
        );
    }
  }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd frontend && CHROME_BIN=/usr/bin/google-chrome npx ng test --watch=false --include='**/filter-searchable-multiselect-value.component.spec.ts'`
Expected: PASS — all five cases (three from Task 1, two new).

- [ ] **Step 6: Lint**

Run: `cd frontend && npx eslint src/app/features/work-packages/components/filters/filter-searchable-multiselect-value/`
Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add frontend/src/app/features/work-packages/components/filters/filter-searchable-multiselect-value/
git commit -m "Route work-package-backed filter autocomplete through OpAutocompleterService

Epic/Parent/Blocks/etc. previously fetched candidates through this
component's own loadCollection(), hitting the full work-packages table
representer for what's just an id+label lookup. They now delegate to
OpAutocompleterService.loadFromUrl -- the same call the time-logging
picker already uses -- which applies a minimal select= and lets real
server-side search replace the old load-everything-then-filter-client-side
approach. allowEmpty=true preserves today's browse-on-focus UX. Version/
User-backed filters are unchanged."
```

---

### Task 3: Remove the stray `pageSize=-1` from the Epic filter's picker href

**Files:**
- Modify: `lib/api/v3/queries/schemas/epic_filter_dependency_representer.rb`
- Modify: `spec/lib/api/v3/queries/schemas/epic_filter_dependency_representer_spec.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces: `href_callback`'s output no longer contains a `pageSize` param — Task 2's frontend change depends on this landing in the same release (see Global Constraints and the spec's §2a).

- [ ] **Step 1: Write the failing test**

Add to the `describe "#href_callback"` block in `spec/lib/api/v3/queries/schemas/epic_filter_dependency_representer_spec.rb`, alongside the existing examples:

```ruby
    it "does not constrain pageSize, letting the caller's own paging apply" do
      expect(href).not_to include("pageSize")
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/lib/api/v3/queries/schemas/epic_filter_dependency_representer_spec.rb`
Expected: FAIL — current `href` ends in `&pageSize=-1`.

- [ ] **Step 3: Remove the param**

In `lib/api/v3/queries/schemas/epic_filter_dependency_representer.rb`, change `href_callback` (currently lines 46-51):

```ruby
          def href_callback
            params = [{ type: { operator: "=", values: epic_type_ids } }]
            escaped = CGI.escape(::JSON.dump(params))

            "#{api_v3_paths.work_packages}?filters=#{escaped}"
          end
```

(Only the trailing `&pageSize=-1` is removed; the `filters=` construction is unchanged.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/lib/api/v3/queries/schemas/epic_filter_dependency_representer_spec.rb`
Expected: PASS — all examples, including the new one and the three pre-existing ones.

- [ ] **Step 5: Rubocop**

Run: `bundle exec rubocop lib/api/v3/queries/schemas/epic_filter_dependency_representer.rb`
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add lib/api/v3/queries/schemas/epic_filter_dependency_representer.rb spec/lib/api/v3/queries/schemas/epic_filter_dependency_representer_spec.rb
git commit -m "Remove the stray pageSize=-1 from the epic filter's picker href

Harmless under the old frontend flow (always overwritten by the
component's own pageSize param) but would resolve to
Setting.apiv3_max_page_size (1000 rows) once the frontend switches to
OpAutocompleterService, which never sets pageSize itself. Removing it
lets the endpoint's normal default (Setting.per_page_options_array.first)
apply, matching every sibling filter in this family."
```

---

### Task 4: Add trigram indexes for the typeahead search

**Files:**
- Create: `db/migrate/20260823120000_add_trigram_indexes_for_typeahead_search.rb`
- Create: `spec/db/indexes_spec.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces: `index_work_packages_on_subject_trigram`, `index_projects_on_name_trigram` — Task 5's EXPLAIN gate checks whether the planner actually uses them.

- [ ] **Step 1: Write the failing test**

Create `spec/db/indexes_spec.rb`:

```ruby
# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Typeahead search indexes" do
  it "has a trigram index on work_packages.subject for the typeahead filter's ILIKE search" do
    expect(
      ActiveRecord::Base.connection.index_exists?(:work_packages, :subject,
                                                    name: "index_work_packages_on_subject_trigram")
    ).to be true
  end

  it "has a trigram index on projects.name for the typeahead filter's ILIKE search" do
    expect(
      ActiveRecord::Base.connection.index_exists?(:projects, :name,
                                                    name: "index_projects_on_name_trigram")
    ).to be true
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/db/indexes_spec.rb`
Expected: FAIL — neither index exists yet.

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260823120000_add_trigram_indexes_for_typeahead_search.rb`:

```ruby
# frozen_string_literal: true

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

- [ ] **Step 4: Run the migration**

Run: `bundle exec rails db:migrate` (or `bin/compose exec backend bundle exec rails db:migrate` under Docker)
Expected: both indexes created; Rails' schema dumper updates `db/structure.sql` locally
as a side effect. Do not add or commit that file — `db/*.sql` is gitignored in this repo
(`.gitignore:122`), so this project doesn't track schema state in git at all; the
migration file itself is the only source of truth that travels with the commit.

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec spec/db/indexes_spec.rb`
Expected: PASS.

Also run the test-DB migration so CI's schema matches:

Run: `RAILS_ENV=test bundle exec rails db:migrate`

- [ ] **Step 6: Rubocop**

Run: `bundle exec rubocop db/migrate/20260823120000_add_trigram_indexes_for_typeahead_search.rb`
Expected: no offenses.

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260823120000_add_trigram_indexes_for_typeahead_search.rb spec/db/indexes_spec.rb
git commit -m "Add trigram indexes on work_packages.subject and projects.name

Neither column had an index; both back the typeahead filter's
'ILIKE %term%' search, which becomes load-bearing once filter-value
pickers route real search terms to the server (see the linked design
doc). types.name/statuses.name are deliberately left unindexed -- small,
admin-curated lookup tables where a sequential scan is always cheap.

Whether the planner can actually use these indexes for TypeaheadFilter's
cross-table OR is verified separately (Task 5, EXPLAIN ANALYZE gate),
not assumed here."
```

---

### Task 5 (manual): Verify the indexes actually help, for both a text and a numeric search term

This is a verification gate, not an automated test — `TypeaheadFilter`'s `WHERE` clause ORs conditions across four joined tables (`subject`, `projects.name`, `types.name`, `statuses.name`, plus an `id::varchar LIKE` check for numeric terms), and whether Postgres's planner can use per-table indexes for that shape at all is a real open question the previous tasks don't settle. Do not consider this feature done until this task's checks pass or its fallback is chosen.

**This has to exercise the real query pipeline, not a hand-built scope or a captured HTTP
request.** The actual picker request runs through
`WorkPackageCollectionFromQueryService#results_to_representer`
(`app/services/api/v3/work_package_collection_from_query_service.rb:60`):
`query.results.work_packages` — which is `Query::Results#work_packages`
(`app/models/query/results.rb:43-57`), applying visibility (`.visible`) and the real
filter joins on top of `TypeaheadFilter`'s `where`. A hand-built
`WorkPackage.joins(filter.joins + [:project]).where(filter.where)` scope skips visibility
entirely, so a gate built on it could pass while the real, authorized request stays slow.

The most direct way to reach that exact code path without also fighting HTTP-layer
concerns (query-param encoding, reconstructing parameterized SQL with its bind values
outside of ActiveRecord) is to build a real `Query` the same way the controller does —
via `API::V3::UpdateQueryFromV3ParamsService`, the service that turns request params into
query filters — and call `.explain(:analyze)` directly on the resulting relation.
`ActiveRecord::Relation#explain` handles bind parameters internally, so there's no SQL
string to reconstruct or binds to lose.

- [ ] **Step 1: Seed a realistic-scale dataset with real visibility, and EXPLAIN ANALYZE the real query pipeline**

Create a temporary file `spec/requests/api/v3/work_packages/tmp_epic_typeahead_perf_spec.rb`
(delete it after this task — it's a one-off diagnostic, not part of the permanent suite):

```ruby
# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Epic filter typeahead performance (diagnostic, delete after use)" do
  let(:project) { create(:project, identifier: "perf-test-project", public: false) }
  let(:role) { create(:project_role, permissions: %i[view_work_packages]) }

  current_user { create(:user, member_with_roles: { project => role }) }

  let(:epic_type) { create(:type, name: "Epic") }
  let(:task_type) { create(:type, name: "Task") }
  let(:status) { create(:status) }

  before do
    epic_type
    task_type

    puts "Seeding 5,000 synthetic projects..."
    (1..5_000).each_slice(1_000) do |slice|
      Project.insert_all(
        slice.map { |i| { name: "Synthetic Project #{i}", identifier: "perf-project-#{i}", workspace_type: "project" } }
      )
    end
    synthetic_project_ids = Project.where("identifier LIKE 'perf-project-%'").pluck(:id)

    # Project.insert_all bypasses every AR callback, so these projects have zero
    # EnabledModule rows. Projects::Scopes::AllowedTo#allowed_to_enabled_module_join
    # INNER JOINs enabled_modules on the permission's project_module (view_work_packages
    # is registered under "work_package_tracking", config/initializers/permissions.rb) --
    # without this, that join matches nothing and WorkPackage.visible excludes every
    # synthetic project regardless of membership, silently testing an empty query.
    puts "Enabling work_package_tracking on all synthetic projects..."
    EnabledModule.insert_all(
      synthetic_project_ids.map { |pid| { project_id: pid, name: "work_package_tracking" } }
    )

    # WorkPackage.visible checks project membership+permission per user -- the synthetic
    # projects above are separate from `project` (which current_user already has a role
    # on via member_with_roles), so without this, .visible would exclude every synthetic
    # work package and the EXPLAIN below would silently run against ~0 matching rows.
    puts "Granting #{current_user.login} view_work_packages on all synthetic projects..."
    Member.insert_all(
      synthetic_project_ids.map { |pid| { user_id: current_user.id, project_id: pid } }
    )
    member_ids = Member.where(user_id: current_user.id, project_id: synthetic_project_ids).pluck(:id)
    MemberRole.insert_all(
      member_ids.map { |mid| { member_id: mid, role_id: role.id } }
    )

    puts "Seeding 100,000 synthetic work packages (2% Epic-typed, matching a realistic ratio)..."
    (1..100_000).each_slice(2_000) do |slice|
      WorkPackage.insert_all(
        slice.map do |i|
          {
            subject: "Synthetic work package #{i} #{SecureRandom.hex(4)}",
            project_id: synthetic_project_ids.sample,
            type_id: (i % 50).zero? ? epic_type.id : task_type.id,
            status_id: status.id,
            author_id: current_user.id
          }
        end
      )
    end
  end

  # Builds a real Query the same way the controller does for a picker request (type filter
  # scoped to Epic + a typeahead search term), then explains the exact relation
  # Query::Results#work_packages produces -- same visibility, same filters, same pagination.
  def explain_for_search_term(term)
    User.execute_as(current_user) do
      query = Query.new_default(project: nil, user: current_user)
      filters_json = [
        { type: { operator: "=", values: [epic_type.id.to_s] } },
        { typeahead: { operator: "**", values: [term] } }
      ].to_json

      # Braced deliberately: #call(params, valid_subset: false) takes params
      # positionally. `.call(filters: filters_json)` would parse as all-keyword
      # arguments under Ruby 3's keyword/positional separation, matching nothing
      # (there's no `filters:` keyword param) and raising ArgumentError.
      update = API::V3::UpdateQueryFromV3ParamsService
                 .new(query, current_user)
                 .call({ filters: filters_json })
      raise "invalid query: #{query.errors.full_messages.join(', ')}" unless update.success?

      relation = query.results.work_packages.limit(Setting.per_page_options_array.first)

      puts "\n=== EXPLAIN ANALYZE for term #{term.inspect} ==="
      puts relation.explain(:analyze)
    end
  end

  it "has a substantial pool of visible epics before any search term narrows it" do
    # Sanity check for the membership grant above, run once: if this is small (or zero),
    # something is wrong with visibility setup, and the two EXPLAIN examples below would
    # be testing an empty table rather than a 100k-row one.
    visible_epic_count = User.execute_as(current_user) { WorkPackage.visible.where(type_id: epic_type.id).count }
    expect(visible_epic_count).to be > 1_000
  end

  it "explains the real query pipeline for a multi-word term" do
    explain_for_search_term("synthetic 4200")
  end

  it "explains the real query pipeline for a numeric term" do
    explain_for_search_term("4200")
  end
end
```

Run it once:

```bash
bundle exec rspec spec/requests/api/v3/work_packages/tmp_epic_typeahead_perf_spec.rb
```

(`bin/compose rspec spec/requests/api/v3/work_packages/tmp_epic_typeahead_perf_spec.rb` under Docker.) RSpec's standard per-example transactional rollback discards all seeded rows and memberships automatically — nothing to clean up manually. **Delete the temporary spec file once you've captured its output**; it isn't meant to become a permanent part of the suite. If the first example (the visible-epic-count sanity check) fails, stop and fix the membership setup before reading anything into the other two examples' EXPLAIN output — a failing sanity check means the plans below are describing a near-empty query, not the 100k-row one this task needs.

- [ ] **Step 2: Judge the two plans against pass/fail criteria**

**Multi-word term (`"synthetic 4200"`) passes if:** the plan shows bitmap or index scans feeding into the join (look for `Bitmap Index Scan on index_work_packages_on_subject_trigram` and/or `index_projects_on_name_trigram` in the output) rather than `Seq Scan on work_packages` touching a large fraction of the 100,000 synthetic rows.

**Numeric term (`"4200"`) passes if:** the plan does *not* show a full `Seq Scan on work_packages` for this term either — but per the design doc, neither index targets `id::varchar(20) LIKE '%4200%'`, so expect this one to fail unless a fix from Step 3 is applied first.

- [ ] **Step 3: Apply the named fallback for whichever term failed, then re-run Steps 1-2 to confirm**

**If the multi-word case failed:** narrowing `typeahead`'s search contract (dropping project/type/status name matching for filter-value pickers) is the documented fallback — this changes product behavior and needs the user's sign-off before implementing; report the EXPLAIN output and stop here rather than change `TypeaheadFilter` unilaterally.

**If the numeric case failed** (the expected starting outcome): report the EXPLAIN output to the user and let them choose between the two documented fixes before implementing either:
  - A functional trigram index: `add_index :work_packages, "(id::varchar(20))", using: :gin, opclass: :gin_trgm_ops, algorithm: :concurrently, name: "index_work_packages_on_id_text_trigram"` (preserves today's substring-on-id behavior).
  - Changing `id_condition` in `app/models/queries/work_packages/filter/typeahead_filter.rb:88-90` from `"#{WorkPackage.table_name}.id::varchar(20) LIKE '%#{string}%'"` to an exact match against the existing primary-key index (`"#{WorkPackage.table_name}.id = #{string.to_i}"`) — needs no new index, but changes what a numeric search term matches everywhere `TypeaheadFilter` is used (not just these pickers), so this is the more product-visible of the two options.

This task ends in a report to the user (EXPLAIN output for both terms, pass/fail per the criteria above, and a recommendation if either fell into the fallback branch) — not a commit.

---

### Task 6 (manual): Browser verification

- [ ] **Step 1: Confirm the picker loads and searches correctly**

In a running instance (`bin/dev`, or `bin/compose start` under Docker) with more than 100 visible epic-typed work packages across projects (seed some if the dev instance doesn't have enough — this only matters for exercising the server-side-search code path; below 100 the whole candidate set fits one page and the picker still works, just doesn't demonstrate the search path):

1. Open a Gantt/work-packages view, open the filter bar, add the "Epic" filter.
2. Click into its value field. Confirm a visible list of epics appears immediately (not empty) — this is the `allowEmpty: true` behavior from Task 2.
3. Type a few characters of an epic's subject. Confirm the list narrows.
4. Open the browser's Network tab, repeat step 3, and find the `GET .../work_packages?...` request: confirm its query string includes `select=elements/id,elements/subject,elements/author,elements/type,elements/project,elements/status` and that the response payload is noticeably smaller than a full work-package representation (no `_links.schema`, no custom fields, no `attachmentsByType` etc.).

- [ ] **Step 2: Confirm saved filter values still render**

1. Save a query with the Epic filter set to one or more values (or open an existing one if available).
2. Reload the page / reopen the query. Confirm the previously-selected epics still show as chips in the filter's value field, and that each chip's × control still removes it.
3. Repeat steps 1-2 for one other filter in the same family (e.g. Parent, or Blocks) to confirm the change generalizes beyond Epic.

- [ ] **Step 3: Confirm Version/User-backed filters are unaffected**

1. Add a Version filter (or another non-work-package filter) to the same view.
2. Confirm its value picker still opens, loads, and searches exactly as before — this exercises the untouched `autocomplete()`/`loadCollection()` branch.

This task ends in a report to the user, not a commit. If any check fails, return to the relevant task above rather than patching ad hoc.
