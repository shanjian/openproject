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
  ChangeDetectorRef,
  Component,
  ElementRef,
  HostListener,
  inject,
} from '@angular/core';

import { OpModalComponent } from 'core-app/shared/components/modal/modal.component';
import { OpModalLocalsToken } from 'core-app/shared/components/modal/modal.service';
import { I18nService } from 'core-app/core/i18n/i18n.service';
import { OpPreviewItem } from './attachment-preview.types';

@Component({
  templateUrl: './attachment-preview.modal.html',
  styleUrls: ['./attachment-preview.modal.sass'],
  changeDetection: ChangeDetectionStrategy.OnPush,
  standalone: false,
})
export class OpAttachmentPreviewModalComponent extends OpModalComponent {
  readonly I18n = inject(I18nService);

  public items:OpPreviewItem[];

  public index:number;

  public text = {
    previous: this.I18n.t('js.attachments.preview.previous'),
    next: this.I18n.t('js.attachments.preview.next'),
    open_in_new_tab: this.I18n.t('js.attachments.preview.open_in_new_tab'),
    close: this.I18n.t('js.close_popup_title'),
    counter: (current:number, total:number):string =>
      this.I18n.t('js.attachments.preview.counter', { current, total }),
  };

  constructor() {
    super(inject(OpModalLocalsToken), inject(ChangeDetectorRef), inject(ElementRef));
    this.items = (this.locals.items ?? []) as OpPreviewItem[];
    this.index = (this.locals.index as number) ?? 0;
  }

  public get current():OpPreviewItem {
    return this.items[this.index];
  }

  public get hasMultiple():boolean {
    return this.items.length > 1;
  }

  public next(evt?:Event):void {
    evt?.stopPropagation();
    if (!this.hasMultiple) {
      return;
    }
    this.index = (this.index + 1) % this.items.length;
    this.cdRef.markForCheck();
  }

  public previous(evt?:Event):void {
    evt?.stopPropagation();
    if (!this.hasMultiple) {
      return;
    }
    this.index = (this.index - 1 + this.items.length) % this.items.length;
    this.cdRef.markForCheck();
  }

  /**
   * Close when the user presses on the backdrop itself (the empty area around
   * the media), but not when pressing on the media or controls. Uses mousedown
   * to mirror the modal overlay's own backdrop handling.
   */
  public onBackdropMousedown(evt:MouseEvent):void {
    if (evt.target === evt.currentTarget) {
      this.closeMe(evt);
    }
  }

  @HostListener('document:keydown', ['$event'])
  public handleKeydown(evt:KeyboardEvent):void {
    if (evt.key === 'ArrowRight') {
      this.next();
      evt.preventDefault();
    } else if (evt.key === 'ArrowLeft') {
      this.previous();
      evt.preventDefault();
    }
  }
}
