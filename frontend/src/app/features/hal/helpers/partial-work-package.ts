import { WorkPackageResource } from 'core-app/features/hal/resources/work-package-resource';

// Work packages fetched through a projected `select` (e.g. the lightweight board
// card payload) only contain a subset of attributes. They are still written to the
// global work-package cache, because drag & drop and the card view read from it, but
// any consumer that needs the COMPLETE resource — notably the work package
// detail/full view — must reload it instead of trusting the cached subset.
//
// We track such partial resources by object identity. A fully loaded resource is
// never marked, and a full resource always supersedes a partial one (a fresh full
// load produces a new, unmarked object), so "full covers partial".
const partialWorkPackages = new WeakSet<WorkPackageResource>();

export function markPartialWorkPackage(workPackage:WorkPackageResource):void {
  partialWorkPackages.add(workPackage);
}

export function isPartialWorkPackage(workPackage:WorkPackageResource|undefined):boolean {
  return !!workPackage && partialWorkPackages.has(workPackage);
}
