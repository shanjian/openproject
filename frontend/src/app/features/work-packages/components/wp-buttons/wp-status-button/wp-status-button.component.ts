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
import { HalResourceEditingService } from 'core-app/shared/components/fields/edit/services/hal-resource-editing.service';
import {
  ChangeDetectorRef, Component, Input, OnInit,
} from '@angular/core';
import { I18nService } from 'core-app/core/i18n/i18n.service';
import { Highlighting } from 'core-app/features/work-packages/components/wp-fast-table/builders/highlighting/highlighting.functions';
import { HalResource } from 'core-app/features/hal/resources/hal-resource';
import { UntilDestroyedMixin } from 'core-app/shared/helpers/angular/until-destroyed.mixin';
import { SchemaCacheService } from 'core-app/core/schemas/schema-cache.service';

@Component({
  selector: 'wp-status-button',
  styleUrls: ['./wp-status-button.component.sass'],
  templateUrl: './wp-status-button.html',
  standalone: false,
})
export class WorkPackageStatusButtonComponent extends UntilDestroyedMixin implements OnInit {
  @Input() public workPackage:WorkPackageResource;

  @Input() public small = false;

  public text = {
    explanation: this.I18n.t('js.label_edit_status'),
    workPackageReadOnly: this.I18n.t('js.work_packages.message_work_package_read_only'),
    workPackageStatusBlocked: this.I18n.t('js.work_packages.message_work_package_status_blocked'),
  };

  constructor(readonly I18n:I18nService,
    readonly cdRef:ChangeDetectorRef,
    readonly schemaCache:SchemaCacheService,
    readonly halEditing:HalResourceEditingService) {
    super();
  }

  ngOnInit() {
    this.halEditing
      .temporaryEditResource(this.workPackage)
      .values$()
      .pipe(
        this.untilDestroyed(),
      )
      .subscribe((wp) => {
        this.workPackage = wp;

        if (this.workPackage.status) {
          this.workPackage.status.$load();
        }

        this.cdRef.detectChanges();
      });
  }

  public get buttonTitle() {
    const { schema } = this;
    if (schema?.isReadonly) {
      return this.text.workPackageReadOnly;
    } if (schema?.isEditable && !this.allowed) {
      return this.text.workPackageStatusBlocked;
    }
    return '';
  }

  public get statusHighlightClass() {
    const { status } = this;
    if (!status) {
      return;
    }
    return Highlighting.backgroundClass('status', status.id!);
  }

  public get status():HalResource {
    return this.workPackage.status;
  }

  public get isReadonly() {
    return !!this.schema?.isReadonly;
  }

  public get allowed() {
    const { schema } = this;
    // When the schema is not loaded (e.g. a board's lightweight `select` payload),
    // assume the status is editable; the dropdown loads what it needs on demand.
    return schema ? schema.isAttributeEditable('status') : true;
  }

  // Returns the schema ONLY when it is actually loaded for this work package. A
  // lightweight (board select) payload has no schema link / cached schema, and
  // schemaCache.of() would otherwise proxy `undefined` and throw in the getters
  // above — which dropped the status display from cards without a cached schema.
  private get schema() {
    const edited = this.halEditing.typedState(this.workPackage);
    if (edited.hasValue()) {
      return edited.value!.schema;
    }

    const href = this.schemaCache.getSchemaHref(this.workPackage);
    if (href && this.schemaCache.state(href).hasValue()) {
      return this.schemaCache.of(this.workPackage);
    }

    return undefined;
  }
}
