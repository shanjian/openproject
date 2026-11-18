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

import {
  ChangeDetectionStrategy,
  Component,
  HostBinding,
  inject,
  Input,
  OnInit,
} from '@angular/core';
import { Observable } from 'rxjs';
import { shareReplay } from 'rxjs/operators';
import { WorkPackageResource } from 'core-app/features/hal/resources/work-package-resource';
import { I18nService } from 'core-app/core/i18n/i18n.service';
import { GithubBranchResourceService } from 'core-app/features/plugins/linked/openproject-github_integration/state/github-branch.service';
import { IGithubBranch } from 'core-app/features/plugins/linked/openproject-github_integration/state/github-branch.model';

@Component({
  selector: 'op-tab-branches',
  templateUrl: './tab-branches.component.html',
  changeDetection: ChangeDetectionStrategy.OnPush,
  standalone: false,
})
export class TabBranchesComponent implements OnInit {
  @HostBinding('class.op-github-branches') className = true;

  @Input() workPackage:WorkPackageResource;

  branches$:Observable<IGithubBranch[]>;

  emptyText:string;

  readonly I18n = inject(I18nService);

  readonly githubBranches = inject(GithubBranchResourceService);

  ngOnInit():void {
    this.emptyText = this.I18n.t('js.github_integration.tab_branches.empty', { wp_id: this.workPackage.id });
    // The API lists the most recently updated branch first
    this.branches$ = this
      .githubBranches
      .ofWorkPackage(this.workPackage)
      .pipe(shareReplay(1));
  }
}
