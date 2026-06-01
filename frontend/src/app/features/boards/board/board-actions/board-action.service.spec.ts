import { Observable, of } from 'rxjs';
import { WorkPackageResource } from 'core-app/features/hal/resources/work-package-resource';
import { HalResource } from 'core-app/features/hal/resources/hal-resource';
import { BoardActionService } from './board-action.service';

class TestBoardActionService extends BoardActionService {
  localizedName = 'Status';

  filterName = 'status';

  resourceName = 'status';

  icon = '';

  protected require():Promise<HalResource> {
    return Promise.resolve({} as HalResource);
  }

  protected loadValues():Observable<HalResource[]> {
    return of([]);
  }
}

describe('BoardActionService#canMove', () => {
  const wp = { id: '1' } as WorkPackageResource;

  const build = (schemaCache:unknown):BoardActionService =>
    new TestBoardActionService(
      {} as never, {} as never, {} as never, {} as never,
      {} as never, {} as never, {} as never, schemaCache as never,
    );

  it('allows the move when the schema is not loaded (lightweight board payload)', () => {
    const service = build({ getSchemaHref: () => undefined });

    expect(service.canMove(wp)).toBe(true);
  });

  it('respects a loaded schema: writable attribute is movable', () => {
    const service = build({
      getSchemaHref: () => '/schema',
      state: () => ({ hasValue: () => true }),
      of: () => ({ status: { writable: true } }),
    });

    expect(service.canMove(wp)).toBe(true);
  });

  it('respects a loaded schema: non-writable attribute is not movable', () => {
    const service = build({
      getSchemaHref: () => '/schema',
      state: () => ({ hasValue: () => true }),
      of: () => ({ status: { writable: false } }),
    });

    expect(service.canMove(wp)).toBe(false);
  });
});
