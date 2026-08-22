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

import { ApplicationController } from 'stimulus-use';
import { TurboRequestsService } from 'core-app/core/turbo/turbo-requests.service';
import { PathHelperService } from 'core-app/core/path-helper/path-helper.service';

export default class extends ApplicationController {
  static targets = ['timezoneSelect'];

  declare readonly timezoneSelectTarget:HTMLSelectElement;
  declare readonly hasTimezoneSelectTarget:boolean;

  protected turboRequests:TurboRequestsService;
  protected pathHelper:PathHelperService;

  async connect() {
    const context = await window.OpenProject.getPluginContext();
    this.turboRequests = context.services.turboRequests;
    this.pathHelper = context.services.pathHelperService;

    this.applyBrowserTimezoneDefault();
  }

  // When the server rendered only a fallback zone (nothing stored on the
  // meeting, no explicit profile zone - marked via data-browser-timezone-default),
  // refine it to the browser's own zone, provided that zone is among the
  // offered options. An explicit selection is never overridden.
  applyBrowserTimezoneDefault():void {
    if (!this.hasTimezoneSelectTarget) {
      return;
    }

    const select = this.timezoneSelectTarget;
    if (select.dataset.browserTimezoneDefault !== 'true') {
      return;
    }

    const browserZone = this.normalizeBrowserZone(Intl.DateTimeFormat().resolvedOptions().timeZone);
    if (!browserZone || select.value === browserZone) {
      return;
    }

    const offered = Array.from(select.options).some((option) => option.value === browserZone);
    if (!offered) {
      return;
    }

    select.value = browserZone;
    this.updateTimezoneText();
  }

  // The select's option values are tzinfo identifiers, but browsers report the
  // UTC family differently: V8 resolves any UTC-equivalent system zone (UTC,
  // Etc/UTC, Universal, ...) to plain "UTC", and a fixed-offset TZ like GMT to
  // "+00:00" - neither of which matches the offered "Etc/UTC" option verbatim.
  private normalizeBrowserZone(zone:string):string {
    if (['UTC', 'GMT', 'Etc/GMT', 'Etc/Universal', 'Etc/Zulu', '+00:00'].includes(zone)) {
      return 'Etc/UTC';
    }

    return zone;
  }

  updateTimezoneText():void {
    const data = new FormData(this.element as HTMLFormElement);
    const urlSearchParams = new URLSearchParams();
    let key:string;

    ['start_date', 'start_time_hour', 'time_zone'].forEach((name) => {
      key = `meeting[${name}]`;
      urlSearchParams.append(key, data.get(key) as string);
    });

    void this
      .turboRequests
      .request(
        `${this.pathHelper.staticBase}/meetings/fetch_timezone?${urlSearchParams.toString()}`,
        {
          headers: {
            Accept: 'text/vnd.turbo-stream.html',
          },
        },
      );
  }
}
