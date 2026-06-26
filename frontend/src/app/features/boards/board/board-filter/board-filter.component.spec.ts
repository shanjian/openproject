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
