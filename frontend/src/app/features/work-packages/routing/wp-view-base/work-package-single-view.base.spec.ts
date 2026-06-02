import { Subject } from 'rxjs';
import { WorkPackageResource } from 'core-app/features/hal/resources/work-package-resource';
import { markPartialWorkPackage } from 'core-app/features/hal/helpers/partial-work-package';
import { WorkPackageSingleViewBase } from './work-package-single-view.base';

describe('WorkPackageSingleViewBase#observeWorkPackage', () => {
  const wp = (id:string):WorkPackageResource => ({
    id,
    subjectWithType: () => `#${id}`,
  } as unknown as WorkPackageResource);

  // The injected dependencies are prototype getters (@InjectField), so we must shadow
  // them with own properties rather than plain assignment.
  const stub = (view:object, key:string, value:unknown) =>
    Object.defineProperty(view, key, { value, configurable: true, writable: true });

  function buildView(
    cached:WorkPackageResource|undefined,
    stream:Subject<WorkPackageResource>,
    renderPartialWhileReloading = true,
  ) {
    // Construct without the (large) DI constructor; we only exercise observeWorkPackage.
    const view = Object.create(WorkPackageSingleViewBase.prototype) as WorkPackageSingleViewBase;

    // Opt-in seeding flag (a protected field overridden by the split view subclass).
    stub(view, 'renderPartialWhileReloading', renderPartialWhileReloading);
    stub(view, 'workPackageId', '1');
    stub(view, 'states', {
      workPackages: { get: () => ({ getValueOr: () => cached }) },
    });
    stub(view, 'apiV3Service', {
      work_packages: { id: () => ({ requireAndStream: () => stream.asObservable() }) },
    });
    stub(view, 'cdRef', { detectChanges: () => undefined });
    stub(view, 'titleService', { setFirstPart: () => undefined });
    // untilDestroyed() is a mixin operator; stub to a pass-through so the stream flows.
    stub(view, 'untilDestroyed', () => (source:unknown) => source);

    return view;
  }

  const observe = (view:WorkPackageSingleViewBase) =>
    (view as unknown as { observeWorkPackage:() => void }).observeWorkPackage();

  it('renders the cached partial immediately and defers init() until the full load', () => {
    const partial = wp('1');
    markPartialWorkPackage(partial);
    const stream = new Subject<WorkPackageResource>();
    const view = buildView(partial, stream);
    const init = spyOn(view as unknown as { init:() => void }, 'init');

    observe(view);

    // Seeded synchronously, before any emission — so the panel is never blank.
    expect(view.workPackage).toBe(partial);
    expect(init).not.toHaveBeenCalled();

    // The forced reload returns the complete resource.
    const full = wp('1');
    stream.next(full);

    expect(view.workPackage).toBe(full);
    expect(init).toHaveBeenCalledTimes(1);
  });

  it('does not run init() more than once on cache re-emissions', () => {
    const partial = wp('1');
    markPartialWorkPackage(partial);
    const stream = new Subject<WorkPackageResource>();
    const view = buildView(partial, stream);
    const init = spyOn(view as unknown as { init:() => void }, 'init');

    observe(view);
    stream.next(wp('1'));
    stream.next(wp('1'));

    expect(init).toHaveBeenCalledTimes(1);
  });

  it('does not seed when the cached work package is already complete', () => {
    const full = wp('1');
    const stream = new Subject<WorkPackageResource>();
    const view = buildView(full, stream);
    spyOn(view as unknown as { init:() => void }, 'init');

    observe(view);

    // Not partial → nothing rendered until the stream emits (unchanged behaviour).
    expect(view.workPackage).toBeUndefined();
  });

  it('does not seed a partial when the view opts out (renderPartialWhileReloading=false)', () => {
    const partial = wp('1');
    markPartialWorkPackage(partial);
    const stream = new Subject<WorkPackageResource>();
    const view = buildView(partial, stream, false);
    spyOn(view as unknown as { init:() => void }, 'init');

    observe(view);

    // e.g. the full view keeps waiting for the complete resource.
    expect(view.workPackage).toBeUndefined();
  });
});
