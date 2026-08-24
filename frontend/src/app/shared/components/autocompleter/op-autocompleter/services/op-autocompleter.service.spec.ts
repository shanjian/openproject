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

  beforeEach(() => {
    // Neither dependency is exercised by createParams itself; minimal stand-ins are enough.
    service = new OpAutocompleterService(
      {} as ApiV3Service,
      {} as HalResourceService,
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
});
