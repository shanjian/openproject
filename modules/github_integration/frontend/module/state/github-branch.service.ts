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

import { Injectable } from '@angular/core';
import { WorkPackageResource } from 'core-app/features/hal/resources/work-package-resource';
import { IGithubBranch } from 'core-app/features/plugins/linked/openproject-github_integration/state/github-branch.model';
import { GithubBranchesStore } from 'core-app/features/plugins/linked/openproject-github_integration/state/github-branch.store';
import { ID } from '@datorama/akita';
import { ResourceStoreService, ResourceStore } from 'core-app/core/state/resource-store.service';
import { Observable } from 'rxjs';

@Injectable()
export class GithubBranchResourceService extends ResourceStoreService<IGithubBranch> {
  ofWorkPackage(workPackage:WorkPackageResource):Observable<IGithubBranch[]> {
    const path = this.workPackageBranchesPath(workPackage.id!);
    return this.requireCollection(path);
  }

  /**
   * Branches have no collection of their own in the API, they are only listed per work package
   * (see `ofWorkPackage`). Nothing is requested from here, but the store service needs a base.
   */
  protected basePath():string {
    return this.apiV3Service.work_packages.path;
  }

  protected workPackageBranchesPath(id:ID):string {
    return `${this.apiV3Service.work_packages.id(id).path}/github_branches`;
  }

  protected createStore():ResourceStore<IGithubBranch> {
    return new GithubBranchesStore();
  }
}
