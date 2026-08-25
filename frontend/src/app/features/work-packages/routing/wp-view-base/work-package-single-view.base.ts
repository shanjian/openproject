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
  ChangeDetectorRef,
  Directive,
  Injector,
  Input,
} from '@angular/core';
import { I18nService } from 'core-app/core/i18n/i18n.service';
import { PathHelperService } from 'core-app/core/path-helper/path-helper.service';
import {
  WorkPackageViewFocusService,
} from 'core-app/features/work-packages/routing/wp-view-base/view-services/wp-view-focus.service';
import { WorkPackageResource } from 'core-app/features/hal/resources/work-package-resource';
import { isPartialWorkPackage } from 'core-app/features/hal/helpers/partial-work-package';
import { OpTitleService } from 'core-app/core/html/op-title.service';
import { AuthorisationService } from 'core-app/core/model-auth/model-auth.service';
import { States } from 'core-app/core/states/states.service';
import {
  KeepTabService,
} from 'core-app/features/work-packages/components/wp-single-view-tabs/keep-tab/keep-tab.service';
import {
  HalResourceEditingService,
} from 'core-app/shared/components/fields/edit/services/hal-resource-editing.service';
import {
  WorkPackageNotificationService,
} from 'core-app/features/work-packages/services/notifications/work-package-notification.service';
import {
  take,
} from 'rxjs/operators';
import { InjectField } from 'core-app/shared/helpers/angular/inject-field.decorator';
import { UntilDestroyedMixin } from 'core-app/shared/helpers/angular/until-destroyed.mixin';
import { ApiV3Service } from 'core-app/core/apiv3/api-v3.service';
import { HookService } from 'core-app/features/plugins/hook-service';
import { WpSingleViewService } from 'core-app/features/work-packages/routing/wp-view-base/state/wp-single-view.service';
import { Observable } from 'rxjs';
import { ActionsService } from 'core-app/core/state/actions/actions.service';
import { AttachmentsResourceService } from 'core-app/core/state/attachments/attachments.service';
import { StoragesResourceService } from 'core-app/core/state/storages/storages.service';
import { FileLinksResourceService } from 'core-app/core/state/file-links/file-links.service';
import { ProjectsResourceService } from 'core-app/core/state/projects/projects.service';
import { HalResource } from 'core-app/features/hal/resources/hal-resource';
import { ToastService } from 'core-app/shared/components/toaster/toast.service';
import { HttpErrorResponse } from '@angular/common/http';
import { StateService } from '@uirouter/angular';

@Directive()
export abstract class WorkPackageSingleViewBase extends UntilDestroyedMixin {
  @Input() routedFromAngular = true;

  @Input() workPackageId:string;

  @Input() activeTab = 'activity';

  @InjectField() states:States;

  @InjectField() $state:StateService;

  @InjectField() i18n:I18nService;

  @InjectField() keepTab:KeepTabService;

  @InjectField() PathHelper:PathHelperService;

  @InjectField() halEditing:HalResourceEditingService;

  @InjectField() wpTableFocus:WorkPackageViewFocusService;

  @InjectField() notificationService:WorkPackageNotificationService;

  @InjectField() authorisationService:AuthorisationService;

  @InjectField() private readonly attachmentsResourceService:AttachmentsResourceService;

  @InjectField() private readonly fileLinkResourceService:FileLinksResourceService;

  @InjectField() private readonly projectsResourceService:ProjectsResourceService;

  @InjectField() private readonly storages:StoragesResourceService;

  @InjectField() private readonly toastService:ToastService;

  @InjectField() cdRef:ChangeDetectorRef;

  @InjectField() readonly titleService:OpTitleService;

  @InjectField() readonly apiV3Service:ApiV3Service;

  @InjectField() readonly hooks:HookService;

  @InjectField() readonly actions$:ActionsService;

  @InjectField() readonly storeService:WpSingleViewService;

  // Work package resource to be loaded from the cache
  public workPackage:WorkPackageResource;

  // Whether init() has already run for the loaded (complete) work package. Guards
  // against re-initializing on cache re-emissions and against running init() against
  // a partial resource that was seeded only for an immediate, non-blank render.
  private initialized = false;

  /**
   * Whether to render a cached partial work package immediately while a forced full
   * reload is in flight, so the panel is never blank. Off by default; subclasses whose
   * template only binds header-level data to the partial (e.g. the split view, whose
   * attribute body is loaded separately) opt in. Views that render schema-dependent
   * attributes directly from the resource must keep waiting for the complete resource.
   */
  protected readonly renderPartialWhileReloading:boolean = false;

