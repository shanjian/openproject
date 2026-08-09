//-- copyright
// OpenProject is an open source project management software.
// Copyright (C) 2023 Ben Tey
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License version 3.
//
// OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
// Copyright (C) 2006-2013 Jean-Philippe Lang
// Copyright (C) 2010-2013 the ChiliProject Team
// Copyright (C) the OpenProject GmbH
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
// See docs/COPYRIGHT.rdoc for more details.
//++

import copy from 'copy-text-to-clipboard';
import { Component, Inject, Input, inject } from '@angular/core';
import { HttpClient, HttpErrorResponse } from '@angular/common/http';
import { GitActionsService } from '../git-actions/git-actions.service';
import { ISnippet } from "core-app/features/plugins/linked/openproject-gitlab_integration/typings";
import { WorkPackageResource } from "core-app/features/hal/resources/work-package-resource";
import { OPContextMenuComponent } from "core-app/shared/components/op-context-menu/op-context-menu.component";
import {
  OpContextMenuLocalsMap,
  OpContextMenuLocalsToken
} from "core-app/shared/components/op-context-menu/op-context-menu.types";
import { I18nService } from "core-app/core/i18n/i18n.service";
import { ApiV3Service } from 'core-app/core/apiv3/api-v3.service';
import { ToastService } from 'core-app/shared/components/toaster/toast.service';

interface ICreateBranchResponse {
  branch:string;
  webUrl:string|null;
  alreadyExisted:boolean;
  repository:string;
}

interface IBranchTarget {
  id:number;
  name:string;
  gitlabProjectId:string;
}

interface IBranchTargetsResponse {
  targets:IBranchTarget[];
}


@Component({
  selector: 'op-git-actions-menu',
  templateUrl: './git-actions-menu.template.html',
  styleUrls: [
    './styles/git-actions-menu.sass'
  ],
  standalone: false,
})
export class GitActionsMenuComponent extends OPContextMenuComponent {
  @Input() public workPackage:WorkPackageResource;

  public text = {
    title: this.I18n.t('js.gitlab_integration.tab_header_mr.git_actions.title'),
    copyButtonHelpText: this.I18n.t('js.gitlab_integration.tab_header_mr.git_actions.copy_button_help'),
    copyResult: {
      success: this.I18n.t('js.gitlab_integration.tab_header_mr.git_actions.copy_success'),
      error: this.I18n.t('js.gitlab_integration.tab_header_mr.git_actions.copy_error')
    },
    createBranch: this.I18n.t('js.gitlab_integration.tab_header_mr.git_actions.create_branch'),
    createBranchAll: this.I18n.t('js.gitlab_integration.tab_header_mr.git_actions.create_branch_all'),
    createBranchSuccess: this.I18n.t('js.gitlab_integration.tab_header_mr.git_actions.create_branch_success'),
    createBranchExists: this.I18n.t('js.gitlab_integration.tab_header_mr.git_actions.create_branch_exists'),
    noTargets: this.I18n.t('js.gitlab_integration.tab_header_mr.git_actions.create_branch_no_targets'),
  };

  public lastCopyResult:string = this.text.copyResult.success;
  public showCopyResult:boolean = false;
  public copiedSnippetId:string = '';
  public branchTargets:IBranchTarget[] = [];
  public targetsLoaded = false;
  public inFlight = 0;

  private readonly apiV3Service = inject(ApiV3Service);
  private readonly toastService = inject(ToastService);
  private readonly http = inject(HttpClient);

  // Captured once per panel open so the displayed name, the copied name, the
  // embedded name in the "create branch with empty commit" command, and the
  // name actually created via "Create branch in GitLab" all agree exactly.
  private branchNameValue = '';

  public get creatingBranch():boolean {
    return this.inFlight > 0;
  }

  public snippets:ISnippet[] = [];

  constructor(@Inject(OpContextMenuLocalsToken)
              public locals:OpContextMenuLocalsMap,
              readonly I18n:I18nService,
              readonly gitActions:GitActionsService) {
    super(locals);
    this.workPackage = this.locals.workPackage;

    const timestampSuffix = this.gitActions.timestampSuffix();
    this.branchNameValue = this.gitActions.branchName(this.workPackage, timestampSuffix);

    this.snippets = [
      {
        id: 'branch',
        name: this.I18n.t('js.gitlab_integration.tab_header_mr.git_actions.branch_name'),
        textToDisplay: () => this.branchNameValue,
        textToCopy: () => this.branchNameValue
      },
      {
        id: 'message',
        name: this.I18n.t('js.gitlab_integration.tab_header_mr.git_actions.merge_request_message'),
        textToDisplay: () => this.gitActions.mergeRequestMessageDisplayText(this.workPackage),
        textToCopy: () => this.gitActions.mergeRequestMessage(this.workPackage)
      },
      {
        id: 'command',
        name: this.I18n.t('js.gitlab_integration.tab_header_mr.git_actions.cmd'),
        textToDisplay: () => this.gitActions.gitCommand(this.workPackage, timestampSuffix),
        textToCopy: () => this.gitActions.gitCommand(this.workPackage, timestampSuffix)
      },
    ];

    this.loadBranchTargets();
  }

  private get branchesBasePath():string {
    return `${this.apiV3Service.work_packages.id(this.workPackage.id!).path}/gitlab`;
  }

  private loadBranchTargets():void {
    this.http
      .get<IBranchTargetsResponse>(`${this.branchesBasePath}/branch_targets`, { withCredentials: true })
      .subscribe({
        next: (response) => {
          this.branchTargets = response.targets;
          this.targetsLoaded = true;
        },
        error: () => {
          // Leave the picker hidden; the button falls back to a single request.
          this.targetsLoaded = true;
        },
      });
  }

  public createInAllTargets():void {
    this.branchTargets.forEach((target) => this.createBranch(target));
  }

  public createBranch(target?:IBranchTarget):void {
    this.inFlight += 1;
    const body = target
      ? { mappingId: target.id, branchName: this.branchNameValue }
      : { branchName: this.branchNameValue };

    this.http
      .post<ICreateBranchResponse>(`${this.branchesBasePath}/branches`, body, { withCredentials: true })
      .subscribe({
        next: (response) => {
          this.inFlight -= 1;
          const prefix = response.alreadyExisted ? this.text.createBranchExists : this.text.createBranchSuccess;
          this.toastService.addSuccess(`${prefix} ${response.repository} — ${response.branch}`);
        },
        error: (error:HttpErrorResponse) => {
          this.inFlight -= 1;
          this.toastService.addError(error);
        },
      });
  }

  public onCopyButtonClick(snippet:ISnippet):void {
    const success = copy(snippet.textToCopy());

    if (success) {
      this.lastCopyResult = this.text.copyResult.success;
    } else {
      this.lastCopyResult = this.text.copyResult.error;
    }
    this.copiedSnippetId = snippet.id;
    this.showCopyResult = true;
    window.setTimeout(() => {
      this.showCopyResult = false;
    }, 2000);
  }
}
