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

import { ComponentFixture, TestBed } from '@angular/core/testing';

import { I18nService } from 'core-app/core/i18n/i18n.service';
import { OpModalLocalsToken } from 'core-app/shared/components/modal/modal.service';
import { OpAttachmentPreviewModalComponent } from './attachment-preview.modal';
import { OpPreviewItem } from './attachment-preview.types';

function item(name:string):OpPreviewItem {
  return { url: `/content/${name}`, fileName: name, contentType: 'image/png', kind: 'image' };
}

function videoItem(name:string):OpPreviewItem {
  return { url: `/content/${name}`, fileName: name, contentType: 'video/mp4', kind: 'video' };
}

function backdropEvent(sameTarget:boolean):MouseEvent {
  const el = document.createElement('div');
  const child = document.createElement('img');
  return {
    target: sameTarget ? el : child,
    currentTarget: el,
    stopPropagation: () => undefined,
    preventDefault: () => undefined,
  } as unknown as MouseEvent;
}

describe('OpAttachmentPreviewModalComponent', () => {
  let closeSpy:jasmine.Spy;

  async function setup(items:OpPreviewItem[], index = 0):Promise<ComponentFixture<OpAttachmentPreviewModalComponent>> {
    closeSpy = jasmine.createSpy('close');

    await TestBed.configureTestingModule({
      declarations: [OpAttachmentPreviewModalComponent],
      providers: [
        { provide: I18nService, useValue: { t: (key:string) => key } },
        { provide: OpModalLocalsToken, useValue: { service: { close: closeSpy }, items, index } },
      ],
    }).compileComponents();

    const fixture = TestBed.createComponent(OpAttachmentPreviewModalComponent);
    fixture.detectChanges();
    return fixture;
  }

  it('exposes the current item at the given index', async () => {
    const fixture = await setup([item('a'), item('b'), item('c')], 1);
    const component = fixture.componentInstance;

    expect(component.current.fileName).toEqual('b');
    expect(component.hasMultiple).toBeTrue();
  });

  it('reports a single item as not navigable', async () => {
    const fixture = await setup([item('only')]);

    expect(fixture.componentInstance.hasMultiple).toBeFalse();
  });

  it('renders a video element (not an image) for a video item', async () => {
    const fixture = await setup([videoItem('clip.mp4')]);

    const video = fixture.nativeElement.querySelector('video') as HTMLVideoElement;

    expect(video).not.toBeNull();
    expect(video.getAttribute('src')).toBe('/content/clip.mp4');
    expect(video.controls).toBeTrue();
    expect(fixture.nativeElement.querySelector('img')).toBeNull();
  });

  it('wraps around when navigating next/previous', async () => {
    const fixture = await setup([item('a'), item('b')], 0);
    const component = fixture.componentInstance;

    component.next();

    expect(component.current.fileName).toEqual('b');
    component.next();

    expect(component.current.fileName).toEqual('a');
    component.previous();

    expect(component.current.fileName).toEqual('b');
  });

  it('does not navigate with a single item', async () => {
    const fixture = await setup([item('only')]);
    const component = fixture.componentInstance;

    component.next();
    component.previous();

    expect(component.index).toEqual(0);
  });

  it('closes when the backdrop itself is pressed', async () => {
    const fixture = await setup([item('a')]);

    fixture.componentInstance.onBackdropMousedown(backdropEvent(true));

    expect(closeSpy).toHaveBeenCalledTimes(1);
  });

  it('does not close when the media (a child) is pressed', async () => {
    const fixture = await setup([item('a')]);

    fixture.componentInstance.onBackdropMousedown(backdropEvent(false));

    expect(closeSpy).not.toHaveBeenCalled();
  });

  it('navigates with the arrow keys', async () => {
    const fixture = await setup([item('a'), item('b')], 0);
    const component = fixture.componentInstance;
    const nextSpy = spyOn(component, 'next').and.callThrough();
    const prevSpy = spyOn(component, 'previous').and.callThrough();

    component.handleKeydown(new KeyboardEvent('keydown', { key: 'ArrowRight' }));

    expect(nextSpy).toHaveBeenCalled();

    component.handleKeydown(new KeyboardEvent('keydown', { key: 'ArrowLeft' }));

    expect(prevSpy).toHaveBeenCalled();
  });

  it('ignores unrelated keys', async () => {
    const fixture = await setup([item('a'), item('b')], 0);
    const component = fixture.componentInstance;
    const nextSpy = spyOn(component, 'next').and.callThrough();

    component.handleKeydown(new KeyboardEvent('keydown', { key: 'Enter' }));

    expect(nextSpy).not.toHaveBeenCalled();
  });
});
