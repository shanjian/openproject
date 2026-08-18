/*
 * -- copyright
 * OpenProject is an open source project management software.
 * Copyright (C) the OpenProject GmbH
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License version 3.
 *
 * OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
 * Copyright (C) 2006-2013 Jean-Philippe Lang
 * Copyright (C) 2010-2013 the ChiliProject Team
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 *
 * See COPYRIGHT and LICENSE files for more details.
 * ++
 */
import { Application } from '@hotwired/stimulus';
import MeetingsFormController from './form.controller';

const nextFrame = () => new Promise((resolve) => requestAnimationFrame(resolve));

describe('MeetingsFormController browser timezone default', () => {
  let Stimulus:Application;
  let fixturesElement:HTMLElement;

  const formTemplate = (browserDefault:boolean) => `
    <form data-controller="meetings--form">
      <select name="meeting[time_zone]"
              data-meetings--form-target="timeZoneSelect"
              ${browserDefault ? 'data-browser-time-zone-default="true"' : ''}
              data-action="input->meetings--form#updateTimezoneText">
        <option value="Etc/UTC" selected="selected">(UTC+00:00) UTC</option>
        <option value="America/New_York">(UTC-05:00) New York (US East)</option>
      </select>
    </form>
  `;

  const select = ():HTMLSelectElement => fixturesElement.querySelector('select')!;

  beforeEach(async () => {
    fixturesElement = document.createElement('div');
    document.body.appendChild(fixturesElement);

    // The controller awaits the plugin context in connect() before doing anything.
    (window as unknown as { OpenProject:unknown }).OpenProject = {
      getPluginContext: () => Promise.resolve({
        services: {
          turboRequests: { request: () => Promise.resolve() },
          pathHelperService: { staticBase: '' },
        },
      }),
    };

    Stimulus = Application.start();
    Stimulus.handleError = (error, message, detail) => {
      console.error(error, message, detail);
    };
    Stimulus.register('meetings--form', MeetingsFormController);
    await nextFrame();
  });

  afterEach(() => {
    Stimulus.stop();
    fixturesElement.remove();
  });

  it("preselects the browser's zone when the server marked the select", async () => {
    spyOn(Intl, 'DateTimeFormat').and.returnValue({
      resolvedOptions: () => ({ timeZone: 'America/New_York' }),
    } as unknown as Intl.DateTimeFormat);
    fixturesElement.innerHTML = formTemplate(true);
    await nextFrame();
    await nextFrame();

    expect(select().value).toEqual('America/New_York');
  });

  it('leaves the server default alone when the select is not marked', async () => {
    spyOn(Intl, 'DateTimeFormat').and.returnValue({
      resolvedOptions: () => ({ timeZone: 'America/New_York' }),
    } as unknown as Intl.DateTimeFormat);
    fixturesElement.innerHTML = formTemplate(false);
    await nextFrame();
    await nextFrame();

    expect(select().value).toEqual('Etc/UTC');
  });

  it('leaves the server default alone when the browser zone is not in the curated list', async () => {
    spyOn(Intl, 'DateTimeFormat').and.returnValue({
      resolvedOptions: () => ({ timeZone: 'Asia/Kolkata' }),
    } as unknown as Intl.DateTimeFormat);
    fixturesElement.innerHTML = formTemplate(true);
    await nextFrame();
    await nextFrame();

    expect(select().value).toEqual('Etc/UTC');
  });
});
