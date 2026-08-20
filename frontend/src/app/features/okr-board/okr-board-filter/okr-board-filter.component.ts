//-- copyright
// OpenProject is an open source project management software.
// Copyright (C) the OpenProject GmbH
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License version 3.
//
// OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
// Copyright (C) 2006-2013 Jean-Philippe Lang
// Copyright (C) 2010-2013 the ChiliProject Team
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 2
// of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
//
// See COPYRIGHT and LICENSE files for more details.
//++

import { ChangeDetectorRef, Component, OnInit } from '@angular/core';
import {
  WorkPackageViewFiltersService,
} from 'core-app/features/work-packages/routing/wp-view-base/view-services/wp-view-filters.service';
import { ApiV3Service } from 'core-app/core/apiv3/api-v3.service';
import { ApiV3ResourceCollection } from 'core-app/core/apiv3/paths/apiv3-resource';
import { ApiV3Resource } from 'core-app/core/apiv3/cache/cachable-apiv3-resource';
import { HalResource } from 'core-app/features/hal/resources/hal-resource';
import { ApiV3FilterBuilder } from 'core-app/shared/helpers/api-v3/api-v3-filter-builder';
import { getPaginatedResults } from 'core-app/core/apiv3/helpers/get-paginated-results';
import { I18nService } from 'core-app/core/i18n/i18n.service';
import { firstValueFrom } from 'rxjs';
import { UntilDestroyedMixin } from 'core-app/shared/helpers/angular/until-destroyed.mixin';

export type OkrBoardScope = 'self'|'ancestors'|'children';

export const VERSION_FILTER_NAME = 'version';

@Component({
  selector: 'okr-board-filter',
  templateUrl: './okr-board-filter.component.html',
  standalone: false,
})
export class OkrBoardFilterComponent extends UntilDestroyedMixin implements OnInit {
  /**
   * Every organizational unit at every depth, in the backend's tree order
   * (`Group.organizational_units.in_tree_order` -- parents always precede their
   * children), each carrying a display `label` indented per its depth so the flat
   * `<select>` still conveys the hierarchy.
   */
  unitOptions:{ id:string, label:string }[] = [];

  /** cf_<id> of the project's one qualifying department-format custom field. */
  departmentFilterName = '';

  selectedUnitId:string|null = null;

  selectedScope:OkrBoardScope = 'self';

  versions:HalResource[] = [];

  selectedVersionId:string|null = null;

  text = {
    unit_all: this.I18n.t('js.okr_board.quick_filters.unit_all'),
    scope_self: this.I18n.t('js.okr_board.quick_filters.scope_self'),
    scope_ancestors: this.I18n.t('js.okr_board.quick_filters.scope_ancestors'),
    scope_children: this.I18n.t('js.okr_board.quick_filters.scope_children'),
    version_all: this.I18n.t('js.okr_board.quick_filters.version_all'),
  };

  private allUnits:HalResource[] = [];

  private childrenIndex:Map<string, string[]> = new Map();

  private parentIndex:Map<string, string> = new Map();

  // Guards the wpTableFilters.updates$() resync (see #ngOnInit()) against running before
  // the corresponding initial load has settled -- #syncSelectionFromLiveFilter() and
  // #syncVersionSelectionFromLiveFilter() both treat an empty #allUnits/#versions as "no
  // options loaded yet" and would otherwise misread any live filter value as stale and
  // remove it.
  private unitsLoaded = false;

  private versionsLoaded = false;

  constructor(
    readonly wpTableFilters:WorkPackageViewFiltersService,
    readonly apiV3Service:ApiV3Service,
    readonly I18n:I18nService,
    readonly cdRef:ChangeDetectorRef,
  ) {
    super();
  }

