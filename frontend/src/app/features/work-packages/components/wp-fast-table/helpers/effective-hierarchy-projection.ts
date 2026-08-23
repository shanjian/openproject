//-- copyright
// OpenProject is an open source project management software.
// Copyright (C) the OpenProject GmbH
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License version 3.
//
// OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
// Copyright (C) 2006-2013 Jean-Philippe Lang
// Copyright (C) 2010-2013 the ChiliProject Team
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 2
// of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
//
// See COPYRIGHT and LICENSE files for more details.
//++

import { WorkPackageResource } from 'core-app/features/hal/resources/work-package-resource';

/**
 * The hierarchy the table *displays*, as opposed to the stored parent
 * hierarchy the API reports. It is the real hierarchy with one addition: a work
 * package that has no parent at all is displayed under the epic it links to, so
 * an epic reads as the head of its work instead of as a sibling of it.
 *
 * The rule is deliberately narrow (see
 * docs/development/epic-hierarchy-display-design.md):
 *
 * - A real parent always wins, so no displayed edge ever contradicts the stored
 *   hierarchy. "Has a real parent" is read from the `hasParent` property, not
 *   from the parent link: that link is empty both for a root work package and
 *   for one whose parent is invisible, and adopting in the second case would
 *   assert a hierarchy that does not exist.
 * - Adoption is scoped to the rows handed to this projection -- one page of one
 *   query -- so an epic that is not on the page adopts nothing. Nesting is
 *   therefore page-local by construction, with no query state to thread here.
 * - Epic edges never chain, which keeps the displayed tree acyclic whatever the
 *   data says.
 *
 * Nothing here is written back; the API keeps reporting the real hierarchy, and
 * the breadcrumb, indent/outdent and every API client go on reading it.
 * `app/models/work_package/effective_hierarchy.rb` applies the same rule to the
 * PDF export.
 */
export class EffectiveHierarchyProjection {
  private readonly rows:WorkPackageResource[];

  private readonly rowsById:Map<string, WorkPackageResource>;

  private readonly adoptiveEpics:Map<string, WorkPackageResource>;

  constructor(rows:WorkPackageResource[]) {
    this.rows = rows;
    this.rowsById = new Map(
      rows
        .filter((row) => !!row.id)
        .map((row) => [row.id!, row]),
    );
    this.adoptiveEpics = new Map();

    rows.forEach((row) => {
      if (!row.id) {
        return;
      }

      const epic = this.resolveAdoptiveEpic(row);
      if (epic) {
        this.adoptiveEpics.set(row.id, epic);
      }
    });
  }

  /**
   * The ancestor chain to display for this work package, root first — the same
   * shape and order as `getAncestors()`, which it replaces in the hierarchy
   * renderers.
   */
  public ancestorsOf(workPackage:WorkPackageResource):WorkPackageResource[] {
    const epic = this.adoptiveEpicOf(workPackage);

    if (!epic) {
      return workPackage.getAncestors();
    }

    // The epic stands in as the parent, so its own real ancestors sit above it.
    return [...epic.getAncestors(), epic];
  }

  /**
   * Whether this work package is displayed under its epic rather than under a
   * real parent. Callers use it to keep epic-derived nesting out of behavior
   * that must reflect the stored hierarchy.
   */
  public isAdopted(workPackage:WorkPackageResource):boolean {
    return !!this.adoptiveEpicOf(workPackage);
  }

  /**
   * The epic standing in as this work package's parent, if any.
   */
  public adoptiveEpicOf(workPackage:WorkPackageResource):WorkPackageResource|null {
    if (!workPackage.id) {
      return null;
    }

    return this.adoptiveEpics.get(workPackage.id) ?? null;
  }

  /**
   * The rows on this page that link to the given work package as their epic —
   * including those displayed elsewhere in the tree because they have a real
   * parent. This is the epic's *scope*, which is not the same as its subtree.
   */
  public linkedChildrenOf(epic:WorkPackageResource):WorkPackageResource[] {
    if (!epic.id) {
      return [];
    }

    return this.rows.filter((row) => this.epicIdOf(row) === epic.id);
  }

  private resolveAdoptiveEpic(workPackage:WorkPackageResource):WorkPackageResource|null {
    // Absent hasParent (an older payload, or a projection that omits it) is
    // treated as "may have a parent": not adopting is the safe direction.
    if (this.hasParent(workPackage) !== false) {
      return null;
    }

    const epicId = this.epicIdOf(workPackage);
    if (!epicId || epicId === workPackage.id) {
      return null;
    }

    const epic = this.rowsById.get(epicId);
    // An epic that is not on the page cannot adopt, and an epic that links an
    // epic of its own does not either: that keeps epic edges to a single hop,
    // so no cycle can be built out of them.
    if (!epic || this.epicIdOf(epic)) {
      return null;
    }

    return epic;
  }

  private hasParent(workPackage:WorkPackageResource):boolean|undefined {
    return (workPackage as unknown as { hasParent?:boolean }).hasParent;
  }

  private epicIdOf(workPackage:WorkPackageResource):string|null {
    const epic = (workPackage as unknown as { epic?:{ id?:string|null } }).epic;
    return epic?.id ? epic.id.toString() : null;
  }
}
