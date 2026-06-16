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

import { inject, Injectable, Injector } from '@angular/core';

import { OpModalService } from 'core-app/shared/components/modal/modal.service';
import { IAttachment } from 'core-app/core/state/attachments/attachment.model';
import { OpAttachmentPreviewModalComponent } from './attachment-preview.modal';
import { OpPreviewItem, OpPreviewMediaKind } from './attachment-preview.types';

@Injectable({ providedIn: 'root' })
export class OpAttachmentPreviewService {
  private readonly opModalService = inject(OpModalService);

  private readonly injector = inject(Injector);

  /**
   * Returns the preview kind for a given content type, or null if the type
   * cannot be previewed in the lightbox.
   */
  public static previewKind(contentType:string|undefined|null):OpPreviewMediaKind|null {
    if (!contentType) {
      return null;
    }

    if (contentType.startsWith('image/')) {
      return 'image';
    }

    if (contentType.startsWith('video/')) {
      return 'video';
    }

    return null;
  }

  /**
   * Build a preview item from an attachment, or null if it is not previewable
   * (or not yet available, e.g. quarantined / pending virus scan).
   */
  public static itemFor(attachment:IAttachment):OpPreviewItem|null {
    const kind = this.previewKind(attachment.contentType);
    if (!kind || attachment.status === 'quarantined') {
      return null;
    }

    const url = attachment._links.staticDownloadLocation.href;
    return {
      url,
      downloadUrl: url,
      fileName: attachment.fileName,
      contentType: attachment.contentType,
      kind,
    };
  }

  /**
   * Open the preview lightbox with the given items, focused on `index`.
   * Does nothing when there are no items to show.
   */
  public open(items:OpPreviewItem[], index = 0):void {
    if (items.length === 0) {
      return;
    }

    const safeIndex = Math.max(0, Math.min(index, items.length - 1));

    this.opModalService.show(
      OpAttachmentPreviewModalComponent,
      this.injector,
      { items, index: safeIndex },
    );
  }

  /**
   * Convenience: open the preview from a list of attachments, building the
   * previewable gallery and focusing on the clicked attachment. Returns true
   * when the lightbox was opened (i.e. the attachment is previewable).
   */
  public openForAttachment(attachment:IAttachment, siblings:IAttachment[] = [attachment]):boolean {
    const clicked = OpAttachmentPreviewService.itemFor(attachment);
    if (!clicked) {
      return false;
    }

    const gallery:OpPreviewItem[] = [];
    let index = 0;
    siblings.forEach((sibling) => {
      const item = OpAttachmentPreviewService.itemFor(sibling);
      if (!item) {
        return;
      }

      if (sibling.id === attachment.id) {
        index = gallery.length;
      }
      gallery.push(item);
    });

    this.open(gallery.length > 0 ? gallery : [clicked], index);
    return true;
  }
}
