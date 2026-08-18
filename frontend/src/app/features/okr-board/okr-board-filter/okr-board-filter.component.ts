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

import { Component, OnInit } from '@angular/core';
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
  ) {
  }

  ngOnInit():void {
    this.departmentFilterName = this.readDepartmentFilterName();
    this.loadOrganizationalUnits();
    void this.loadVersions();
  }

  readDepartmentFilterName():string {
    const bootstrapEl = document.getElementById('okr-board-bootstrap');
    return bootstrapEl?.dataset.departmentFilter || '';
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
      this.wpTableFilters.remove(this.departmentFilterName);
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
    const filter = this.wpTableFilters.instantiate(this.departmentFilterName);
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
      },
      // Keep the current (empty) state on failure, but surface the error rather
      // than swallowing it silently.
      error: (error:unknown) => {
        console.error('Failed to load OKR board organizational units', error);
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

    this.versions = await firstValueFrom(
      getPaginatedResults<HalResource>(
        (params) => (this.apiV3Service.collectionFromString(allowedValues.href) as
          ApiV3ResourceCollection<HalResource, ApiV3Resource>)
          .filtered(new ApiV3FilterBuilder(), { pageSize: `${params.pageSize}`, offset: `${params.offset}` })
          .get(),
      ),
    );
  }

  onVersionChange(versionId:string|null):void {
    this.selectedVersionId = versionId;

    if (!versionId) {
      this.wpTableFilters.remove(VERSION_FILTER_NAME);
      return;
    }

    this.wpTableFilters.replace(VERSION_FILTER_NAME, (filter) => {
      // QueryFilterInstanceResource#operator is a QueryOperatorResource, not a plain
      // string — mirror the pattern used by quick-filter-by-text-input.component.ts.
      filter.operator = filter.findOperator('=')!;
      filter.values = [versionId];
    });
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
    const values = this.scopeValues(unitId, scope);

    this.wpTableFilters.replace(this.departmentFilterName, (filter) => {
      // QueryFilterInstanceResource#operator is a QueryOperatorResource, not a plain
      // string — mirror the pattern used by quick-filter-by-text-input.component.ts.
      filter.operator = filter.findOperator('=')!;
      filter.values = values;
    });
  }
}
