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

import { Injector } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { I18nService } from 'core-app/core/i18n/i18n.service';
import { ToastService } from 'core-app/shared/components/toaster/toast.service';
import { PathHelperService } from 'core-app/core/path-helper/path-helper.service';
import { WorkPackageResource } from 'core-app/features/hal/resources/work-package-resource';
import { HalResourceService } from 'core-app/features/hal/services/hal-resource.service';
import { SchemaCacheService } from 'core-app/core/schemas/schema-cache.service';
import { States } from 'core-app/core/states/states.service';
import { take, takeWhile } from 'rxjs/operators';
import { WorkPackagesActivityService } from 'core-app/features/work-packages/components/wp-single-view-tabs/activity-panel/wp-activity.service';
import { ConfigurationService } from 'core-app/core/config/configuration.service';
import { WorkPackageNotificationService } from 'core-app/features/work-packages/services/notifications/work-package-notification.service';
import { WorkPackageCache } from 'core-app/core/apiv3/endpoints/work_packages/work-package.cache';
import { isPartialWorkPackage, markPartialWorkPackage } from 'core-app/features/hal/helpers/partial-work-package';
import { TimezoneService } from 'core-app/core/datetime/timezone.service';
import { HalResourceNotificationService } from 'core-app/features/hal/services/hal-resource-notification.service';
import { OpenprojectHalModule } from 'core-app/features/hal/openproject-hal.module';
import { provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient, withInterceptorsFromDi } from '@angular/common/http';

describe('WorkPackageCache', () => {
  let injector:Injector;
  let states:States;
  let workPackageCache:WorkPackageCache;
  let schemaCacheService:SchemaCacheService;
  let dummyWorkPackages:WorkPackageResource[] = [];

  beforeEach(() => {
    TestBed.configureTestingModule({
    imports: [OpenprojectHalModule],
    providers: [
        States,
        HalResourceService,
        TimezoneService,
        WorkPackagesActivityService,
        SchemaCacheService,
        PathHelperService,
        { provide: ConfigurationService, useValue: {} },
        { provide: I18nService, useValue: { t: (...args:any[]) => 'translation' } },
        { provide: WorkPackageResource, useValue: {} },
        { provide: ToastService, useValue: {} },
        { provide: HalResourceNotificationService, useValue: { handleRawError: () => false } },
        { provide: WorkPackageNotificationService, useValue: {} },
        provideHttpClient(withInterceptorsFromDi()),
        provideHttpClientTesting(),
    ]
});

    injector = TestBed.inject(Injector);
    states = TestBed.inject(States);
    schemaCacheService = TestBed.inject(SchemaCacheService);
    workPackageCache = new WorkPackageCache(injector, states.workPackages);

    // sinon.stub(schemaCacheService, 'ensureLoaded').returns(Promise.resolve(true));
    spyOn(schemaCacheService, 'ensureLoaded').and.resolveTo(true as any);

    const workPackage1 = new WorkPackageResource(
      injector,
      {
        id: '1',
        _links: {
          self: '',
        },
      },
      true,
      (wp:WorkPackageResource) => undefined,
      'WorkPackage',
    );

    dummyWorkPackages = [workPackage1 as any];
  });

  it('returns a work package after the list has been initialized', (done:any) => {
    workPackageCache.state('1').values$()
      .pipe(
        take(1),
      )
      .subscribe((wp:WorkPackageResource) => {
        expect(wp.id!).toEqual('1');
        done();
      });

    workPackageCache.updateWorkPackageList(dummyWorkPackages);
  });

  it('should return/stream a work package every time it gets updated', (done:any) => {
    let count = 0;

    workPackageCache.state('1').values$()
      .pipe(
        takeWhile((wp) => count < 2),
      )
      .subscribe((wp:WorkPackageResource) => {
        expect(wp.id!).toEqual('1');

        count += 1;
        if (count === 2) {
          done();
        }
      });

    workPackageCache.updateWorkPackageList([dummyWorkPackages[0]], false);
    workPackageCache.updateWorkPackageList([dummyWorkPackages[0]], false);
    workPackageCache.updateWorkPackageList([dummyWorkPackages[0]], false);
  });

  describe('partial work packages (full covers partial)', () => {
    const makeWp = (id:string):WorkPackageResource =>
      new WorkPackageResource(
        injector,
        { id, _links: { self: '' } },
        true,
        () => undefined,
        'WorkPackage',
      ) as unknown as WorkPackageResource;

    it('does not overwrite a complete cached work package with a partial one', async () => {
      const full = makeWp('10');
      const partial = makeWp('10');
      markPartialWorkPackage(partial);

      await workPackageCache.updateWorkPackage(full, true);

      expect(workPackageCache.state('10').value).toBe(full);

      // A board reload tries to write the stripped `select` payload back.
      const result = await workPackageCache.updateWorkPackage(partial, true);

      // The complete resource is retained and returned.
      expect(result).toBe(full);
      expect(workPackageCache.state('10').value).toBe(full);
      expect(isPartialWorkPackage(workPackageCache.state('10').value)).toBe(false);
    });

    it('caches a partial work package when the slot is empty', async () => {
      const partial = makeWp('11');
      markPartialWorkPackage(partial);

      await workPackageCache.updateWorkPackage(partial, true);

      expect(workPackageCache.state('11').value).toBe(partial);
    });

    it('replaces a cached partial with a newer partial', async () => {
      const partial1 = makeWp('12');
      const partial2 = makeWp('12');
      markPartialWorkPackage(partial1);
      markPartialWorkPackage(partial2);

      await workPackageCache.updateWorkPackage(partial1, true);
      await workPackageCache.updateWorkPackage(partial2, true);

      expect(workPackageCache.state('12').value).toBe(partial2);
    });

    it('lets a fresh complete work package supersede a cached partial', async () => {
      const partial = makeWp('13');
      markPartialWorkPackage(partial);
      const full = makeWp('13');

      await workPackageCache.updateWorkPackage(partial, true);
      await workPackageCache.updateWorkPackage(full, true);

      expect(workPackageCache.state('13').value).toBe(full);
    });
  });
});
