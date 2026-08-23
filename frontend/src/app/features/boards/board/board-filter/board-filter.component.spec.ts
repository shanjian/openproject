import { of } from 'rxjs';
import { HalResource } from 'core-app/features/hal/resources/hal-resource';
import { BoardFilterComponent } from './board-filter.component';

interface TestOption {
  identifier?:string;
  label:string;
  key:string;
}

describe('BoardFilterComponent assignee quick filter ordering', () => {
  const principal = (id:string, name:string, type:'User'|'Group' = 'User'):HalResource =>
    ({ id, name, _type: type } as unknown as HalResource);

  // assigneeFilterOptions only uses pure prototype helpers, so we can exercise
  // it without the (large) DI constructor.
  const orderOptions = (assignees:HalResource[], currentUserId:string|null):TestOption[] => {
    const component = Object.create(BoardFilterComponent.prototype) as BoardFilterComponent;
    return (component as unknown as {
      assigneeFilterOptions(a:HalResource[], id:string|null):TestOption[];
    }).assigneeFilterOptions(assignees, currentUserId);
  };

  it('pins the current user to the top, keeping the order of the rest', () => {
    const assignees = [
      principal('8', 'Aaron'),
      principal('154', 'Shanjian'),
      principal('33', 'Bin'),
    ];

    const labels = orderOptions(assignees, '154').map((option) => option.label);

    expect(labels).toEqual(['Shanjian', 'Aaron', 'Bin']);
  });

  it('keeps the current user first when already at the top', () => {
    const assignees = [principal('154', 'Shanjian'), principal('8', 'Aaron')];

    const labels = orderOptions(assignees, '154').map((option) => option.label);

    expect(labels).toEqual(['Shanjian', 'Aaron']);
  });

  it('leaves the order unchanged when no current user is known', () => {
    const assignees = [principal('8', 'Aaron'), principal('33', 'Bin')];

    const labels = orderOptions(assignees, null).map((option) => option.label);

    expect(labels).toEqual(['Aaron', 'Bin']);
  });

  it('leaves the order unchanged when the current user is not assignable', () => {
    const assignees = [principal('8', 'Aaron'), principal('33', 'Bin')];

    const labels = orderOptions(assignees, '999').map((option) => option.label);

    expect(labels).toEqual(['Aaron', 'Bin']);
  });

  it('excludes groups and other non-user principals', () => {
    const assignees = [principal('8', 'Aaron'), principal('241', 'all_users', 'Group')];

    const identifiers = orderOptions(assignees, null).map((option) => option.identifier);

    expect(identifiers).toEqual(['8']);
  });
});

describe('BoardFilterComponent#initializeQuickFilters', () => {
  // The options load after an awaited HAL request that resolves outside Angular's
  // change detection, under OnPush ancestors that would otherwise skip a re-render
  // (regression: PRs #74/#75, "board quick filters not rendering"/"detect changes").
  // Exercised directly on the prototype (as above) to avoid the large DI constructor.
  const buildComponent = (assignees:HalResource[], versions:HalResource[]) => {
    const detectChanges = jasmine.createSpy('detectChanges');
    const component = Object.create(BoardFilterComponent.prototype) as BoardFilterComponent;
    Object.assign(component, {
      text: {
        assignee_all: 'All assignees',
        assignee_unassigned: 'Unassigned',
        version_all: 'All versions',
        version_none: 'No version',
      },
      componentDestroyed: false,
      boardActions: {
        get: (key:string) => ({
          loadAvailable: () => of(key === 'assignee' ? assignees : versions),
        }),
      },
      currentUserService: { user$: of({ id: '1' }) },
      syncQuickFilterSelections: () => undefined,
      cdRef: { detectChanges },
    });
    return { component, detectChanges };
  };

  const principal = (id:string, name:string):HalResource => ({ id, name, _type: 'User' } as unknown as HalResource);

  it('triggers change detection after the loaded options are applied', async () => {
    const { component, detectChanges } = buildComponent([principal('8', 'Aaron')], [principal('12', 'Sprint 1')]);

    await (component as unknown as { initializeQuickFilters():Promise<void> }).initializeQuickFilters();

    expect(component.assigneeOptions.map((o) => o.label)).toEqual(['All assignees', 'Unassigned', 'Aaron']);
    expect(component.versionOptions.map((o) => o.label)).toEqual(['All versions', 'No version', 'Sprint 1']);
    expect(detectChanges).toHaveBeenCalledTimes(1);
  });

  it('does not touch change detection once the component has been destroyed', async () => {
    const { component, detectChanges } = buildComponent([principal('8', 'Aaron')], []);
    component.componentDestroyed = true;

    await (component as unknown as { initializeQuickFilters():Promise<void> }).initializeQuickFilters();

    expect(detectChanges).not.toHaveBeenCalled();
  });
});