  ngOnInit():void {
    this.departmentFilterName = this.readDepartmentFilterName();

    // The department and version filter schemas are only available once the
    // surrounding work package view has loaded its query and populated
    // WorkPackageViewFiltersService's available-filters state. Calling
    // #instantiate() before that resolves throws (see #onReady() usage
    // elsewhere, e.g. filters-tab-inner.component.ts), so wait for it first
    // rather than racing the view's own query bootstrap.
    //
    // Chained as two independent listeners on the same promise (not sequentially
    // inside one callback) so that one filter failing to load can never prevent
    // the other from loading -- see #isFilterAvailable()'s comment for a concrete
    // case where the department filter is legitimately unavailable.
    const ready = this.wpTableFilters.onReady();
    void ready.then(() => this.loadOrganizationalUnits());
    void ready.then(() => this.loadVersions());

    // The native filter panel (<op-filter-container>) writes into the same
    // WorkPackageViewFiltersService instance. Without this, removing the department or
    // version filter there (or any other external change to them) would leave these
    // quick-filter dropdowns showing a stale selection while the table itself changed
    // underneath them, and the next scope-radio click would silently re-add a filter the
    // user thought they'd removed.
    //
    // updates$() also fires for this component's own #applyUnitFilter()/#onVersionChange()
    // writes; that's intentional and safe -- #syncSelectionFromLiveFilter() and
    // #syncVersionSelectionFromLiveFilter() are idempotent no-ops when the live filter
    // already matches what's displayed (see #inferScope()'s comment for the one subtlety,
    // around preserving "ancestors").
    this.wpTableFilters
      .updates$()
      .pipe(this.untilDestroyed())
      .subscribe(() => {
        if (this.unitsLoaded) {
          this.syncSelectionFromLiveFilter();
        }

        if (this.versionsLoaded) {
          this.syncVersionSelectionFromLiveFilter();
        }

        // See the comment in #loadOrganizationalUnits() -- this runs under the same
        // OnPush ancestor and needs an explicit change-detection call.
        this.cdRef.markForCheck();
      });
  }

  readDepartmentFilterName():string {
    const bootstrapEl = document.getElementById('okr-board-bootstrap');
    return bootstrapEl?.dataset.departmentFilter || '';
  }

  /**
   * Derives the work package custom field *schema*'s id ("customField<id>") from
   * #departmentFilterName's filter-instance id ("cf_<id>"). See the comment in
   * #loadOrganizationalUnits() for why these two different ids both matter here.
   */
  departmentSchemaName():string {
    const match = /^cf_(\d+)$/.exec(this.departmentFilterName);
    return match ? `customField${match[1]}` : this.departmentFilterName;
  }

  childrenOf(unitId:string):string[] {
    return this.childrenIndex.get(unitId) || [];
  }

  ancestorsOf(unitId:string):string[] {
    const ancestors:string[] = [];
    let current = this.parentIndex.get(unitId);

    while (current) {
      ancestors.push(current);
      current = this.parentIndex.get(current);
    }

    return ancestors;
  }

  scopeValues(unitId:string, scope:OkrBoardScope):string[] {
    if (scope === 'children') {
      return [unitId, ...this.childrenOf(unitId)];
    }

    if (scope === 'ancestors') {
      return [unitId, ...this.ancestorsOf(unitId)];
    }

    return [unitId];
  }

  onUnitChange(unitId:string|null):void {
    this.selectedUnitId = unitId;

    if (!unitId) {
      this.wpTableFilters.remove(this.departmentSchemaName());
      return;
    }

    this.applyUnitFilter(unitId, this.selectedScope);
  }

  onScopeChange(scope:OkrBoardScope):void {
    this.selectedScope = scope;

    if (this.selectedUnitId) {
      this.applyUnitFilter(this.selectedUnitId, scope);
    }
  }

