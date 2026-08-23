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

import { UserAutocompleterTemplateComponent } from './user-autocompleter-template.component';
import { IUserAutocompleteItem } from './user-autocompleter.component';

// "Assign to me" gating and action: exercised directly on the prototype (no
// TestBed) since ngOnInit/checkCurrentUserAssignable pull in HTTP, the current
// user service and the API v3 service - showAssignToMe/onAssignToMe don't need any of that.
describe('UserAutocompleterTemplateComponent "assign to me"', () => {
  const currentUser:IUserAutocompleteItem = { id: '7', name: 'Me', href: '/api/v3/users/7' };

  const buildComponent = (overrides:Partial<Record<string, unknown>> = {}) => {
    const changed = jasmine.createSpy('changed');
    const closeSelect = jasmine.createSpy('closeSelect');
    const component = Object.create(UserAutocompleterTemplateComponent.prototype) as UserAutocompleterTemplateComponent;
    Object.assign(component, {
      assignToMe: true,
      currentUserItem: currentUser,
      currentUserAssignable: true,
      autocompleter: { model: null, changed, closeSelect },
      ...overrides,
    });
    return { component, changed, closeSelect };
  };

  describe('#showAssignToMe', () => {
    it('is true when eligible: assignToMe enabled, a current user, assignable, and not already the assignee', () => {
      const { component } = buildComponent();

      expect(component.showAssignToMe).toBe(true);
    });

    it('is false when the assignToMe feature is not enabled for this field', () => {
      const { component } = buildComponent({ assignToMe: false });

      expect(component.showAssignToMe).toBe(false);
    });

    it('is false when there is no logged-in current user', () => {
      const { component } = buildComponent({ currentUserItem: null });

      expect(component.showAssignToMe).toBe(false);
    });

    it('is false when the current user is not an allowed assignee', () => {
      const { component } = buildComponent({ currentUserAssignable: false });

      expect(component.showAssignToMe).toBe(false);
    });

    it('is false when the field is already assigned to the current user', () => {
      const { component } = buildComponent();
      (component.autocompleter as unknown as { model:IUserAutocompleteItem }).model = currentUser;

      expect(component.showAssignToMe).toBe(false);
    });
  });

  describe('#onAssignToMe', () => {
    const clickEvent = (stopPropagation:jasmine.Spy):Event => ({ stopPropagation } as unknown as Event);

    it('assigns the current user and closes the dropdown', () => {
      const { component, changed, closeSelect } = buildComponent();
      const stopPropagation = jasmine.createSpy('stopPropagation');

      component.onAssignToMe(clickEvent(stopPropagation));

      expect(stopPropagation).toHaveBeenCalled();
      expect(changed).toHaveBeenCalledWith(currentUser);
      expect(closeSelect).toHaveBeenCalled();
    });

    it('does nothing when there is no current user', () => {
      const { component, changed } = buildComponent({ currentUserItem: null });

      component.onAssignToMe(clickEvent(jasmine.createSpy('stopPropagation')));

      expect(changed).not.toHaveBeenCalled();
    });

    it('does nothing when the current user is not an allowed assignee', () => {
      const { component, changed } = buildComponent({ currentUserAssignable: false });

      component.onAssignToMe(clickEvent(jasmine.createSpy('stopPropagation')));

      expect(changed).not.toHaveBeenCalled();
    });
  });
});
