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
          useValue: {
            // ngOnInit() now waits on #onReady() before instantiating any filter -- see
            // okr-board-filter.component.ts for why (the department/version filter schemas
            // aren't available until the surrounding view's query has loaded).
            onReady: () => Promise.resolve(null),
            instantiate: () => ({ currentSchema: { values: { allowedValues: { href: '/api/v3/x' } } } }),
            // loadOrganizationalUnits() now calls syncSelectionFromLiveFilter() once it
            // resolves, which needs #find; no live filter value is under test here.
            find: () => undefined,
          },
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
          useValue: {
            onReady: () => Promise.resolve(null),
            instantiate: () => ({ currentSchema: { values: { allowedValues: { href: '/api/v3/x' } } } }),
          },
        },
      ],
    });
    fixture = TestBed.createComponent(OkrBoardFilterComponent);
    component = fixture.componentInstance;
  }

  it('lists only top-level units in the dropdown', async () => {
    configure([
      group('1', 'Marketing', null),
      group('2', 'Growth', '1'),
      group('3', 'Product', null),
    ]);

    component.ngOnInit();
    await fixture.whenStable();

    expect(component.topLevelUnits.map((u) => u.id)).toEqual(['1', '3']);
  });

  it('builds a parent -> children index for "one level down"', async () => {
    configure([
      group('1', 'Marketing', null),
      group('2', 'Growth', '1'),
      group('3', 'Audience Development', '1'),
      group('4', 'Product', null),
    ]);

    component.ngOnInit();
    await fixture.whenStable();

    expect(component.childrenOf('1').sort()).toEqual(['2', '3']);
    expect(component.childrenOf('4')).toEqual([]);
  });

  it('handles more than 100 units without truncating the index', async () => {
    const units = Array.from({ length: 150 }, (_, i) => group(`${i}`, `Unit ${i}`, i === 0 ? null : '0'));
    configure(units);

    component.ngOnInit();
    await fixture.whenStable();

    expect(component.childrenOf('0').length).toBe(149);
  });

  it('logs and keeps the empty state when loading the units fails', async () => {
    configureWithError();
    spyOn(console, 'error');

    expect(() => component.ngOnInit()).not.toThrow();
    await fixture.whenStable();

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
        {
          provide: WorkPackageViewFiltersService,
          useValue: { onReady: () => Promise.resolve(null), instantiate: () => ({}) },
        },
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
          useValue: {
            onReady: () => Promise.resolve(null),
            replace: () => undefined,
            remove: () => undefined,
            instantiate: () => ({}),
          },
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
    // applyUnitFilter() resolves ids to the actual loaded HalResources (not plain ids) --
    // see its comment in okr-board-filter.component.ts for why a plain id silently
    // disappears once the filter is cloned for the URL/query_props.
    (component as unknown as { allUnits:HalResource[] }).allUnits = [group('1', 'Marketing', null)];

    component.onUnitChange('1');

    expect(replaceSpy).toHaveBeenCalled();
    const [id, modifier] = replaceSpy.calls.mostRecent().args as [
      string,
      (f:{ operator:string, values:HalResource[], findOperator:(id:string) => string }) => void,
    ];

    // departmentFilterName ("cf_42") is the backend's filter *instance* accessor;
    // replace() needs the schema id ("customField42") -- see departmentSchemaName().
    expect(id).toBe('customField42');
    const filter = { operator: '', values: [] as HalResource[], findOperator: (operatorId:string) => operatorId };
    modifier(filter);

    expect(filter.operator).toBe('=');
    expect(filter.values.map((v) => v.id)).toEqual(['1']);
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
            onReady: () => Promise.resolve(null),
            // The real QueryFilterInstanceResource exposes the schema's allowedValues via
            // #currentSchema (see query-filter-instance-resource.ts), not a plain #schema
            // property - mirror that shape here rather than the non-existent one.
            instantiate: () => ({ currentSchema: { values: { allowedValues: { href: '/api/v3/versions' } } } }),
            // ngOnInit's own loadOrganizationalUnits() call resolves via this same mocked
            // collection and then calls syncSelectionFromLiveFilter(), which needs #find;
            // no live department filter value is under test in this "version quick filter"
            // suite.
            find: () => undefined,
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
    // onVersionChange() looks up the actual loaded Version resource by id (not a plain
    // id) -- see its comment in okr-board-filter.component.ts for why.
    component.versions = [{ id: '5', name: '2026 Q3' } as unknown as HalResource];

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
            onReady: () => Promise.resolve(null),
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

describe('OkrBoardFilterComponent - stale unit fallback', () => {
  let fixture:ComponentFixture<OkrBoardFilterComponent>;
  let component:OkrBoardFilterComponent;
  let removeSpy:jasmine.Spy;

  beforeEach(() => {
    TestBed.configureTestingModule({
      declarations: [OkrBoardFilterComponent],
      providers: [
        {
          provide: ApiV3Service,
          useValue: {
            collectionFromString: () => ({
              filtered: () => ({
                get: () => of({ _embedded: { elements: [group('1', 'Marketing', null)] }, count: 1, total: 1 }),
              }),
            }),
          },
        },
        {
          provide: WorkPackageViewFiltersService,
          useValue: {
            onReady: () => Promise.resolve(null),
            // The real QueryFilterInstanceResource exposes the schema's allowedValues via
            // #currentSchema (see query-filter-instance-resource.ts), not a plain #schema
            // property - mirror that shape here rather than the non-existent one, so units
            // actually load and the "999" filter value below is a genuine mismatch against
            // the loaded set (not a mismatch caused by loading never happening at all).
            instantiate: () => ({ currentSchema: { values: { allowedValues: { href: '/api/v3/x' } } } }),
            find: () => ({ values: ['999'] }),
            remove: () => {},
            replace: () => {},
          },
        },
      ],
    });
    fixture = TestBed.createComponent(OkrBoardFilterComponent);
    component = fixture.componentInstance;
    component.departmentFilterName = 'cf_42';
    removeSpy = spyOn(component.wpTableFilters, 'remove');
  });

  it('clears the live filter and the displayed selection when the filter value matches no loaded unit', async () => {
    await component.loadOrganizationalUnits();
    component.syncSelectionFromLiveFilter();

    expect(component.selectedUnitId).toBeNull();
    // departmentFilterName ("cf_42") is the backend's filter *instance* accessor;
    // remove() needs the schema id ("customField42") -- see departmentSchemaName().
    expect(removeSpy).toHaveBeenCalledWith('customField42');
  });
});
