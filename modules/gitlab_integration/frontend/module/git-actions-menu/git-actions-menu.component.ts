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
    createBranchSuccess: this.I18n.t('js.gitlab_integration.tab_header_mr.git_actions.create_branch_success'),
    createBranchExists: this.I18n.t('js.gitlab_integration.tab_header_mr.git_actions.create_branch_exists'),
  };

  public lastCopyResult:string = this.text.copyResult.success;
  public showCopyResult:boolean = false;
  public copiedSnippetId:string = '';
  public creatingBranch = false;

  private readonly apiV3Service = inject(ApiV3Service);
  private readonly toastService = inject(ToastService);
  private readonly http = inject(HttpClient);

  public snippets:ISnippet[] = [
    {
      id: 'branch',
      name: this.I18n.t('js.gitlab_integration.tab_header_mr.git_actions.branch_name'),
      textToDisplay: () => this.gitActions.branchName(this.workPackage),
      textToCopy: () => this.gitActions.branchName(this.workPackage)
    },
    {
      id: 'message',
      name: this.I18n.t('js.gitlab_integration.tab_header_mr.git_actions.commit_message'),
      textToDisplay: () => this.gitActions.commitMessageDisplayText(this.workPackage),
      textToCopy: () => this.gitActions.commitMessage(this.workPackage)
    },
    {
      id: 'command',
      name: this.I18n.t('js.gitlab_integration.tab_header_mr.git_actions.cmd'),
      textToDisplay: () => this.gitActions.gitCommand(this.workPackage),
      textToCopy: () => this.gitActions.gitCommand(this.workPackage)
    },
  ];

  constructor(@Inject(OpContextMenuLocalsToken)
              public locals:OpContextMenuLocalsMap,
              readonly I18n:I18nService,
              readonly gitActions:GitActionsService) {
    super(locals);
    this.workPackage = this.locals.workPackage;
  }

  public createBranch():void {
    if (this.creatingBranch) {
      return;
    }

    this.creatingBranch = true;
    const path = `${this.apiV3Service.work_packages.id(this.workPackage.id!).path}/gitlab/branches`;

    this.http
      .post<ICreateBranchResponse>(path, {}, { withCredentials: true })
      .subscribe({
        next: (response) => {
          this.creatingBranch = false;
          const message = response.alreadyExisted ? this.text.createBranchExists : this.text.createBranchSuccess;
          this.toastService.addSuccess(`${message} ${response.branch}`);
        },
        error: (error:HttpErrorResponse) => {
          this.creatingBranch = false;
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
