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

import { UIRouterGlobals } from '@uirouter/core';
import {
  Component,
  inject,
  Input,
  OnInit,
} from '@angular/core';
import { I18nService } from 'core-app/core/i18n/i18n.service';
import { ApiV3Service } from 'core-app/core/apiv3/api-v3.service';
import { Observable } from 'rxjs';
import { filter, map } from 'rxjs/operators';
import { WpTabDefinition } from 'core-app/features/work-packages/components/wp-tabs/components/wp-tab-wrapper/tab';
import { WorkPackageTabsService } from 'core-app/features/work-packages/components/wp-tabs/services/wp-tabs/wp-tabs.service';
import { WorkPackageResource } from 'core-app/features/hal/resources/work-package-resource';
import { isPartialWorkPackage } from 'core-app/features/hal/helpers/partial-work-package';
import { States } from 'core-app/core/states/states.service';

@Component({
  templateUrl: './wp-tab-wrapper.html',
  selector: 'op-wp-tab',
  standalone: false,
})
export class WpTabWrapperComponent implements OnInit {
  @Input() public workPackageId:string;
  @Input() public tabIdentifier:string;

  workPackage:WorkPackageResource;

  ndcDynamicInputs$:Observable<{
    workPackage:WorkPackageResource;
    tab:WpTabDefinition | undefined;
  }>;

  private readonly states = inject(States);

  constructor(
    readonly I18n:I18nService,
    readonly uiRouterGlobals:UIRouterGlobals,
    readonly apiV3Service:ApiV3Service,
    readonly wpTabsService:WorkPackageTabsService,
  ) {}

  ngOnInit() {
    if (this.workPackageId === undefined) {
      this.workPackageId = this.uiRouterGlobals.params.workPackageId;
    }

    // If only a partial work package is cached (a board's lightweight `select`
    // payload), force a full reload, and never surface a partial here. The tab body
    // (e.g. wp-single-view) builds its view once from the work package it is created
    // with and does not re-initialize on input changes — so on a board deep-link
    // reload it would otherwise stay stuck on the stripped, schema-less subset until
    // the tab is re-created. Filtering guarantees the body is only ever built from the
    // complete resource.
    const cached = this.states.workPackages.get(this.workPackageId).getValueOr(undefined);

    this.ndcDynamicInputs$ = this
      .apiV3Service
      .work_packages
      .id(this.workPackageId)
      .requireAndStream(isPartialWorkPackage(cached))
      .pipe(
        filter((wp) => !isPartialWorkPackage(wp)),
        map((wp) => ({
          workPackage: wp,
          tab: this.findTab(wp),
        })),
      );
  }

  findTab(workPackage:WorkPackageResource):WpTabDefinition | undefined {
    if (this.tabIdentifier === undefined) {
      this.tabIdentifier = this.uiRouterGlobals.params.tabIdentifier;
    }

    return this.wpTabsService.getTab(this.tabIdentifier, workPackage);
  }
}
