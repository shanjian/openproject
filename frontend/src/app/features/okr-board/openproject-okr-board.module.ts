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

import { NgModule } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { OpSharedModule } from 'core-app/shared/shared.module';
import { OpenprojectWorkPackagesModule } from 'core-app/features/work-packages/openproject-work-packages.module';
import { UIRouterModule } from '@uirouter/angular';
import { OkrBoardEntryComponent } from 'core-app/features/okr-board/okr-board-entry/okr-board-entry.component';
import { OkrBoardPageComponent } from 'core-app/features/okr-board/okr-board-page/okr-board-page.component';
import { OkrBoardFilterAreaComponent } from 'core-app/features/okr-board/okr-board-filter-area/okr-board-filter-area.component';
import { OkrBoardFilterComponent } from 'core-app/features/okr-board/okr-board-filter/okr-board-filter.component';
import { OKR_BOARD_ROUTES } from 'core-app/features/okr-board/openproject-okr-board.routes';

@NgModule({
  imports: [
    OpSharedModule,
    OpenprojectWorkPackagesModule,
    FormsModule,
    UIRouterModule.forChild({
      states: OKR_BOARD_ROUTES,
    }),
  ],
  declarations: [
    OkrBoardEntryComponent,
    OkrBoardPageComponent,
    OkrBoardFilterAreaComponent,
    OkrBoardFilterComponent,
  ],
})
export class OpenprojectOkrBoardModule {
}
