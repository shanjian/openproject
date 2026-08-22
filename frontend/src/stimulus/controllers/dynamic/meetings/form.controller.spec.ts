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
/* eslint-disable @typescript-eslint/no-explicit-any, @typescript-eslint/no-unsafe-assignment */

import FormController from './form.controller';

describe('meetings form.controller', () => {
  let controller:any;
  let select:HTMLSelectElement;
  let browserZone:string;

  beforeEach(() => {
    spyOn(Intl, 'DateTimeFormat').and.callFake((() => ({
      resolvedOptions: () => ({ timeZone: browserZone }),
    })) as unknown as typeof Intl.DateTimeFormat);

    // Create a plain object that uses the controller prototype so we can call methods
    controller = Object.create(FormController.prototype);

    select = document.createElement('select');
    ['America/New_York', 'Asia/Tokyo', 'Etc/UTC'].forEach((zone) => {
      const option = document.createElement('option');
      option.value = zone;
      option.textContent = zone;
      select.appendChild(option);
    });
    select.value = 'America/New_York';

    controller.hasTimezoneSelectTarget = true;
    controller.timezoneSelectTarget = select;

    spyOn(controller, 'updateTimezoneText');
  });

  describe('applyBrowserTimezoneDefault', () => {
    it('selects the browser zone and refreshes the caption when the select is a marked fallback', () => {
      select.dataset.browserTimezoneDefault = 'true';
      browserZone = 'Asia/Tokyo';

      controller.applyBrowserTimezoneDefault();

      expect(select.value).toBe('Asia/Tokyo');
      expect(controller.updateTimezoneText).toHaveBeenCalledTimes(1);
    });

    it('leaves the server-rendered default when the browser zone is not among the options', () => {
      select.dataset.browserTimezoneDefault = 'true';
      browserZone = 'Asia/Shanghai';

      controller.applyBrowserTimezoneDefault();

      expect(select.value).toBe('America/New_York');
      expect(controller.updateTimezoneText).not.toHaveBeenCalled();
    });

    it('maps a browser-reported "UTC" onto the offered Etc/UTC option', () => {
      select.dataset.browserTimezoneDefault = 'true';
      browserZone = 'UTC';

      controller.applyBrowserTimezoneDefault();

      expect(select.value).toBe('Etc/UTC');
      expect(controller.updateTimezoneText).toHaveBeenCalledTimes(1);
    });

    it('maps a browser-reported fixed "+00:00" offset onto the offered Etc/UTC option', () => {
      select.dataset.browserTimezoneDefault = 'true';
      browserZone = '+00:00';

      controller.applyBrowserTimezoneDefault();

      expect(select.value).toBe('Etc/UTC');
      expect(controller.updateTimezoneText).toHaveBeenCalledTimes(1);
    });

    it('does not touch a select that is not marked as a fallback default', () => {
      browserZone = 'Asia/Tokyo';

      controller.applyBrowserTimezoneDefault();

      expect(select.value).toBe('America/New_York');
      expect(controller.updateTimezoneText).not.toHaveBeenCalled();
    });

    it('does not refresh the caption when the browser zone already is the selection', () => {
      select.dataset.browserTimezoneDefault = 'true';
      browserZone = 'America/New_York';

      controller.applyBrowserTimezoneDefault();

      expect(select.value).toBe('America/New_York');
      expect(controller.updateTimezoneText).not.toHaveBeenCalled();
    });

    it('is a no-op on forms without a timezone select target', () => {
      controller.hasTimezoneSelectTarget = false;
      browserZone = 'Asia/Tokyo';

      expect(() => {
        controller.applyBrowserTimezoneDefault();
      }).not.toThrow();

      expect(controller.updateTimezoneText).not.toHaveBeenCalled();
    });
  });
});
