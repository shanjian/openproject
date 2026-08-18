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

import { ChangeDetectionStrategy, Component, Injector } from '@angular/core';
import {
  PartitionedQuerySpacePageComponent,
} from 'core-app/features/work-packages/routing/partitioned-query-space-page/partitioned-query-space-page.component';
import { HalResourceNotificationService } from 'core-app/features/hal/services/hal-resource-notification.service';
import { WorkPackageNotificationService } from 'core-app/features/work-packages/services/notifications/work-package-notification.service';
import { QueryParamListenerService } from 'core-app/features/work-packages/components/wp-query/query-param-listener.service';
import { BreadcrumbItem } from 'core-app/shared/components/breadcrumbs/op-breadcrumbs.component';
import { I18nService } from 'core-app/core/i18n/i18n.service';

@Component({
  selector: 'okr-board-page',
  templateUrl:
    '../../work-packages/routing/partitioned-query-space-page/partitioned-query-space-page.component.html',
  styleUrls: [
    '../../work-packages/routing/partitioned-query-space-page/partitioned-query-space-page.component.sass',
  ],
  changeDetection: ChangeDetectionStrategy.OnPush,
  providers: [
    { provide: HalResourceNotificationService, useClass: WorkPackageNotificationService },
    QueryParamListenerService,
  ],
  standalone: false,
})
export class OkrBoardPageComponent extends PartitionedQuerySpacePageComponent {
  constructor(
    readonly injector:Injector,
    readonly I18nOwn:I18nService,
  ) {
    super(injector);
  }

  breadcrumbItems():BreadcrumbItem[] {
    const items:BreadcrumbItem[] = [];

    if (this.currentProject?.identifier) {
      items.push({
        href: this.pathHelperService.projectPath(this.currentProject.identifier),
        text: this.currentProject.name!,
      });
    }

    items.push({ href: '', text: this.I18nOwn.t('okr_board.label_okr_board') });

    return items;
  }

  currentMenuSectionHeader():string {
    return this.I18nOwn.t('js.label_global_queries');
  }
}
