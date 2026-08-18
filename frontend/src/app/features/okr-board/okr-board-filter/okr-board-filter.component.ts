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

export type OkrBoardScope = 'self'|'ancestors'|'children';

export const VERSION_FILTER_NAME = 'version';

@Component({
  selector: 'okr-board-filter',
  templateUrl: './okr-board-filter.component.html',
  standalone: false,
})
export class OkrBoardFilterComponent implements OnInit {
  topLevelUnits:HalResource[] = [];

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

  constructor(
    readonly wpTableFilters:WorkPackageViewFiltersService,
    readonly apiV3Service:ApiV3Service,
    readonly I18n:I18nService,
    readonly cdRef:ChangeDetectorRef,
  ) {
  }

  ngOnInit():void {
    this.departmentFilterName = this.readDepartmentFilterName();

    // The department and version filter schemas are only available once the
    // surrounding work package view has loaded its query and populated
    // WorkPackageViewFiltersService's available-filters state. Calling
    // #instantiate() before that resolves throws (see #onReady() usage
    // elsewhere, e.g. filters-tab-inner.component.ts), so wait for it first
    // rather than racing the view's own query bootstrap.
    void this.wpTableFilters.onReady().then(() => {
      this.loadOrganizationalUnits();
      void this.loadVersions();
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

  scopeValues(unitId:string, scope:OkrBoardScope):string[] {
    if (scope === 'children') {
      return [unitId, ...this.childrenOf(unitId)];
    }

    // 'self' and 'ancestors' are identical for a top-level-only picker —
    // there is nothing above a top-level unit to add.
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
    const filter = this.wpTableFilters.instantiate(this.departmentSchemaName());
    const allowedValues = filter.currentSchema?.values?.allowedValues as { href:string } | undefined;

    // No qualifying department custom field is configured for this project (or its filter
    // schema could not be resolved) - nothing to load.
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
        this.topLevelUnits = this.allUnits.filter((unit) => !unit.parent);
        this.childrenIndex = this.buildChildrenIndex(this.allUnits);
        this.syncSelectionFromLiveFilter();
        // The HTTP response for this HAL collection resolves outside of Angular's zone
        // (see ApiV3Service's HAL layer), so the assignments above never trigger a
        // change detection pass on their own -- mirror
        // WorkPackageFilterContainerComponent#ngOnInit()'s own explicit detectChanges().
        this.cdRef.detectChanges();
      },
      // Keep the current (empty) state on failure, but surface the error rather
      // than swallowing it silently.
      error: (error:unknown) => {
        console.error('Failed to load OKR board organizational units', error);
        this.cdRef.detectChanges();
      },
    });
  }

  async loadVersions():Promise<void> {
    const filter = this.wpTableFilters.instantiate(VERSION_FILTER_NAME);
    const allowedValues = filter.currentSchema?.values?.allowedValues as { href:string } | undefined;

    // No version filter available (e.g. its schema could not be resolved) - nothing to load.
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
      this.syncVersionSelectionFromLiveFilter();
    } catch (error:unknown) {
      // Keep the current (empty) state on failure, but surface the error rather
      // than swallowing it silently.
      console.error('Failed to load OKR board versions', error);
    } finally {
      // See the comment in #loadOrganizationalUnits() -- the HTTP response resolves
      // outside Angular's zone, so this needs an explicit change detection pass.
      this.cdRef.detectChanges();
    }
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
    // value as the linked HalResource, not a plain id -- see #applyUnitFilter().
    const rawValue = filter?.values?.[0];
    const currentValue = typeof rawValue === 'string' ? rawValue : rawValue?.id as string | undefined;

    if (!currentValue) {
      this.selectedUnitId = null;
      return;
    }

    const stillExists = this.allUnitIds().has(currentValue);
    if (stillExists) {
      this.selectedUnitId = currentValue;
      return;
    }

    // The filter references a unit that no longer exists in the loaded set
    // (e.g. its Group was deleted). Clear the live filter itself, not just
    // the displayed selection -- board-filter.component.ts's own
    // selectedQuickFilter only resets the display, leaving the table
    // filtered by a dead id. We deliberately don't repeat that here.
    this.selectedUnitId = null;
    this.wpTableFilters.remove(this.departmentSchemaName());
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
    this.selectedVersionId = stillExists ? currentValue : null;
  }

  private allUnitIds():Set<string> {
    return new Set(this.allUnits.map((unit) => unit.id as string));
  }

  private buildChildrenIndex(units:HalResource[]):Map<string, string[]> {
    const index = new Map<string, string[]>();

    units.forEach((unit) => {
      const parentId = (unit.parent as HalResource | null)?.id as string | undefined;
      if (!parentId) {
        return;
      }

      const siblings = index.get(parentId) || [];
      siblings.push(unit.id as string);
      index.set(parentId, siblings);
    });

    return index;
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
