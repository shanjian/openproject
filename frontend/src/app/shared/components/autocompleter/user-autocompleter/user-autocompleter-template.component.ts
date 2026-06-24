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

import { ChangeDetectionStrategy, Component, inject, Input, OnInit, TemplateRef, ViewChild } from '@angular/core';
import { take } from 'rxjs/operators';
import {
  IAutocompleterTemplateComponent,
  OpAutocompleterComponent,
} from 'core-app/shared/components/autocompleter/op-autocompleter/op-autocompleter.component';
import { PathHelperService } from 'core-app/core/path-helper/path-helper.service';
import { PrincipalLike } from 'core-app/shared/components/principal/principal-types';
import { hrefFromPrincipal, typeFromHref } from 'core-app/shared/components/principal/principal-helper';
import { CurrentUserService } from 'core-app/core/current-user/current-user.service';
import { ApiV3Service } from 'core-app/core/apiv3/api-v3.service';
import { I18nService } from 'core-app/core/i18n/i18n.service';
import {
  IUserAutocompleteItem,
} from 'core-app/shared/components/autocompleter/user-autocompleter/user-autocompleter.component';

@Component({
  templateUrl: './user-autocompleter-template.component.html',
  styleUrls: ['./user-autocompleter-template.component.sass'],
  changeDetection: ChangeDetectionStrategy.OnPush,
  standalone: false,
})
export class UserAutocompleterTemplateComponent implements IAutocompleterTemplateComponent, OnInit {
  @Input() public inviteUserToProject:string|undefined;
  @Input() public isOpenedInModal = false;
  @Input() public hoverCards = true;
  @Input() public assignToMe = false;

  readonly I18n = inject(I18nService);
  readonly currentUserService = inject(CurrentUserService);
  readonly apiV3Service = inject(ApiV3Service);
  readonly autocompleter = inject(OpAutocompleterComponent);
  private readonly pathHelperService = inject(PathHelperService);

  text = {
    assignToMe: this.I18n.t('js.label_assign_to_me'),
  };

  /** The current user as an autocompleter item, or null when not logged in */
  currentUserItem:IUserAutocompleteItem|null = null;

  @ViewChild('optionTemplate') optionTemplate:TemplateRef<Element>;
  @ViewChild('headerTemplate') headerTemplate?:TemplateRef<Element>;
  @ViewChild('footerTemplate') footerTemplate?:TemplateRef<Element>;

  public ngOnInit():void {
    if (!this.assignToMe) {
      return;
    }

    this
      .currentUserService
      .user$
      .pipe(take(1))
      .subscribe((user) => {
        if (user.id) {
          this.currentUserItem = {
            id: user.id,
            name: user.name ?? '',
            href: this.apiV3Service.users.id(user.id).path,
          };
        }
      });
  }

  /** Whether to render the "Assign to me" footer action */
  public get showAssignToMe():boolean {
    if (!this.assignToMe || !this.currentUserItem) {
      return false;
    }

    const model = this.autocompleter.model as IUserAutocompleteItem|undefined|null;
    return model?.href !== this.currentUserItem.href;
  }

  public onAssignToMe($event:Event):void {
    $event.stopPropagation();

    if (!this.currentUserItem) {
      return;
    }

    this.autocompleter.changed(this.currentUserItem);
    this.autocompleter.closeSelect();
  }

  public getHoverCardUrl(principal:PrincipalLike) {
    if (!this.hoverCards || !principal.id) { return ''; }

    const type = typeFromHref(hrefFromPrincipal(principal));
    if (!type || type !== 'user') {
      return '';
    }

    return this.pathHelperService.userHoverCardPath(principal.id);
  }
}
