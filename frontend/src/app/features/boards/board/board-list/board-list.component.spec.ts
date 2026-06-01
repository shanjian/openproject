import { of } from 'rxjs';
import { WorkPackageResource } from 'core-app/features/hal/resources/work-package-resource';
import { isPartialWorkPackage } from 'core-app/features/hal/helpers/partial-work-package';
import { BoardListComponent } from './board-list.component';

describe('BoardListComponent partial caching', () => {
  const wp = (id:string):WorkPackageResource => ({ id } as WorkPackageResource);

  it('marks the loaded (select-payload) work packages as partial before caching them', () => {
    const elements = [wp('1'), wp('2')];
    const query = { results: { elements } };
    const updateQuerySpace = jasmine.createSpy('updateQuerySpace');

    // Construct without the (large) DI constructor; we only exercise loadQuery.
    const component = Object.create(BoardListComponent.prototype) as BoardListComponent;
    const fields = component as unknown as Record<string, unknown>;
    fields.apiv3Service = { queries: { find: () => of(query) } };
    fields.wpStatesInitialization = { updateQuerySpace };
    fields.cdRef = { markForCheck: () => undefined };
    fields.resource = { options: { queryId: 1 } };
    fields.columnsQueryProps = {};

    // visibly=false skips the loading-indicator wrapping; of(query) emits synchronously.
    (component as unknown as { loadQuery:(visibly?:boolean) => void }).loadQuery(false);

    expect(isPartialWorkPackage(elements[0])).toBe(true);
    expect(isPartialWorkPackage(elements[1])).toBe(true);
    expect(updateQuerySpace).toHaveBeenCalledWith(query, query.results);
  });
});
