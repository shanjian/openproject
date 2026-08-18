import { ComponentFixture, TestBed } from '@angular/core/testing';
import { of } from 'rxjs';
import { OkrBoardFilterComponent } from './okr-board-filter.component';
import { ApiV3Service } from 'core-app/core/apiv3/api-v3.service';
import {
  WorkPackageViewFiltersService,
} from 'core-app/features/work-packages/routing/wp-view-base/view-services/wp-view-filters.service';
import { HalResource } from 'core-app/features/hal/resources/hal-resource';

function group(id:string, name:string, parentId:string|null) {
  return {
    id,
    name,
    parent: parentId ? { id: parentId } : null,
  } as unknown as HalResource;
}

describe('OkrBoardFilterComponent - organizational unit loading', () => {
  let fixture:ComponentFixture<OkrBoardFilterComponent>;
  let component:OkrBoardFilterComponent;

  function configure(elements:HalResource[]) {
    TestBed.configureTestingModule({
      declarations: [OkrBoardFilterComponent],
      providers: [
        {
          provide: ApiV3Service,
          useValue: {
            collectionFromString: () => ({
              filtered: () => ({
                get: () => of({ _embedded: { elements }, count: elements.length, total: elements.length }),
              }),
            }),
          },
        },
        {
          provide: WorkPackageViewFiltersService,
          useValue: { instantiate: () => ({ currentSchema: { values: { allowedValues: { href: '/api/v3/x' } } } }) },
        },
      ],
    });
    fixture = TestBed.createComponent(OkrBoardFilterComponent);
    component = fixture.componentInstance;
  }

  it('lists only top-level units in the dropdown', () => {
    configure([
      group('1', 'Marketing', null),
      group('2', 'Growth', '1'),
      group('3', 'Product', null),
    ]);

    component.ngOnInit();

    expect(component.topLevelUnits.map((u) => u.id)).toEqual(['1', '3']);
  });

  it('builds a parent -> children index for "one level down"', () => {
    configure([
      group('1', 'Marketing', null),
      group('2', 'Growth', '1'),
      group('3', 'Audience Development', '1'),
      group('4', 'Product', null),
    ]);

    component.ngOnInit();

    expect(component.childrenOf('1').sort()).toEqual(['2', '3']);
    expect(component.childrenOf('4')).toEqual([]);
  });

  it('handles more than 100 units without truncating the index', () => {
    const units = Array.from({ length: 150 }, (_, i) => group(`${i}`, `Unit ${i}`, i === 0 ? null : '0'));
    configure(units);

    component.ngOnInit();

    expect(component.childrenOf('0').length).toBe(149);
  });
});

describe('OkrBoardFilterComponent - department filter id from bootstrap data', () => {
  let fixture:ComponentFixture<OkrBoardFilterComponent>;
  let component:OkrBoardFilterComponent;
  let bootstrapEl:HTMLDivElement;

  beforeEach(() => {
    bootstrapEl = document.createElement('div');
    bootstrapEl.id = 'okr-board-bootstrap';
    bootstrapEl.dataset.departmentFilter = 'cf_42';
    document.body.appendChild(bootstrapEl);

    TestBed.configureTestingModule({
      declarations: [OkrBoardFilterComponent],
      providers: [
        { provide: ApiV3Service, useValue: {} },
        { provide: WorkPackageViewFiltersService, useValue: { instantiate: () => ({}) } },
      ],
    });
    fixture = TestBed.createComponent(OkrBoardFilterComponent);
    component = fixture.componentInstance;
  });

  afterEach(() => {
    bootstrapEl.remove();
  });

  it('reads the qualifying custom field\'s filter id from the bootstrap element', () => {
    expect(component.readDepartmentFilterName()).toBe('cf_42');
  });
});
