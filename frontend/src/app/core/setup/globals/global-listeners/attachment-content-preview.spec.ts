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

import { setupAttachmentContentPreview } from './attachment-content-preview';

describe('setupAttachmentContentPreview', () => {
  let openSpy:jasmine.Spy;
  let originalOpenProject:unknown;
  let root:HTMLElement;

  // Register the document-level listener exactly once for this spec file to
  // avoid stacking handlers across tests.
  beforeAll(() => {
    setupAttachmentContentPreview();
  });

  beforeEach(() => {
    openSpy = jasmine.createSpy('open');

    const context = {
      injector: { get: () => ({ open: openSpy }) },
      runInZone: (cb:() => void) => cb(),
    };

    originalOpenProject = (window as unknown as { OpenProject:unknown }).OpenProject;
    (window as unknown as { OpenProject:unknown }).OpenProject = {
      getPluginContext: () => Promise.resolve(context),
    };

    root = document.createElement('div');
    document.body.appendChild(root);
  });

  afterEach(() => {
    root.remove();
    (window as unknown as { OpenProject:unknown }).OpenProject = originalOpenProject;
  });

  // Allow the getPluginContext() promise chain to settle.
  function flush():Promise<void> {
    return new Promise((resolve) => { setTimeout(resolve, 0); });
  }

  // 1x1 transparent GIF, so no real network request is made for image sources.
  const PIXEL = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';

  function contentImage():HTMLImageElement {
    const img = document.createElement('img');
    img.className = 'op-uc-image';
    img.src = PIXEL;
    return img;
  }

  function click(el:Element, init:MouseEventInit = {}):void {
    el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, ...init }));
  }

  it('opens the preview for a clicked content image, with a gallery of siblings', async () => {
    const container = document.createElement('div');
    container.className = 'op-uc-container';
    const first = contentImage();
    const second = contentImage();
    container.append(first, second);
    root.appendChild(container);

    click(second);
    await flush();

    expect(openSpy).toHaveBeenCalledTimes(1);
    const [items, index] = openSpy.calls.mostRecent().args as [{ kind:string }[], number];

    expect(items.length).toEqual(2);
    expect(items.every((i) => i.kind === 'image')).toBeTrue();
    expect(index).toEqual(1);
  });

  it('scopes the gallery to the surrounding op-uc-container', async () => {
    const containerA = document.createElement('div');
    containerA.className = 'op-uc-container';
    const a1 = contentImage();
    containerA.appendChild(a1);

    const containerB = document.createElement('div');
    containerB.className = 'op-uc-container';
    containerB.append(contentImage(), contentImage());

    root.append(containerA, containerB);

    click(a1);
    await flush();

    const [items] = openSpy.calls.mostRecent().args as [unknown[], number];

    expect(items.length).toEqual(1);
  });

  it('ignores clicks on non-content images', async () => {
    const img = document.createElement('img');
    img.src = PIXEL;
    root.appendChild(img);

    click(img);
    await flush();

    expect(openSpy).not.toHaveBeenCalled();
  });

  it('ignores content images wrapped in a link', async () => {
    const link = document.createElement('a');
    link.href = '#';
    // Prevent the anchor from triggering a (Turbo) navigation during the test.
    link.addEventListener('click', (evt) => evt.preventDefault());
    const img = contentImage();
    link.appendChild(img);
    root.appendChild(link);

    click(img);
    await flush();

    expect(openSpy).not.toHaveBeenCalled();
  });

  it('ignores content images inside an editing (CKEditor) container', async () => {
    const editing = document.createElement('div');
    editing.className = 'ck-content';
    const img = contentImage();
    editing.appendChild(img);
    root.appendChild(editing);

    click(img);
    await flush();

    expect(openSpy).not.toHaveBeenCalled();
  });

  it('ignores content images inside an inline-editable field (keeps click-to-edit)', async () => {
    // e.g. the work package description, where clicking the image should
    // activate the editor rather than open the preview.
    const field = document.createElement('op-editable-attribute-field');
    const container = document.createElement('div');
    container.className = 'op-uc-container';
    const img = contentImage();
    container.appendChild(img);
    field.appendChild(container);
    root.appendChild(field);

    click(img);
    await flush();

    expect(openSpy).not.toHaveBeenCalled();
  });

  it('ignores modifier / non-primary clicks', async () => {
    const container = document.createElement('div');
    container.className = 'op-uc-container';
    const img = contentImage();
    container.appendChild(img);
    root.appendChild(container);

    click(img, { ctrlKey: true });
    await flush();

    expect(openSpy).not.toHaveBeenCalled();
  });
});