  loadOrganizationalUnits():void {
    // WorkPackageViewFiltersService#instantiate()/#replace()/#remove()/#find() all key off
    // a work package custom field's *schema* id, "customField<id>" -- a different naming
    // convention than the backend's own filter accessor, "cf_<id>" (matching
    // Queries::Filters::Shared::CustomFieldFilter's `cf_(\d+)` regex and what the bootstrap
    // element's data-department-filter attribute sends, since that's built from
    // custom_field.column_name). #departmentSchemaName() derives the former from the
    // latter; passing #departmentFilterName directly here would never match any schema
    // and permanently throw at `.getFilter()`.
    const schemaName = this.departmentSchemaName();

    if (!this.isFilterAvailable(schemaName)) {
      // #instantiate() below matches only against the view's currently-available filter
      // schemas; calling it for one that isn't there permanently throws at `.getFilter()`
      // (no schema would ever match, unlike a temporary/racy absence). Degrade to an
      // empty picker instead: OkrBoard::Availability#available? only requires a
      // qualifying department custom field associated with the project, not that its
      // schema is guaranteed to already be present in #availableFilters by the time this
      // runs, so this must never be assumed.
      console.error(
        `OKR board: department filter schema '${schemaName}' is not among the view's ` +
        'available filters; leaving the unit picker empty.',
      );
      // Deliberately NOT setting #unitsLoaded here: it means "we have authoritative
      // data about which units exist", which isn't true in this branch. Leaving it
      // false keeps the updates$() resync (see #ngOnInit()) from later reading a live
      // filter value against an empty #allUnits and wrongly concluding it references a
      // deleted unit -- that would call #remove() on a filter this component simply
      // never had data to judge (e.g. one set via the native filter panel).
      return;
    }

    const filter = this.wpTableFilters.instantiate(schemaName);
    const allowedValues = filter.currentSchema?.values?.allowedValues as { href:string } | undefined;

    // No qualifying department custom field is configured for this project (or its filter
    // schema could not be resolved) - nothing to load. See the comment above: #unitsLoaded
    // stays false so the updates$() resync doesn't misread the live filter as stale.
    if (!allowedValues) {
      return;
    }

    getPaginatedResults<HalResource>(
      (params) => (this.apiV3Service.collectionFromString(allowedValues.href) as
        ApiV3ResourceCollection<HalResource, ApiV3Resource>)
        .filtered(new ApiV3FilterBuilder(), { pageSize: `${params.pageSize}`, offset: `${params.offset}` })
        .get(),
    ).subscribe({
      next: (allUnits) => {
        this.allUnits = allUnits;
        const { childrenIndex, parentIndex } = this.buildHierarchyIndexes(this.allUnits);
        this.childrenIndex = childrenIndex;
        this.parentIndex = parentIndex;
        this.unitOptions = this.buildUnitOptions(this.allUnits);
        this.unitsLoaded = true;
        this.syncSelectionFromLiveFilter();
        // OkrBoardFilterComponent sits inside PartitionedQuerySpacePageComponent, an
        // OnPush-strategy ancestor. HttpClient callbacks DO run inside Angular's zone (so
        // a tick() is scheduled), but OnPush makes that tick() skip this whole subtree
        // unless something has explicitly marked it (or an ancestor) dirty first -- mirror
        // WorkPackageFilterContainerComponent#ngOnInit()'s own explicit change-detection
        // call for the same reason.
        this.cdRef.markForCheck();
      },
      // Keep the current (empty) state on failure, but surface the error rather
      // than swallowing it silently. #unitsLoaded stays false -- see the comments
      // earlier in this method for why a failed load must not enable the
      // updates$() resync against an #allUnits set we know is incomplete.
      error: (error:unknown) => {
        console.error('Failed to load OKR board organizational units', error);
        this.cdRef.markForCheck();
      },
    });
  }

  async loadVersions():Promise<void> {
    if (!this.isFilterAvailable(VERSION_FILTER_NAME)) {
      // See the comment in #loadOrganizationalUnits() -- guard defensively here too so an
      // unavailable version filter degrades to an empty picker instead of throwing.
      console.error(
        `OKR board: version filter schema '${VERSION_FILTER_NAME}' is not among the ` +
        'view\'s available filters; leaving the version picker empty.',
      );
      // Deliberately NOT setting #versionsLoaded here -- see the equivalent comment in
      // #loadOrganizationalUnits(): it means "we have authoritative data", which isn't
      // true in this branch, and setting it would let the updates$() resync wrongly
      // treat a live version filter as stale and remove it.
      return;
    }

    const filter = this.wpTableFilters.instantiate(VERSION_FILTER_NAME);
    const allowedValues = filter.currentSchema?.values?.allowedValues as { href:string } | undefined;

    // No version filter available (e.g. its schema could not be resolved) - nothing to
    // load. #versionsLoaded stays false; see the comment above.
    if (!allowedValues) {
      return;
    }

    try {
      this.versions = await firstValueFrom(
        getPaginatedResults<HalResource>(
          (params) => (this.apiV3Service.collectionFromString(allowedValues.href) as
            ApiV3ResourceCollection<HalResource, ApiV3Resource>)
            .filtered(new ApiV3FilterBuilder(), { pageSize: `${params.pageSize}`, offset: `${params.offset}` })
            .get(),
        ),
      );
      this.versionsLoaded = true;
      this.syncVersionSelectionFromLiveFilter();
    } catch (error:unknown) {
      // Keep the current (empty) state on failure, but surface the error rather
      // than swallowing it silently. #versionsLoaded stays false -- a failed load
      // must not enable the updates$() resync against a #versions set we know is
      // incomplete (see the comments earlier in this method).
      console.error('Failed to load OKR board versions', error);
    } finally {
      // See the comment in #loadOrganizationalUnits() -- this needs an explicit
      // change-detection call because of the OnPush ancestor, not a zone escape.
      this.cdRef.markForCheck();
    }
  }

