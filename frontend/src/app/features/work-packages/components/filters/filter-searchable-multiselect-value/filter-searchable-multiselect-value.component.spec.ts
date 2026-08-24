import { ComponentFixture, TestBed } from '@angular/core/testing';
import { NO_ERRORS_SCHEMA } from '@angular/core';
import { of } from 'rxjs';
import { FilterSearchableMultiselectValueComponent } from './filter-searchable-multiselect-value.component';
import { HalResourceService } from 'core-app/features/hal/services/hal-resource.service';
import { ApiV3Service } from 'core-app/core/apiv3/api-v3.service';
import { I18nService } from 'core-app/core/i18n/i18n.service';
import { CurrentProjectService } from 'core-app/core/current-project/current-project.service';
import { CurrentUserService } from 'core-app/core/current-user/current-user.service';
import { HalResourceNotificationService } from 'core-app/features/hal/services/hal-resource-notification.service';
import { QueryFilterInstanceResource } from 'core-app/features/hal/resources/query-filter-instance-resource';

describe('FilterSearchableMultiselectValueComponent', () => {
  let fixture:ComponentFixture<FilterSearchableMultiselectValueComponent>;
  let component:FilterSearchableMultiselectValueComponent;

  function filterWithType(type:string, href = '/api/v3/work_packages?filters=%5B%5D'):QueryFilterInstanceResource {
    return {
      id: 'epic',
      values: [],
      currentSchema: {
        values: {
          type,
          allowedValues: { href },
        },
      },
    } as unknown as QueryFilterInstanceResource;
  }

  beforeEach(() => {
    TestBed.configureTestingModule({
      declarations: [FilterSearchableMultiselectValueComponent],
      schemas: [NO_ERRORS_SCHEMA],
      providers: [
        { provide: HalResourceService, useValue: { createHalResource: () => ({}) } },
        {
          provide: ApiV3Service,
          useValue: {
            users: {
              me: {
                path: '/api/v3/users/me',
              },
            },
            collectionFromString: () => ({
              filtered: () => ({
                get: () => of({ elements: [], count: 0, total: 0 }),
              }),
            }),
          },
        },
        { provide: I18nService, useValue: { t: (key:string) => key } },
        { provide: CurrentProjectService, useValue: {} },
        { provide: CurrentUserService, useValue: { isLoggedIn$: of(false), user$: of(null) } },
        { provide: HalResourceNotificationService, useValue: {} },
      ],
    });

    fixture = TestBed.createComponent(FilterSearchableMultiselectValueComponent);
    component = fixture.componentInstance;
  });

  describe('resourceType detection', () => {
    it('resolves to "work_packages" for a []WorkPackage-typed filter (Epic, Parent, Blocks, ...)', () => {
      component.filter = filterWithType('[]WorkPackage');
      component.ngOnInit();

      expect(component.resourceType).toBe('work_packages');
    });

    it('stays null for a []Version-typed filter', () => {
      component.filter = filterWithType('[]Version');
      component.ngOnInit();

      expect(component.resourceType).toBeNull();
    });

    it('stays null for a []User-typed filter', () => {
      component.filter = filterWithType('[]User');
      component.ngOnInit();

      expect(component.resourceType).toBeNull();
    });
  });
});
