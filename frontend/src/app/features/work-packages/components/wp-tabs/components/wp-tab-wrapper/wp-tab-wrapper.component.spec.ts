import { Subject } from 'rxjs';
import { WorkPackageResource } from 'core-app/features/hal/resources/work-package-resource';
import { isPartialWorkPackage, markPartialWorkPackage } from 'core-app/features/hal/helpers/partial-work-package';
import { WpTabWrapperComponent } from './wp-tab-wrapper.component';

describe('WpTabWrapperComponent', () => {
  const wp = (id:string):WorkPackageResource => ({ id } as WorkPackageResource);

  function build(cached:WorkPackageResource|undefined, stream:Subject<WorkPackageResource>) {
    // Construct without the DI constructor; we only exercise ngOnInit's stream wiring.
    const component = Object.create(WpTabWrapperComponent.prototype) as WpTabWrapperComponent;
    const fields = component as unknown as Record<string, unknown>;

    let forced:boolean|undefined;
    fields.workPackageId = '1';
    fields.uiRouterGlobals = { params: { workPackageId: '1', tabIdentifier: 'overview' } };
    fields.states = { workPackages: { get: () => ({ getValueOr: () => cached }) } };
    fields.apiV3Service = {
      work_packages: {
        id: () => ({
          requireAndStream: (force:boolean) => {
            forced = force;
            return stream.asObservable();
          },
        }),
      },
    };
    fields.wpTabsService = { getTab: () => ({ id: 'overview' }) };

    return { component, getForced: () => forced };
  }

  it('forces a full reload and never surfaces a partial when the cached WP is partial', () => {
    const partial = wp('1');
    markPartialWorkPackage(partial);
    const stream = new Subject<WorkPackageResource>();
    const { component, getForced } = build(partial, stream);

    component.ngOnInit();

    // Cached payload is partial -> reload is forced.
    expect(getForced()).toBe(true);

    const emissions:{ workPackage:WorkPackageResource }[] = [];
    component.ndcDynamicInputs$.subscribe((value) => emissions.push(value));

    // A partial emission must not reach the body (it would build wp-single-view from
    // the schema-less subset and stay stuck there).
    const stillPartial = wp('1');
    markPartialWorkPackage(stillPartial);
    stream.next(stillPartial);

    expect(emissions.length).toBe(0);

    // The complete resource is surfaced.
    const full = wp('1');
    stream.next(full);

    expect(emissions.length).toBe(1);
    expect(emissions[0].workPackage).toBe(full);
    expect(isPartialWorkPackage(emissions[0].workPackage)).toBe(false);
  });

  it('does not force a reload when the cached work package is already complete', () => {
    const full = wp('1');
    const stream = new Subject<WorkPackageResource>();
    const { component, getForced } = build(full, stream);

    component.ngOnInit();

    expect(getForced()).toBe(false);
  });
});