  /**
   * Whether the given filter schema id is currently among the view's available filters.
   * #instantiate() throws permanently if asked for a schema that isn't -- see the
   * comment in #loadOrganizationalUnits() -- so it must never be called speculatively;
   * OkrBoard::Availability#available? guarantees a qualifying department custom field
   * exists for the project, not that its schema has necessarily reached this list yet.
   */
  private isFilterAvailable(schemaId:string):boolean {
    return this.wpTableFilters.availableFilters.some((filter) => filter.id === schemaId);
  }

  onVersionChange(versionId:string|null):void {
    this.selectedVersionId = versionId;

    if (!versionId) {
      this.wpTableFilters.remove(VERSION_FILTER_NAME);
      return;
    }

    // See the comment in #applyUnitFilter() -- the version filter is resource-typed too,
    // so this needs the actual linked Version resource, not its plain id.
    const version = this.versions.find((v) => v.id === versionId);
    if (!version) {
      return;
    }

    this.wpTableFilters.replace(VERSION_FILTER_NAME, (filter) => {
      // QueryFilterInstanceResource#operator is a QueryOperatorResource, not a plain
      // string — mirror the pattern used by quick-filter-by-text-input.component.ts.
      filter.operator = filter.findOperator('=')!;
      filter.values = [version];
    });
  }

  syncSelectionFromLiveFilter():void {
    const filter = this.wpTableFilters.find(this.departmentSchemaName());
    // A live filter restored from query_props (e.g. after a bookmark reload) carries its
    // values as the linked HalResources, not plain ids -- see #applyUnitFilter().
    const values = this.resolveFilterValueIds(filter?.values);

    if (values.length === 0) {
      this.selectedUnitId = null;
      return;
    }

    // scopeValues() always puts the anchor unit id first, whatever the scope (see its
    // implementation), so the first value is always the unit to match against.
    const matchedUnitId = values[0];
    const stillExists = this.allUnitIds().has(matchedUnitId);
    if (!stillExists) {
      // The filter references a unit that no longer exists in the loaded set
      // (e.g. its Group was deleted). Clear the live filter itself, not just
      // the displayed selection -- board-filter.component.ts's own
      // selectedQuickFilter only resets the display, leaving the table
      // filtered by a dead id. We deliberately don't repeat that here.
      this.selectedUnitId = null;
      this.wpTableFilters.remove(this.departmentSchemaName());
      return;
    }

    this.selectedUnitId = matchedUnitId;
    this.selectedScope = this.inferScope(matchedUnitId, values);
  }

  /**
   * Infers #selectedScope from the live filter's full value list.
   *
   * For a top-level unit, "self" and "ancestors" still produce the identical
   * single-value filter ([unitId]) -- there is nothing above a top-level unit to add
   * (see #ancestorsOf()) -- so they can never be told apart from the values alone in
   * that case; restoring from a bookmark then displays such a selection as "self".
   * That's accepted, unavoidable behavior for a top-level unit specifically, not a
   * general limitation: for any unit with actual ancestors, the explicit "ancestors"
   * check below tells it apart from "self" correctly.
   *
   * Preserves the currently-selected scope when it already explains the observed values.
   * This matters because this method also runs on every wpTableFilters.updates$() emission
   * (see ngOnInit()), including the ones this component's own #applyUnitFilter() call
   * triggers -- e.g. selecting "ancestors" for a top-level unit (whose values are
   * identical to "self"'s) would otherwise be immediately clobbered back to "self" by the
   * resync its own filter write causes.
   */
  private inferScope(unitId:string, values:string[]):OkrBoardScope {
    const valueSet = new Set(values);

    if (this.setsEqual(valueSet, new Set(this.scopeValues(unitId, this.selectedScope)))) {
      return this.selectedScope;
    }

    if (values.length > 1 && this.setsEqual(valueSet, new Set(this.scopeValues(unitId, 'children')))) {
      return 'children';
    }

    if (values.length > 1 && this.setsEqual(valueSet, new Set(this.scopeValues(unitId, 'ancestors')))) {
      return 'ancestors';
    }

    return 'self';
  }

