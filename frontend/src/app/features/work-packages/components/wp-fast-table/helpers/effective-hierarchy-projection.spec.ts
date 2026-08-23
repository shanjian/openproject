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
import { EffectiveHierarchyProjection } from './effective-hierarchy-projection';

describe('EffectiveHierarchyProjection', () => {
  interface FakeOptions {
    hasParent?:boolean;
    epicId?:string;
    ancestors?:WorkPackageResource[];
    startDate?:string|null;
    dueDate?:string|null;
  }

  function wp(id:string, options:FakeOptions = {}):WorkPackageResource {
    const ancestors = options.ancestors ?? [];
    return {
      id,
      hasParent: options.hasParent,
      epic: options.epicId ? { id: options.epicId } : undefined,
      startDate: options.startDate,
      dueDate: options.dueDate,
      getAncestors: () => ancestors,
    } as unknown as WorkPackageResource;
  }

  function projectionOf(...rows:WorkPackageResource[]):EffectiveHierarchyProjection {
    return new EffectiveHierarchyProjection(rows);
  }

  describe('a parentless work package linking an epic on the page', () => {
    it('is adopted by the epic', () => {
      const epic = wp('1');
      const task = wp('2', { hasParent: false, epicId: '1' });

      expect(projectionOf(epic, task).ancestorsOf(task)).toEqual([epic]);
      expect(projectionOf(epic, task).isAdopted(task)).toBe(true);
    });

    it('is placed below the epic\'s own real ancestors, root first', () => {
      const grandparent = wp('9');
      const epic = wp('1', { hasParent: true, ancestors: [grandparent] });
      const task = wp('2', { hasParent: false, epicId: '1' });

      expect(projectionOf(grandparent, epic, task).ancestorsOf(task)).toEqual([grandparent, epic]);
    });
  });

  describe('scoping to the current page', () => {
    it('leaves the work package at root level when the epic is not on the page', () => {
      const task = wp('2', { hasParent: false, epicId: '1' });

      expect(projectionOf(task).ancestorsOf(task)).toEqual([]);
      expect(projectionOf(task).isAdopted(task)).toBe(false);
    });
  });

  describe('a work package with a real parent', () => {
    it('keeps its real ancestors, even when it also links an epic on the page', () => {
      const epic = wp('1');
      const parent = wp('3');
      const task = wp('2', { hasParent: true, epicId: '1', ancestors: [parent] });

      expect(projectionOf(epic, parent, task).ancestorsOf(task)).toEqual([parent]);
      expect(projectionOf(epic, parent, task).isAdopted(task)).toBe(false);
    });

    // The parent link is empty for an invisible parent exactly as it is for no
    // parent, so without hasParent this work package would be adopted and the
    // display would assert a hierarchy that does not exist.
    it('is not adopted when its real parent is merely invisible', () => {
      const epic = wp('1');
      const task = wp('2', { hasParent: true, epicId: '1', ancestors: [] });

      expect(projectionOf(epic, task).ancestorsOf(task)).toEqual([]);
      expect(projectionOf(epic, task).isAdopted(task)).toBe(false);
    });
  });

  describe('when hasParent is absent from the payload', () => {
    it('does not adopt, rather than guessing', () => {
      const epic = wp('1');
      const task = wp('2', { epicId: '1' });

      expect(projectionOf(epic, task).isAdopted(task)).toBe(false);
    });
  });

  describe('acyclicity', () => {
    it('does not adopt into an epic that itself links an epic', () => {
      const outer = wp('0');
      const epic = wp('1', { hasParent: false, epicId: '0' });
      const task = wp('2', { hasParent: false, epicId: '1' });

      expect(projectionOf(outer, epic, task).isAdopted(task)).toBe(false);
    });

    it('cannot build a cycle out of two mutually linked work packages', () => {
      const a = wp('1', { hasParent: false, epicId: '2' });
      const b = wp('2', { hasParent: false, epicId: '1' });
      const projection = projectionOf(a, b);

      expect(projection.isAdopted(a)).toBe(false);
      expect(projection.isAdopted(b)).toBe(false);
    });

    it('ignores a self-referencing epic link', () => {
      const task = wp('2', { hasParent: false, epicId: '2' });

      expect(projectionOf(task).isAdopted(task)).toBe(false);
    });
  });

  describe('linkedChildrenOf', () => {
    it('returns the epic\'s linked children present on the page', () => {
      const epic = wp('1');
      const child = wp('2', { hasParent: false, epicId: '1' });
      const otherChild = wp('3', { hasParent: false, epicId: '1' });
      const unrelated = wp('4', { hasParent: false, epicId: '99' });

      expect(projectionOf(epic, child, otherChild, unrelated).linkedChildrenOf(epic))
        .toEqual([child, otherChild]);
    });

    // The bar shows the epic's scope, which is not the same as its subtree: a
    // linked work package displayed under its own parent is still in scope.
    it('includes linked children that are displayed under their own real parent', () => {
      const epic = wp('1');
      const parent = wp('3');
      const parentedChild = wp('2', { hasParent: true, epicId: '1', ancestors: [parent] });

      expect(projectionOf(epic, parent, parentedChild).linkedChildrenOf(epic))
        .toEqual([parentedChild]);
    });

    it('is empty for a work package nothing links to', () => {
      const epic = wp('1');
      const unrelated = wp('4', { hasParent: false });

      expect(projectionOf(epic, unrelated).linkedChildrenOf(epic)).toEqual([]);
    });
  });

  // The epic's bar shows when its work runs. It is the span of the linked
  // children on this page, which is deliberately not the same thing as the
  // hierarchy children-duration bar: it covers linked work displayed elsewhere
  // in the tree, and it covers nothing that is not on the page.
  describe('linkedChildrenEnvelopeOf', () => {
    it('spans the earliest start and the latest finish of the linked children', () => {
      const epic = wp('1');
      const early = wp('2', { hasParent: false, epicId: '1', startDate: '2026-03-02', dueDate: '2026-03-20' });
      const late = wp('3', { hasParent: false, epicId: '1', startDate: '2026-04-01', dueDate: '2026-04-10' });

      expect(projectionOf(epic, early, late).linkedChildrenEnvelopeOf(epic))
        .toEqual({ start: '2026-03-02', due: '2026-04-10' });
    });

    it('covers a linked child displayed under its own real parent', () => {
      const epic = wp('1');
      const parent = wp('4');
      const parented = wp('2', {
        hasParent: true, epicId: '1', ancestors: [parent], startDate: '2026-03-02', dueDate: '2026-03-20',
      });

      expect(projectionOf(epic, parent, parented).linkedChildrenEnvelopeOf(epic))
        .toEqual({ start: '2026-03-02', due: '2026-03-20' });
    });

    it('ignores linked children that carry no dates', () => {
      const epic = wp('1');
      const dated = wp('2', { hasParent: false, epicId: '1', startDate: '2026-03-02', dueDate: '2026-03-20' });
      const undated = wp('3', { hasParent: false, epicId: '1' });

      expect(projectionOf(epic, dated, undated).linkedChildrenEnvelopeOf(epic))
        .toEqual({ start: '2026-03-02', due: '2026-03-20' });
    });

    it('uses a milestone-style child with only one date at both ends', () => {
      const epic = wp('1');
      const milestone = wp('2', { hasParent: false, epicId: '1', dueDate: '2026-03-20' });

      expect(projectionOf(epic, milestone).linkedChildrenEnvelopeOf(epic))
        .toEqual({ start: '2026-03-20', due: '2026-03-20' });
    });

    it('is null when no linked child is on the page', () => {
      const epic = wp('1');
      const elsewhere = wp('2', { hasParent: false, epicId: '99', startDate: '2026-03-02', dueDate: '2026-03-20' });

      expect(projectionOf(epic, elsewhere).linkedChildrenEnvelopeOf(epic)).toBeNull();
    });

    it('is null when every linked child is undated', () => {
      const epic = wp('1');
      const undated = wp('2', { hasParent: false, epicId: '1' });

      expect(projectionOf(epic, undated).linkedChildrenEnvelopeOf(epic)).toBeNull();
    });

    // Collapsing is presentation, not filtering: the rows are still on the page,
    // so the span the projection reports does not move.
    it('does not depend on which rows are currently visible', () => {
      const epic = wp('1');
      const child = wp('2', { hasParent: false, epicId: '1', startDate: '2026-03-02', dueDate: '2026-03-20' });
      const projection = projectionOf(epic, child);

      expect(projection.linkedChildrenEnvelopeOf(epic)).toEqual(projection.linkedChildrenEnvelopeOf(epic));
      expect(projection.linkedChildrenEnvelopeOf(epic)).toEqual({ start: '2026-03-02', due: '2026-03-20' });
    });
  });

  describe('rows that are not adopted at all', () => {
    it('reports real ancestors unchanged for a plain nested work package', () => {
      const parent = wp('3');
      const child = wp('4', { hasParent: true, ancestors: [parent] });

      expect(projectionOf(parent, child).ancestorsOf(child)).toEqual([parent]);
    });

    it('reports no ancestors for a plain root work package', () => {
      const root = wp('5', { hasParent: false });

      expect(projectionOf(root).ancestorsOf(root)).toEqual([]);
    });
  });
});
