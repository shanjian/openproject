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
  static targets = ['timeZoneSelect'];

  declare timeZoneSelectTarget:HTMLSelectElement;
  declare hasTimeZoneSelectTarget:boolean;

  protected turboRequests:TurboRequestsService;
  protected pathHelper:PathHelperService;

  async connect() {
    const context = await window.OpenProject.getPluginContext();
    this.turboRequests = context.services.turboRequests;
    this.pathHelper = context.services.pathHelperService;

    this.applyBrowserTimezoneDefault();
  }

  // The server marks the select when creating a meeting as a user who has no
  // profile time zone of their own, in which case it renders UTC. Prefer the
  // browser's own zone there, leaving the select editable. Zones outside the
  // curated list have no option to select, so the server default stands.
  private applyBrowserTimezoneDefault():void {
    if (!this.hasTimeZoneSelectTarget) {
      return;
    }

    const select = this.timeZoneSelectTarget;
    if (select.dataset.browserTimeZoneDefault !== 'true') {
      return;
    }

    const browserTimezone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    if (!browserTimezone || select.value === browserTimezone) {
      return;
    }

    if (!Array.from(select.options).some((option) => option.value === browserTimezone)) {
      return;
    }

    select.value = browserTimezone;
    select.dispatchEvent(new Event('input', { bubbles: true }));
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
