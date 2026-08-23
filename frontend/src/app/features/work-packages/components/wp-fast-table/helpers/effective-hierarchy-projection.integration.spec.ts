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

import { TestBed, waitForAsync } from '@angular/core/testing';
import { Injector } from '@angular/core';
import { of } from 'rxjs';
import { provideHttpClient, withInterceptorsFromDi } from '@angular/common/http';
import { provideHttpClientTesting } from '@angular/common/http/testing';
import { StateService } from '@uirouter/core';
import { HalResourceService } from 'core-app/features/hal/services/hal-resource.service';
import { HalResourceNotificationService } from 'core-app/features/hal/services/hal-resource-notification.service';
import { OpenprojectHalModule } from 'core-app/features/hal/openproject-hal.module';
import { WorkPackageResource } from 'core-app/features/hal/resources/work-package-resource';
import { States } from 'core-app/core/states/states.service';
import { TimezoneService } from 'core-app/core/datetime/timezone.service';
import { ConfigurationService } from 'core-app/core/config/configuration.service';
import { LoadingIndicatorService } from 'core-app/core/loading-indicator/loading-indicator.service';
import { PathHelperService } from 'core-app/core/path-helper/path-helper.service';
import { I18nService } from 'core-app/core/i18n/i18n.service';
import { ApiV3Service } from 'core-app/core/apiv3/api-v3.service';
import { SchemaCacheService } from 'core-app/core/schemas/schema-cache.service';
import { WeekdayService } from 'core-app/core/days/weekday.service';
import { WorkPackageCreateService } from 'core-app/features/work-packages/components/wp-new/wp-create.service';
import { WorkPackageNotificationService } from 'core-app/features/work-packages/services/notifications/work-package-notification.service';
import { WorkPackagesActivityService } from 'core-app/features/work-packages/components/wp-single-view-tabs/activity-panel/wp-activity.service';
import { EffectiveHierarchyProjection } from './effective-hierarchy-projection';

// The unit specs feed the projection plain objects. This one feeds it real
// WorkPackageResources built from the payload the API actually returns, so the
// two properties the rule depends on -- the hasParent property and the epic link
// -- are proven readable through the HAL machinery rather than assumed.
describe('EffectiveHierarchyProjection with real HAL resources', () => {
  let halResourceService:HalResourceService;

  const WeekdayServiceStub = { loadWeekdays: () => of(true) };

  beforeEach(waitForAsync(() => {
    void TestBed.configureTestingModule({
      imports: [OpenprojectHalModule],
      providers: [
        HalResourceService,
        States,
        TimezoneService,
        WorkPackagesActivityService,
        { provide: WeekdayService, useValue: WeekdayServiceStub },
        ConfigurationService,
        LoadingIndicatorService,
        PathHelperService,
        I18nService,
        ApiV3Service,
        { provide: HalResourceNotificationService, useValue: { handleRawError: () => false } },
        { provide: WorkPackageNotificationService, useValue: {} },
        { provide: WorkPackageCreateService, useValue: {} },
        { provide: StateService, useValue: {} },
        { provide: SchemaCacheService, useValue: {} },
        provideHttpClient(withInterceptorsFromDi()),
        provideHttpClientTesting(),
      ],
    })
      .compileComponents()
      .then(() => {
        halResourceService = TestBed.inject(HalResourceService);
        TestBed.inject(Injector);
        halResourceService.registerResource('WorkPackage', { cls: WorkPackageResource });
      });
  }));

  interface PayloadOptions {
    hasParent:boolean;
    epicId?:number;
    parentId?:number;
    startDate?:string;
    dueDate?:string;
  }

  // Shaped exactly like an element of the work package collection: hasParent as
  // a plain property, parent and epic as links that are null when unset.
  function resourceFrom(id:number, options:PayloadOptions):WorkPackageResource {
    const source = {
      _type: 'WorkPackage',
      id,
      subject: `WP ${id}`,
      hasParent: options.hasParent,
      startDate: options.startDate ?? null,
      dueDate: options.dueDate ?? null,
      _links: {
        self: { href: `/api/v3/work_packages/${id}` },
        parent: options.parentId
          ? { href: `/api/v3/work_packages/${options.parentId}`, title: `WP ${options.parentId}` }
          : { href: null },
        epic: options.epicId
          ? { href: `/api/v3/work_packages/${options.epicId}`, title: `WP ${options.epicId}` }
          : { href: null },
      },
    };

    return halResourceService.createHalResourceOfType<WorkPackageResource>('WorkPackage', source);
  }

  it('reads hasParent off the resource', () => {
    expect(resourceFrom(1, { hasParent: false }).hasParent).toBe(false);
    expect(resourceFrom(2, { hasParent: true, parentId: 1 }).hasParent).toBe(true);
  });

  it('reads the epic id off the epic link', () => {
    const task = resourceFrom(2, { hasParent: false, epicId: 1 });

    expect(task.epic).toBeTruthy();
    expect(task.epic!.id).toEqual('1');
  });

  it('leaves the epic empty when the link has no href', () => {
    const task = resourceFrom(2, { hasParent: false });

    expect(task.epic?.id ?? null).toBeNull();
  });

  it('adopts a parentless linked work package under its epic', () => {
    const epic = resourceFrom(1, { hasParent: false });
    const task = resourceFrom(2, { hasParent: false, epicId: 1 });
    const projection = new EffectiveHierarchyProjection([epic, task]);

    expect(projection.isAdopted(task)).toBe(true);
    expect(projection.ancestorsOf(task).map((wp) => wp.id)).toEqual(['1']);
  });

  it('does not adopt a work package whose parent is invisible', () => {
    const epic = resourceFrom(1, { hasParent: false });
    // A real but invisible parent: hasParent is true while the link stays empty.
    const task = resourceFrom(2, { hasParent: true, epicId: 1 });
    const projection = new EffectiveHierarchyProjection([epic, task]);

    expect(task.parent).toBeFalsy();
    expect(projection.isAdopted(task)).toBe(false);
  });

  it('spans the linked children for the epic bar', () => {
    const epic = resourceFrom(1, { hasParent: false });
    const early = resourceFrom(2, {
      hasParent: false, epicId: 1, startDate: '2026-03-02', dueDate: '2026-03-20',
    });
    const late = resourceFrom(3, {
      hasParent: false, epicId: 1, startDate: '2026-04-01', dueDate: '2026-04-10',
    });
    const projection = new EffectiveHierarchyProjection([epic, early, late]);

    expect(projection.linkedChildrenEnvelopeOf(epic))
      .toEqual({ start: '2026-03-02', due: '2026-04-10' });
  });
});
