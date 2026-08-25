import { of } from 'rxjs';
import { OpAutocompleterService } from './op-autocompleter.service';
import { ApiV3Service } from 'core-app/core/apiv3/api-v3.service';
import { HalResourceService } from 'core-app/features/hal/services/hal-resource.service';
import { TOpAutocompleterResource } from 'core-app/shared/components/autocompleter/op-autocompleter/typings';

// createParams is protected; expose it for this one internal-contract assertion rather
// than reimplementing OpAutocompleterService's public entry points (loadAvailable/
// loadFromUrl) just to observe the params they build.
interface OpAutocompleterServiceWithCreateParams {
  createParams(resource:TOpAutocompleterResource):Record<string, string>;
}

describe('OpAutocompleterService', () => {
  let service:OpAutocompleterService;
  let halResourceService:{ get:jasmine.Spy };

  beforeEach(() => {
    halResourceService = { get: jasmine.createSpy('get').and.returnValue(of({ elements: [] })) };
    service = new OpAutocompleterService(
      {} as ApiV3Service,
      halResourceService as unknown as HalResourceService,
    );
  });

  describe('createParams', () => {
    it("includes 'elements/self' in the select for work_packages", () => {
      // Regression test: without elements/self, every option's _links.self defaults to
      // { href: null } (see hal-resource-builder.ts), which breaks compareByHref
      // (tracking-functions.ts) and causes a 500 on save via
      // QueryFilterInstanceRepresenter#set_link_values when the picked value's href is nil.
      const params = (service as unknown as OpAutocompleterServiceWithCreateParams).createParams('work_packages');

      expect(params.select).toContain('elements/self');
    });
  });

  describe('loadFromUrl', () => {
    it('uses the resource defaults when the caller supplies no params', () => {
      service.loadFromUrl('/api/v3/work_packages', 'epi', 'work_packages', [], 'typeahead').subscribe();

      const requested = new URL(halResourceService.get.calls.mostRecent().args[0] as string, 'http://localhost');

      expect(requested.searchParams.get('select')).toContain('elements/author');
      expect(requested.searchParams.get('pageSize')).toBeNull();
    });

    it('lets the caller replace the resource defaults', () => {
      // The filter value pickers need a leaner select and their own page size;
      // see FilterSearchableMultiselectValueComponent.
      service
        .loadFromUrl('/api/v3/work_packages', 'epi', 'work_packages', [], 'typeahead', true, {
          select: 'elements/id,elements/self,elements/subject',
          pageSize: '100',
        })
        .subscribe();

      const requested = new URL(halResourceService.get.calls.mostRecent().args[0] as string, 'http://localhost');

      expect(requested.searchParams.get('select')).toEqual('elements/id,elements/self,elements/subject');
      expect(requested.searchParams.get('pageSize')).toEqual('100');
      expect(requested.searchParams.get('sortBy')).toBeNull();
    });
  });
});