  private setsEqual(a:Set<string>, b:Set<string>):boolean {
    return a.size === b.size && [...a].every((value) => b.has(value));
  }

  private resolveFilterValueIds(values:HalResource[]|string[]|undefined):string[] {
    return (values ?? [])
      .map((value) => (typeof value === 'string' ? value : value?.id))
      .filter((id):id is string => !!id);
  }

  /**
   * Mirrors #syncSelectionFromLiveFilter() for the version quick filter, so a version
   * selected before a bookmark reload is reflected back in the dropdown afterwards.
   */
  syncVersionSelectionFromLiveFilter():void {
    const filter = this.wpTableFilters.find(VERSION_FILTER_NAME);
    const rawValue = filter?.values?.[0];
    const currentValue = typeof rawValue === 'string' ? rawValue : rawValue?.id as string | undefined;

    if (!currentValue) {
      this.selectedVersionId = null;
      return;
    }

    const stillExists = this.versions.some((version) => version.id === currentValue);
    if (stillExists) {
      this.selectedVersionId = currentValue;
      return;
    }

    // Mirror the department-side stale-unit branch in #syncSelectionFromLiveFilter() --
    // clear the live filter itself, not just the displayed selection, so the table isn't
    // left filtered by a dead version id while the dropdown shows "All versions".
    this.selectedVersionId = null;
    this.wpTableFilters.remove(VERSION_FILTER_NAME);
  }

  private allUnitIds():Set<string> {
    return new Set(this.allUnits.map((unit) => unit.id as string));
  }

  private buildHierarchyIndexes(units:HalResource[]):{ childrenIndex:Map<string, string[]>, parentIndex:Map<string, string> } {
    const childrenIndex = new Map<string, string[]>();
    const parentIndex = new Map<string, string>();

    units.forEach((unit) => {
      const parentId = (unit.parent as HalResource | null)?.id as string | undefined;
      if (!parentId) {
        return;
      }

      parentIndex.set(unit.id as string, parentId);

      const siblings = childrenIndex.get(parentId) || [];
      siblings.push(unit.id as string);
      childrenIndex.set(parentId, siblings);
    });

    return { childrenIndex, parentIndex };
  }

  /**
   * Builds the flat dropdown option list, indenting each unit's display label by its
   * depth (number of ancestor hops via #parentIndex) so the hierarchy stays legible in a
   * plain `<select>`. Relies on #parentIndex already being populated (see the caller in
   * #loadOrganizationalUnits()) and on the backend returning units in tree order
   * (`Group.organizational_units.in_tree_order`, `CustomField#possible_department_values`)
   * so parents always precede their children here.
   */
  private buildUnitOptions(units:HalResource[]):{ id:string, label:string }[] {
    return units.map((unit) => {
      const depth = this.ancestorsOf(unit.id as string).length;
      return {
        id: unit.id as string,
        label: `${'— '.repeat(depth)}${unit.name as string}`,
      };
    });
  }

  private applyUnitFilter(unitId:string, scope:OkrBoardScope):void {
    const ids = this.scopeValues(unitId, scope);
    // A department/organizational-unit filter is resource-typed (its schema defines
    // allowedValues), so QueryFilterInstanceResource#values must be the actual linked
    // HalResources, not their plain ids: the HAL layer's setter (hal-resource-builder.ts)
    // rebuilds _links.values from each element's #href, so a plain id string there
    // silently becomes {href: undefined} once the filter is cloned for the URL/query_props
    // (see WorkPackageViewFiltersService#applyToQuery -> #cloneFilters()) -- it reads back
    // fine in-memory before that clone, which is what makes this easy to miss.
    const values = this.resolveUnitResources(ids);

    this.wpTableFilters.replace(this.departmentSchemaName(), (filter) => {
      // QueryFilterInstanceResource#operator is a QueryOperatorResource, not a plain
      // string — mirror the pattern used by quick-filter-by-text-input.component.ts.
      filter.operator = filter.findOperator('=')!;
      filter.values = values;
    });
  }

  private resolveUnitResources(ids:string[]):HalResource[] {
    const byId = new Map(this.allUnits.map((unit) => [unit.id!, unit]));
    return ids.map((id) => byId.get(id)).filter((unit):unit is HalResource => !!unit);
  }
}
