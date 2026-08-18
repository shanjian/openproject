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

import { Ng2StateDeclaration } from '@uirouter/angular';
import { OkrBoardEntryComponent } from 'core-app/features/okr-board/okr-board-entry/okr-board-entry.component';
import { OkrBoardPageComponent } from 'core-app/features/okr-board/okr-board-page/okr-board-page.component';
import { WorkPackageListViewComponent } from 'core-app/features/work-packages/routing/wp-list-view/wp-list-view.component';
import { makeSplitViewRoutes } from 'core-app/features/work-packages/routing/split-view-routes.template';
import { WorkPackageSplitViewComponent } from 'core-app/features/work-packages/routing/wp-split-view/wp-split-view.component';

export const menuItemClass = 'okr-board-menu-item';

export const OKR_BOARD_ROUTES:Ng2StateDeclaration[] = [
  {
    name: 'okr-board',
    parent: 'optional_project',
    url: '/okr_board/?query_props',
    component: OkrBoardEntryComponent,
    data: {
      bodyClasses: 'router--okr-board-base',
      menuItem: menuItemClass,
    },
    params: {
      query_props: { type: 'opQueryString', dynamic: true },
    },
  },
  {
    name: 'okr-board.partitioned',
    component: OkrBoardPageComponent,
    url: '',
    redirectTo: 'okr-board.partitioned.list',
    data: {
      bodyClasses: '',
    },
  },
  {
    name: 'okr-board.partitioned.list',
    url: '',
    reloadOnSearch: false,
    views: {
      'content-left': { component: WorkPackageListViewComponent },
    },
    data: {
      bodyClasses: ['router--okr-board-partitioned-split-view'],
      menuItem: menuItemClass,
      partition: '-left-only',
    },
  },
  ...makeSplitViewRoutes(
    'okr-board.partitioned.list',
    menuItemClass,
    WorkPackageSplitViewComponent,
  ),
];
