import { WorkPackageResource } from 'core-app/features/hal/resources/work-package-resource';
import { isPartialWorkPackage, markPartialWorkPackage } from './partial-work-package';

describe('partial work package marker', () => {
  const wp = (id:string):WorkPackageResource => ({ id } as WorkPackageResource);

  it('reports a marked work package as partial', () => {
    const partial = wp('1');
    markPartialWorkPackage(partial);

    expect(isPartialWorkPackage(partial)).toBe(true);
  });

  it('reports an unmarked (full) work package as not partial', () => {
    expect(isPartialWorkPackage(wp('2'))).toBe(false);
  });

  it('treats undefined as not partial', () => {
    expect(isPartialWorkPackage(undefined)).toBe(false);
  });

  it('keys by object identity, so a fresh full load supersedes a partial one', () => {
    const partial = wp('3');
    markPartialWorkPackage(partial);
    // A full reload produces a new object for the same id; it is not marked.
    const full = wp('3');

    expect(isPartialWorkPackage(partial)).toBe(true);
    expect(isPartialWorkPackage(full)).toBe(false);
  });
});