  public projectIdentifier:string;

  public focusAnchorLabel:string;

  public showStaticPagePath:string;

  public displayNotificationsButton$:Observable<boolean>;

  constructor(
    public injector:Injector,
  ) {
    super();

    if (this.routedFromAngular && this.workPackageId === undefined) {
      this.workPackageId = this.$state.params.workPackageId as string;
    }
  }

  /**
   * Observe changes of work package and re-run initialization.
   * Needs to be run explicitly by descendants.
   */
  protected observeWorkPackage():void {
    // If only a partial work package is cached (e.g. a board's lightweight `select`
    // payload), force a full reload — the detail view needs the complete resource.
    const cached = this.states.workPackages.get(this.workPackageId).getValueOr(undefined);
    const forceFullReload = isPartialWorkPackage(cached);

    // Render the cached partial straight away so the panel is never blank while the
    // full resource reloads. Forcing a reload clears the cache entry and fires an
    // async request; without this seed the view would show nothing until it returns.
    // We hold our own reference here, so the upcoming cache clear cannot null it, and
    // init() stays deferred until the complete resource arrives (see `initialized`).
    //
    // Opt-in (split view only): the partial drives just the header/toolbar there, the
    // attribute body is reloaded separately. The full view renders attributes directly
    // from this resource and needs the schema, which the partial lacks, so it keeps
    // waiting for the complete resource instead. We do not detect changes here on
    // purpose — the first change-detection pass after ngOnInit renders the seed once
    // requireAndStream() below has cleared the cache, so child views (e.g. the tab
    // wrapper) mount against the cleared cache and wait for the full resource rather
    // than briefly binding the partial.
    if (forceFullReload && cached && this.renderPartialWhileReloading) {
      this.workPackage = cached;
    }

    this
      .apiV3Service
      .work_packages
      .id(this.workPackageId)
      .requireAndStream(forceFullReload)
      .pipe(this.untilDestroyed())
      .subscribe((wp:WorkPackageResource) => {
        this.workPackage = wp;

        // Run one-time initialization only once, against the complete resource —
        // never against the partial seeded above. When a reload is forced, the first
        // emission is the freshly loaded full work package.
        if (!this.initialized) {
          this.initialized = true;
          this.init();
        }

        // Push the current title
        this.titleService.setFirstPart(this.workPackage.subjectWithType(-1));

        this.cdRef.detectChanges();
      }, (error) => {
        this.handleLoadingError(error);
      });
  }

  /**
   * Initialize controller after workPackage resource has been loaded.
   */
  protected init():void {
    // Set elements
    this
      .apiV3Service
      .projects
      .id(this.workPackage.project)
      .requireAndStream()
      .subscribe(() => {
        this.projectIdentifier = this.workPackage.project.identifier;
        this.cdRef.detectChanges();
      });

    // lazy load the work package's project, needed when initializing
    // the work package resource from split view.
    this.projectsResourceService
      .requireEntity((this.workPackage.$links.project as HalResource).href!)
      .subscribe(
        () => {},
        (error:HttpErrorResponse) => {
          this.toastService.addError(error);
        },
      );

    this.displayNotificationsButton$ = this.storeService.hasNotifications$;
    // Opening a work package, in the split view or in the full view, counts as reading
    // its notifications.
    this.storeService.setFilters(this.workPackage.id!, true);

    // Set authorisation data
    this.authorisationService.initModelAuth('work_package', this.workPackage.$links);

    // Preselect this work package for future list operations
    this.showStaticPagePath = this.PathHelper.workPackagePath(this.workPackageId);

    // Fetch attachments of current work package
    if (this.workPackage.$links.attachments) {
      this.attachmentsResourceService.fetchCollection(this.workPackage.$links.attachments.href!).subscribe();
    }

    // Listen to tab changes to update the tab label
    this.keepTab.observable
      .pipe(this.untilDestroyed())
      .subscribe((tabs:{ active:string }) => {
        this.updateFocusAnchorLabel(tabs.active);
      });
  }

  protected handleLoadingError(error:unknown):void {
    this.notificationService.handleRawError(error);
  }

  /**
   * Recompute the current tab focus label
   */
  public updateFocusAnchorLabel(tabName:string):string {
    this.focusAnchorLabel = this.i18n.t('js.label_work_package_details_you_are_here', {
      tab: this.i18n.t(`js.work_packages.tabs.${tabName}`),
      type: this.workPackage.type.name,
      subject: this.workPackage.subject,
    });
    return this.focusAnchorLabel;
  }
}
