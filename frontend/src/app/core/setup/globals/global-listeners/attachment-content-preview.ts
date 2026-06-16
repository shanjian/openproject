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

import { OpAttachmentPreviewService } from 'core-app/shared/components/attachments/attachment-preview/attachment-preview.service';
import { OpPreviewItem } from 'core-app/shared/components/attachments/attachment-preview/attachment-preview.types';

// Images rendered inside formatted (rich text) content, e.g. work package
// descriptions, comments and wiki pages.
const CONTENT_IMAGE_SELECTOR = 'img.op-uc-image';
// The wrapper around a single rendered formatted field; used to scope the
// preview gallery to the content block that was clicked.
const CONTENT_CONTAINER_SELECTOR = '.op-uc-container';
// Do not hijack clicks while the content is being edited in CKEditor.
const EDITING_SELECTOR = '.op-uc-container_editing, .ck-content';
// Images inside an inline-editable field (e.g. the work package description)
// keep their click-to-edit behavior: the field already displays the image
// well, and the click should activate the editor rather than open the preview.
const EDITABLE_FIELD_SELECTOR = 'op-editable-attribute-field';

function fileNameFromImage(img:HTMLImageElement):string {
  if (img.alt) {
    return img.alt;
  }

  try {
    const url = new URL(img.src, window.location.href);
    const last = url.pathname.split('/').filter(Boolean).pop();
    return last ? decodeURIComponent(last) : img.src;
  } catch {
    return img.src;
  }
}

function buildItem(img:HTMLImageElement):OpPreviewItem {
  return {
    url: img.src,
    downloadUrl: img.src,
    fileName: fileNameFromImage(img),
    contentType: 'image/*',
    kind: 'image',
  };
}

/**
 * Open content images (images embedded in formatted text such as work package
 * descriptions, comments and wiki pages) in the in-app preview (lightbox)
 * instead of leaving them as non-interactive inline images.
 *
 * Works on both Angular and server-rendered pages by bridging into the Angular
 * application through the global plugin context.
 */
export function setupAttachmentContentPreview():void {
  document
    .documentElement
    .addEventListener('click', (evt) => {
      // Respect modifier / non-primary clicks (open in new tab, etc.)
      if (evt.button !== 0 || evt.metaKey || evt.ctrlKey || evt.shiftKey || evt.altKey) {
        return;
      }

      const target = evt.target as HTMLElement;
      const img = target.closest<HTMLImageElement>(CONTENT_IMAGE_SELECTOR);
      if (!img) {
        return;
      }

      // Linked images keep their link behavior; editing widgets keep theirs.
      // Images inside an inline-editable field keep click-to-edit.
      if (img.closest('a') || img.closest(EDITING_SELECTOR) || img.closest(EDITABLE_FIELD_SELECTOR)) {
        return;
      }

      const container = img.closest(CONTENT_CONTAINER_SELECTOR) ?? document;
      const images = Array
        .from(container.querySelectorAll<HTMLImageElement>(CONTENT_IMAGE_SELECTOR))
        .filter((el) => !el.closest('a'));
      const items = images.map(buildItem);
      const index = Math.max(0, images.indexOf(img));

      if (items.length === 0) {
        return;
      }

      evt.preventDefault();

      void window.OpenProject.getPluginContext().then((context) => {
        const service = context.injector.get(OpAttachmentPreviewService);
        context.runInZone(() => service.open(items, index));
      });
    });
}
