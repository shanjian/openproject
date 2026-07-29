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

import {
  LinkedWorkPackageDisplayField,
} from 'core-app/shared/components/fields/display/field-types/linked-work-package-display-field.module';

// The Epic link is a regular, user-editable work package attribute (unlike
// `parent`, which is managed through the hierarchy). LinkedWorkPackageDisplayField
// hard-codes `writable = false`, which suppresses inline editing and, more
// importantly, hides the field entirely on the create form (see
// WorkPackageFormAttributeGroupComponent#shouldHideField, which drops non-writable
// fields in create mode). We therefore restore schema-driven writability for epic
// so it renders and can be edited on both the create and edit forms, while keeping
// the link rendering inherited from LinkedWorkPackageDisplayField.
export class EpicDisplayField extends LinkedWorkPackageDisplayField {
  public get writable():boolean {
    return this.schema.writable && this.context.options.writable !== false;
  }
}
