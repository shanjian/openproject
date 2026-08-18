import { ComponentFixture, TestBed } from '@angular/core/testing';
import { FormsModule } from '@angular/forms';
import { of, throwError } from 'rxjs';
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
      imports: [FormsModule],
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

  function configureWithError() {
    TestBed.configureTestingModule({
      declarations: [OkrBoardFilterComponent],
      imports: [FormsModule],
      providers: [
        {
          provide: ApiV3Service,
          useValue: {
            collectionFromString: () => ({
              filtered: () => ({
                get: () => throwError(() => new Error('boom')),
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

  it('logs and keeps the empty state when loading the units fails', () => {
    configureWithError();
    spyOn(console, 'error');

    expect(() => component.ngOnInit()).not.toThrow();

    expect(component.topLevelUnits).toEqual([]);
    expect(component.childrenOf('1')).toEqual([]);
    expect(console.error).toHaveBeenCalled();
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
      imports: [FormsModule],
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

describe('OkrBoardFilterComponent - scope computation', () => {
  let fixture:ComponentFixture<OkrBoardFilterComponent>;
  let component:OkrBoardFilterComponent;
  let replaceSpy:jasmine.Spy;

  beforeEach(() => {
    TestBed.configureTestingModule({
      declarations: [OkrBoardFilterComponent],
      imports: [FormsModule],
      providers: [
        { provide: ApiV3Service, useValue: {} },
        {
          provide: WorkPackageViewFiltersService,
          useValue: { replace: () => undefined, remove: () => undefined, instantiate: () => ({}) },
        },
      ],
    });
    fixture = TestBed.createComponent(OkrBoardFilterComponent);
    component = fixture.componentInstance;
    component.departmentFilterName = 'cf_42';
    replaceSpy = spyOn(component.wpTableFilters, 'replace');
  });

  it('computes "just this unit" as [unit.id]', () => {
    component.selectedUnitId = '1';
    component.selectedScope = 'self';

    expect(component.scopeValues('1', 'self')).toEqual(['1']);
  });

  it('computes "everything above" as a no-op for a top-level unit', () => {
    expect(component.scopeValues('1', 'ancestors')).toEqual(['1']);
  });

  it('computes "one level down" from the children index', () => {
    spyOn(component, 'childrenOf').and.returnValue(['2', '3']);

    expect(component.scopeValues('1', 'children').sort()).toEqual(['1', '2', '3']);
  });

  it('writes the computed values into the department filter on unit change', () => {
    component.onUnitChange('1');

    expect(replaceSpy).toHaveBeenCalled();
    const [id, modifier] = replaceSpy.calls.mostRecent().args as [
      string,
      (f:{ operator:string, values:string[], findOperator:(id:string) => string }) => void,
    ];

    expect(id).toBe('cf_42');
    const filter = { operator: '', values: [] as string[], findOperator: (operatorId:string) => operatorId };
    modifier(filter);

    expect(filter.operator).toBe('=');
    expect(filter.values).toEqual(['1']);
  });
});

describe('OkrBoardFilterComponent - version quick filter', () => {
  let fixture:ComponentFixture<OkrBoardFilterComponent>;
  let component:OkrBoardFilterComponent;
  let replaceSpy:jasmine.Spy;
  let removeSpy:jasmine.Spy;

  beforeEach(() => {
    TestBed.configureTestingModule({
      declarations: [OkrBoardFilterComponent],
      imports: [FormsModule],
      providers: [
        {
          provide: ApiV3Service,
          useValue: {
            collectionFromString: () => ({
              filtered: () => ({
                get: () => of({ _embedded: { elements: [{ id: '5', name: '2026 Q3' }] }, count: 1, total: 1 }),
              }),
            }),
          },
        },
        {
          provide: WorkPackageViewFiltersService,
          useValue: {
            // The real QueryFilterInstanceResource exposes the schema's allowedValues via
            // #currentSchema (see query-filter-instance-resource.ts), not a plain #schema
            // property - mirror that shape here rather than the non-existent one.
            instantiate: () => ({ currentSchema: { values: { allowedValues: { href: '/api/v3/versions' } } } }),
            replace: () => undefined,
            remove: () => undefined,
          },
        },
      ],
    });
    fixture = TestBed.createComponent(OkrBoardFilterComponent);
    component = fixture.componentInstance;
    replaceSpy = spyOn(component.wpTableFilters, 'replace');
    removeSpy = spyOn(component.wpTableFilters, 'remove');
  });

  it('loads versions from the version filter\'s own allowedValues link', async () => {
    await component.loadVersions();

    expect(component.versions.map((v) => v.id)).toEqual(['5']);
  });

  it('writes the selected version into the version_id filter', () => {
    component.onVersionChange('5');

    expect(replaceSpy).toHaveBeenCalledWith('version', jasmine.any(Function));
  });

  it('clears the version filter when "all versions" is selected', () => {
    component.onVersionChange(null);

    expect(removeSpy).toHaveBeenCalledWith('version');
  });
});

describe('OkrBoardFilterComponent - version quick filter error handling', () => {
  let fixture:ComponentFixture<OkrBoardFilterComponent>;
  let component:OkrBoardFilterComponent;

  beforeEach(() => {
    TestBed.configureTestingModule({
      declarations: [OkrBoardFilterComponent],
      imports: [FormsModule],
      providers: [
        {
          provide: ApiV3Service,
          useValue: {
            collectionFromString: () => ({
              filtered: () => ({
                get: () => throwError(() => new Error('boom')),
              }),
            }),
          },
        },
        {
          provide: WorkPackageViewFiltersService,
          useValue: {
            instantiate: () => ({ currentSchema: { values: { allowedValues: { href: '/api/v3/versions' } } } }),
          },
        },
      ],
    });
    fixture = TestBed.createComponent(OkrBoardFilterComponent);
    component = fixture.componentInstance;
  });

  it('logs and keeps the empty state when loading the versions fails', async () => {
    spyOn(console, 'error');

    await expectAsync(component.loadVersions()).toBeResolved();

    expect(component.versions).toEqual([]);
    expect(console.error).toHaveBeenCalled();
  });
});
