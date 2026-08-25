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
import { MAGIC_FILTER_AUTOCOMPLETE_PAGE_SIZE } from 'core-app/core/apiv3/helpers/get-paginated-results';

describe('FilterSearchableMultiselectValueComponent', () => {
  let fixture:ComponentFixture<FilterSearchableMultiselectValueComponent>;
  let component:FilterSearchableMultiselectValueComponent;

  function filterWithType(type:string, href = '/api/v3/work_packages?filters=%5B%5D', id = 'epic'):QueryFilterInstanceResource {
    return {
      id,
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
    it('resolves to "work_packages" for the id filter, whose options are identified by their id', () => {
      component.filter = filterWithType('[]WorkPackage', undefined, 'id');
      component.ngOnInit();

      expect(component.resourceType).toBe('work_packages');
    });

    it('stays null for the other []WorkPackage-typed filters (Epic, Parent, Blocks, ...)', () => {
      // Their options are named by their subject alone; op-autocompleter's work package
      // template would add a type badge, project, #id and status around it.
      component.filter = filterWithType('[]WorkPackage');
      component.ngOnInit();

      expect(component.resourceType).toBeNull();
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

  describe('autocompleterFn', () => {
    it('delegates to OpAutocompleterService.loadFromUrl for a work-package-backed filter', () => {
      const href = '/api/v3/work_packages?filters=%5B%7B%22type%22%3A%7B%22operator%22%3A%22%3D%22%2C%22values%22%3A%5B%221%22%5D%7D%7D%5D';
      component.filter = filterWithType('[]WorkPackage', href);
      component.ngOnInit();
      const loadFromUrlSpy = spyOn(component.opAutocompleterService, 'loadFromUrl').and.returnValue(of([]));

      component.autocompleterFn('epi').subscribe();

      expect(loadFromUrlSpy).toHaveBeenCalledWith(
        href,
        'epi',
        'work_packages',
        [],
        'typeahead',
        true,
        component.workPackageParams,
      );
      // Guards that the old, heavy loadCollection('') load can never fire for
      // work-package-backed filters: initialRequest$ must stay unset in this branch.
      expect(component.initialRequest$).toBeUndefined();
    });

    it('asks for the same number of candidates the picker offered before it used the service', () => {
      // Regression: OpAutocompleterService sets no pageSize, so the endpoint fell back to
      // Setting.per_page_options_array.min (20) and the dropdown lost 80% of its options.
      component.filter = filterWithType('[]WorkPackage');
      component.ngOnInit();

      expect(component.workPackageParams.pageSize).toEqual(`${MAGIC_FILTER_AUTOCOMPLETE_PAGE_SIZE}`);
    });

    it('does not request the author, whose avatar the option template would then render', () => {
      // The shared work_packages select feeds op-autocompleter's <op-principal> avatar.
      // A filter value picker has no use for "who created this work package".
      component.filter = filterWithType('[]WorkPackage');
      component.ngOnInit();

      expect(component.workPackageParams.select).not.toContain('elements/author');
      // ... but elements/self must stay: compareByHref and saving the query both need it,
      // and its title is what the plain option template renders as the item's name.
      expect(component.workPackageParams.select).toContain('elements/self');
    });

    it('requests nothing beyond the subject for a filter that only renders the subject', () => {
      component.filter = filterWithType('[]WorkPackage');
      component.ngOnInit();

      expect(component.workPackageParams.select).toEqual('elements/id,elements/self,elements/subject');
    });

    it('still requests what the id filter\'s richer option template renders', () => {
      component.filter = filterWithType('[]WorkPackage', undefined, 'id');
      component.ngOnInit();

      expect(component.workPackageParams.select).toContain('elements/type');
      expect(component.workPackageParams.select).toContain('elements/project');
      expect(component.workPackageParams.select).toContain('elements/status');
    });

    it('falls back to the existing HAL-collection autocomplete for a non-work-package filter', (done) => {
      component.filter = filterWithType('[]Version');
      component.ngOnInit();

      component.autocompleterFn('').subscribe((result) => {
        expect(result).toEqual([]);
        done();
      });
    });
  });
});
