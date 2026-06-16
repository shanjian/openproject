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

import { TestBed } from '@angular/core/testing';

import { IAttachment } from 'core-app/core/state/attachments/attachment.model';
import { OpModalService } from 'core-app/shared/components/modal/modal.service';
import { OpAttachmentPreviewService } from './attachment-preview.service';
import { OpAttachmentPreviewModalComponent } from './attachment-preview.modal';

interface AttachmentProps {
  id?:number;
  contentType?:string;
  status?:string;
  fileName?:string;
  originOpen?:boolean;
  href?:string;
}

function makeAttachment(props:AttachmentProps = {}):IAttachment {
  const id = props.id ?? 1;
  const links:Record<string, { href:string }> = {
    staticDownloadLocation: { href: props.href ?? `/api/v3/attachments/${id}/content` },
  };
  if (props.originOpen) {
    links.originOpen = { href: 'https://nextcloud.example/f/1' };
  }

  return {
    id,
    title: props.fileName ?? 'image.png',
    status: props.status ?? 'uploaded',
    fileName: props.fileName ?? 'image.png',
    fileSize: 100,
    description: { format: 'plain', raw: '', html: '' },
    contentType: props.contentType ?? 'image/png',
    digest: 'abc',
    createdAt: '2020-01-01T00:00:00Z',
    _links: links,
  } as unknown as IAttachment;
}

describe('OpAttachmentPreviewService', () => {
  describe('previewKind (static)', () => {
    it('maps image/* to image', () => {
      expect(OpAttachmentPreviewService.previewKind('image/png')).toEqual('image');
      expect(OpAttachmentPreviewService.previewKind('image/svg+xml')).toEqual('image');
    });

    it('maps video/* to video', () => {
      expect(OpAttachmentPreviewService.previewKind('video/mp4')).toEqual('video');
    });

    it('returns null for other / missing content types', () => {
      expect(OpAttachmentPreviewService.previewKind('application/pdf')).toBeNull();
      expect(OpAttachmentPreviewService.previewKind('')).toBeNull();
      expect(OpAttachmentPreviewService.previewKind(undefined)).toBeNull();
      expect(OpAttachmentPreviewService.previewKind(null)).toBeNull();
    });
  });

  describe('itemFor (static)', () => {
    it('builds an item for a previewable image', () => {
      const item = OpAttachmentPreviewService.itemFor(makeAttachment({ contentType: 'image/png' }));

      expect(item).toEqual({
        url: '/api/v3/attachments/1/content',
        downloadUrl: '/api/v3/attachments/1/content',
        fileName: 'image.png',
        contentType: 'image/png',
        kind: 'image',
      });
    });

    it('builds a video item', () => {
      const item = OpAttachmentPreviewService.itemFor(makeAttachment({ contentType: 'video/mp4', fileName: 'clip.mp4' }));

      expect(item?.kind).toEqual('video');
    });

    it('returns null for non-previewable content types', () => {
      expect(OpAttachmentPreviewService.itemFor(makeAttachment({ contentType: 'application/pdf' }))).toBeNull();
    });

    it('returns null for quarantined attachments', () => {
      expect(OpAttachmentPreviewService.itemFor(makeAttachment({ status: 'quarantined' }))).toBeNull();
    });

    it('returns null for external-storage (originOpen) attachments', () => {
      expect(OpAttachmentPreviewService.itemFor(makeAttachment({ originOpen: true }))).toBeNull();
    });
  });

  describe('open / openForAttachment', () => {
    let service:OpAttachmentPreviewService;
    let showSpy:jasmine.Spy;

    beforeEach(() => {
      showSpy = jasmine.createSpy('show');
      TestBed.configureTestingModule({
        providers: [
          { provide: OpModalService, useValue: { show: showSpy } },
        ],
      });
      service = TestBed.inject(OpAttachmentPreviewService);
    });

    it('does not open the modal when there are no items', () => {
      service.open([], 0);

      expect(showSpy).not.toHaveBeenCalled();
    });

    it('opens the modal with the preview component and clamps the index', () => {
      const items = [
        { url: 'a', fileName: 'a', contentType: 'image/png', kind: 'image' as const },
        { url: 'b', fileName: 'b', contentType: 'image/png', kind: 'image' as const },
      ];

      service.open(items, 5);

      expect(showSpy).toHaveBeenCalledTimes(1);
      const args = showSpy.calls.mostRecent().args;

      expect(args[0]).toBe(OpAttachmentPreviewModalComponent);
      expect(args[2]).toEqual({ items, index: 1 });
    });

    it('clamps a negative index to 0', () => {
      const items = [{ url: 'a', fileName: 'a', contentType: 'image/png', kind: 'image' as const }];
      service.open(items, -3);

      expect(showSpy.calls.mostRecent().args[2]).toEqual({ items, index: 0 });
    });

    it('builds a gallery from siblings, excludes non-previewable/external, and focuses the clicked one', () => {
      const image1 = makeAttachment({ id: 1, fileName: 'one.png' });
      const pdf = makeAttachment({ id: 2, contentType: 'application/pdf', fileName: 'doc.pdf' });
      const external = makeAttachment({ id: 3, originOpen: true, fileName: 'remote.png' });
      const image2 = makeAttachment({ id: 4, fileName: 'two.png' });

      const opened = service.openForAttachment(image2, [image1, pdf, external, image2]);

      expect(opened).toBeTrue();
      expect(showSpy).toHaveBeenCalledTimes(1);
      const { items, index } = showSpy.calls.mostRecent().args[2] as { items:{ fileName:string }[], index:number };
      // pdf + external filtered out; only the two images remain, in order.
      expect(items.map((i) => i.fileName)).toEqual(['one.png', 'two.png']);
      // clicked image2 is the second previewable item.
      expect(index).toEqual(1);
    });

    it('returns false and does not open for a non-previewable attachment', () => {
      const opened = service.openForAttachment(makeAttachment({ contentType: 'application/pdf' }));

      expect(opened).toBeFalse();
      expect(showSpy).not.toHaveBeenCalled();
    });
  });
});
