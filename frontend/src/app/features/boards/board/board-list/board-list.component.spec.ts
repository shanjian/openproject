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

describe('BoardListComponent include-closed filtering', () => {
  const buildComponent = (options:Record<string, unknown>):BoardListComponent => {
    const component = Object.create(BoardListComponent.prototype) as BoardListComponent;
    const fields = component as unknown as Record<string, unknown>;
    fields.board = { actionAttribute: 'version' };
    fields.resource = { options };
    return component;
  };

  const filtersFor = (component:BoardListComponent):string => {
    (component as unknown as { setQueryProps:(f:unknown[]) => void }).setQueryProps([]);
    return (component as unknown as { columnsQueryProps:{ filters:string } }).columnsQueryProps.filters;
  };

  it('carries the column filters (incl. an open-status filter) into the query props', () => {
    const filters = filtersFor(buildComponent({
      queryId: 1,
      filters: [{ status: { operator: 'o', values: [] } }],
    }));

    expect(filters).toContain('"status":{"operator":"o"');
  });

  it('does not restrict status when no open-status filter is configured', () => {
    const filters = filtersFor(buildComponent({ queryId: 1, filters: [] }));

    expect(filters).not.toContain('"operator":"o"');
  });

  it('derives includeClosed from the presence of the open-status filter', () => {
    const excluded = buildComponent({ filters: [{ status: { operator: 'o', values: [] } }] });
    const included = buildComponent({ filters: [{ assignee: { operator: '!*', values: [] } }] });

    expect(excluded.includeClosed).toBe(false);
    expect(included.includeClosed).toBe(true);
  });
});

describe('BoardListComponent load more', () => {
  const buildComponent = (query:unknown):BoardListComponent => {
    const component = Object.create(BoardListComponent.prototype) as BoardListComponent;
    const fields = component as unknown as Record<string, unknown>;
    fields.apiv3Service = { queries: { find: () => of(query) } };
    fields.wpStatesInitialization = { updateQuerySpace: () => undefined };
    fields.cdRef = { markForCheck: () => undefined, detectChanges: () => undefined };
    fields.halNotification = { retrieveErrorMessage: () => '' };
    fields.resource = { options: { queryId: 1, filters: [] } };
    fields.board = { actionAttribute: 'status' };
    fields.boardFilters = { current: [] };
    // Object.create skips the constructor, so seed the field the initializer would set.
    fields.currentPageSize = 250;
    return component;
  };

  const loadQuery = (component:BoardListComponent):void =>
    (component as unknown as { loadQuery:(visibly?:boolean) => void }).loadQuery(false);

  const pageSizeOf = (component:BoardListComponent):number =>
    (component as unknown as { columnsQueryProps:{ pageSize:number } }).columnsQueryProps.pageSize;

  // The SQL projection only emits selected properties; the board selects `total`
  // but not `count`, so loaded count must come from the `elements` array length.
  const results = (loaded:number, total:number):unknown =>
    ({
      results: {
        elements: Array.from({ length: loaded }, (_, i) => ({ id: String(i) } as WorkPackageResource)),
        total,
      },
    });

  it('captures loaded/total counts from elements length and reports truncation', () => {
    const component = buildComponent(results(250, 1341));

    loadQuery(component);

    expect(component.loadedCount).toBe(250);
    expect(component.totalCount).toBe(1341);
    expect(component.hasMoreCards).toBe(true);
  });

  it('reports no more cards when the loaded elements already cover the total', () => {
    const component = buildComponent(results(12, 12));

    loadQuery(component);

    expect(component.hasMoreCards).toBe(false);
  });

  it('grows the page size by the increment and reloads when loading more', () => {
    const component = buildComponent(results(250, 1341));
    loadQuery(component);

    component.loadMoreCards();

    expect(pageSizeOf(component)).toBe(500);
  });

  it('grows from the actually-loaded count when the server returned more than requested', () => {
    // forced_single_page_size > our initial 250: the backend clamps up, so the
    // first load already returned 500. The next request must exceed 500, not
    // re-request 500 (which would load nothing).
    const component = buildComponent(results(500, 1341));
    loadQuery(component);

    component.loadMoreCards();

    expect(pageSizeOf(component)).toBe(750); // max(250, 500) + 250
  });

  it('does not request more when the column is not truncated', () => {
    const component = buildComponent(results(12, 12));
    loadQuery(component);

    const findSpy = jasmine.createSpy('find').and.returnValue(of(results(12, 12)));
    (component as unknown as Record<string, unknown>).apiv3Service = { queries: { find: findSpy } };

    component.loadMoreCards();

    expect(findSpy).not.toHaveBeenCalled();
  });
});
