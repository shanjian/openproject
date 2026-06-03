import {
  AfterViewInit,
  ChangeDetectionStrategy,
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  Injector,
  Input,
  OnInit,
  Output,
  QueryList,
  ViewChild,
  ViewChildren,
  OnDestroy,
} from '@angular/core';
import { IsolatedQuerySpace } from 'core-app/features/work-packages/directives/query-space/isolated-query-space';
import { I18nService } from 'core-app/core/i18n/i18n.service';
import { WorkPackageInlineCreateService } from 'core-app/features/work-packages/components/wp-inline-create/wp-inline-create.service';
import { WorkPackageCreateService } from 'core-app/features/work-packages/components/wp-new/wp-create.service';
import { trackByHrefAndProperty } from 'core-app/shared/helpers/angular/tracking-functions';
import { CardHighlightingMode } from 'core-app/features/work-packages/components/wp-fast-table/builders/highlighting/highlighting-mode.const';
import { AuthorisationService } from 'core-app/core/model-auth/model-auth.service';
import { StateService } from '@uirouter/core';
import { States } from 'core-app/core/states/states.service';
import { WorkPackageViewOrderService } from 'core-app/features/work-packages/routing/wp-view-base/view-services/wp-view-order.service';
import { PathHelperService } from 'core-app/core/path-helper/path-helper.service';
import {
  filter,
  map,
  withLatestFrom,
} from 'rxjs/operators';
import { CausedUpdatesService } from 'core-app/features/boards/board/caused-updates/caused-updates.service';
import { WorkPackageViewSelectionService } from 'core-app/features/work-packages/routing/wp-view-base/view-services/wp-view-selection.service';
import { CardViewHandlerRegistry } from 'core-app/features/work-packages/components/wp-card-view/event-handler/card-view-handler-registry';
import { WorkPackageCardViewService } from 'core-app/features/work-packages/components/wp-card-view/services/wp-card-view.service';
import { WorkPackageCardDragAndDropService } from 'core-app/features/work-packages/components/wp-card-view/services/wp-card-drag-and-drop.service';
import { WorkPackageNotificationService } from 'core-app/features/work-packages/services/notifications/work-package-notification.service';
import { DeviceService } from 'core-app/core/browser/device.service';
import {
  WorkPackageViewHandlerToken,
  WorkPackageViewOutputs,
} from 'core-app/features/work-packages/routing/wp-view-base/event-handling/event-handler-registry';
import { UntilDestroyedMixin } from 'core-app/shared/helpers/angular/until-destroyed.mixin';
import { QueryColumn } from 'core-app/features/work-packages/components/wp-query/query-column';
import { QueryResource } from 'core-app/features/hal/resources/query-resource';
import { HalEventsService } from 'core-app/features/hal/services/hal-events.service';
import { WorkPackageResource } from 'core-app/features/hal/resources/work-package-resource';
import isNewResource from 'core-app/features/hal/helpers/is-new-resource';

export type CardViewOrientation = 'horizontal'|'vertical';

@Component({
  selector: 'wp-card-view',
  styleUrls: ['./styles/wp-card-view.component.sass', './styles/wp-card-view-horizontal.sass', './styles/wp-card-view-vertical.sass'],
  templateUrl: './wp-card-view.component.html',
  changeDetection: ChangeDetectionStrategy.OnPush,
  standalone: false,
})
export class WorkPackageCardViewComponent extends UntilDestroyedMixin implements OnInit, AfterViewInit, WorkPackageViewOutputs, OnDestroy {
  @Input('dragOutOfHandler') public canDragOutOf:(wp:WorkPackageResource) => boolean;

  @Input() public dragInto:boolean;

  @Input() public highlightingMode:CardHighlightingMode;

  @Input() public workPackageAddedHandler:(wp:WorkPackageResource) => Promise<unknown>;

  @Input() public showStatusButton = true;

  @Input() public showInfoButton = false;

  @Input() public orientation:CardViewOrientation = 'vertical';

  /** Whether cards are removable */
  @Input() public cardsRemovable = false;

  /** Whether a notification box shall be shown when there are no WP to display */
  @Input() public showEmptyResultsBox = false;

  /** Whether on special mobile version of the cards shall be shown */
  @Input() public shrinkOnMobile = false;

  /** Show the assignee as a name (text) instead of an avatar. Used by boards. */
  @Input() public showAssigneeName = false;

  /** Show the compact metadata (story points, work, epic) on cards. Boards only. */
  @Input() public showCardMeta = false;

  /** Render the assignee at all. Suppressed on assignee boards (redundant). */
  @Input() public showAssignee = true;

  /**
   * When enabled, cards are rendered as lightweight placeholders and only
   * hydrated into full cards once they scroll near the viewport. Used by boards,
   * where a single column can hold hundreds of cards. Defaults to false so other
   * consumers (wp-grid, team planner) keep rendering every card eagerly.
   */
  @Input() public lazyHydrate = false;

  /** Container reference */
  @ViewChild('container', { static: true }) public container:ElementRef;

  /** Host elements of the rendered single cards, used to observe their visibility */
  @ViewChildren('cardHost', { read: ElementRef })
  public cardElements:QueryList<ElementRef<HTMLElement>>;

  /** Ids of work packages whose cards have been hydrated (lazy mode only) */
  public hydratedIds = new Set<string>();

  private intersectionObserver?:IntersectionObserver;

  @Output() public onMoved = new EventEmitter<void>();

  @Output() selectionChanged = new EventEmitter<string[]>();

  @Output() itemClicked = new EventEmitter<{ workPackageId:string, double:boolean }>();

  @Output() stateLinkClicked = new EventEmitter<{ workPackageId:string, requestedState:string }>();

  public trackByHref = trackByHrefAndProperty('lockVersion');

  public query:QueryResource;

  public isResultEmpty = false;

  public columns:QueryColumn[];

  public text = {
    removeCard: this.I18n.t('js.card.remove_from_list'),
    addNewCard: this.I18n.t('js.card.add_new'),
    noResults: {
      title: this.I18n.t('js.work_packages.no_results.title'),
      description: this.I18n.t('js.work_packages.no_results.description'),
    },
  };

  public inReference = false;

  public referenceClass = this.wpInlineCreate.referenceComponentClass;

  // We need to mount a dynamic component into the view
  // but map the following output
  public referenceOutputs = {
    onCancel: () => this.setReferenceMode(false),
    onReferenced: (wp:WorkPackageResource) => this.cardDragDrop.addWorkPackageToQuery(wp, 0),
  };

  isNewResource = isNewResource;

  constructor(readonly querySpace:IsolatedQuerySpace,
    readonly states:States,
    readonly injector:Injector,
    readonly $state:StateService,
    readonly I18n:I18nService,
    readonly wpCreate:WorkPackageCreateService,
    readonly wpInlineCreate:WorkPackageInlineCreateService,
    readonly notificationService:WorkPackageNotificationService,
    readonly halEvents:HalEventsService,
    readonly authorisationService:AuthorisationService,
    readonly causedUpdates:CausedUpdatesService,
    readonly cdRef:ChangeDetectorRef,
    readonly pathHelper:PathHelperService,
    readonly wpTableSelection:WorkPackageViewSelectionService,
    readonly wpViewOrder:WorkPackageViewOrderService,
    readonly cardView:WorkPackageCardViewService,
    readonly cardDragDrop:WorkPackageCardDragAndDropService,
    readonly deviceService:DeviceService) {
    super();
  }

  ngOnInit() {
    this.registerCreationCallback();

    // Observe changes to the work packages in this view
    this.halEvents
      .aggregated$('WorkPackage')
      .pipe(
        map((events) => events.filter((event) => event.eventType === 'updated')),
        filter((events) => {
          const wpIds:string[] = this.workPackages.map((el) => el.id!.toString());
          return !!events.find((event) => wpIds.includes(event.id));
        }),
      ).subscribe(() => {
        this.workPackages = this.workPackages.map((wp) => this.states.workPackages.get(wp.id!).getValueOr(wp));
        this.cdRef.detectChanges();
      });

    this.querySpace.results
      .values$()
      .pipe(
        withLatestFrom(this.querySpace.query.values$()),
        this.untilDestroyed(),
      ).subscribe(([results, query]) => {
        this.query = query;
        this.workPackages = this.wpViewOrder.orderedWorkPackages();
        this.cardView.updateRenderedCardsValues(this.workPackages);
        this.isResultEmpty = this.workPackages.length === 0;
        this.cdRef.detectChanges();
      });
  }

  ngAfterViewInit() {
    this.cardDragDrop.init(this);

    // Register Drag & Drop only on desktop
    if (!this.deviceService.isMobile) {
      this.cardDragDrop.registerDragAndDrop();
    }

    // Register event handlers for the cards
    const registry = this.injector.get<any>(WorkPackageViewHandlerToken, CardViewHandlerRegistry);
    if (registry instanceof CardViewHandlerRegistry) {
      registry.attachTo(this);
    } else {
      new registry(this.injector).attachTo(this);
    }
    this.wpTableSelection.registerSelectAllListener(() => this.cardView.renderedCards);
    this.wpTableSelection.registerDeselectAllListener();

    if (this.lazyHydrate) {
      this.setupLazyHydration();
    }
  }

  ngOnDestroy():void {
    super.ngOnDestroy();
    this.cardDragDrop.destroy();
    this.intersectionObserver?.disconnect();
  }

  /** Whether the card for the given work package should render its full content */
  public isHydrated(wp:WorkPackageResource):boolean {
    return !this.lazyHydrate || isNewResource(wp) || this.hydratedIds.has(wp.id!);
  }

  /** Hydrate a single card on demand (e.g. when it receives keyboard focus) */
  public hydrate(wp:WorkPackageResource):void {
    if (wp.id && !this.hydratedIds.has(wp.id)) {
      this.hydratedIds.add(wp.id);
      this.cdRef.detectChanges();
    }
  }

  /**
   * Observe every card host element; hydrate cards as they approach the viewport.
   * A single observer per card view is used and re-pointed whenever the rendered
   * set of cards changes (reorder, refresh, add/remove).
   */
  private setupLazyHydration():void {
    // Without IntersectionObserver (older browsers/webviews) there is no way to
    // detect when cards approach the viewport, so fall back to eager rendering
    // rather than leaving every card stuck as a placeholder.
    if (!('IntersectionObserver' in window)) {
      this.lazyHydrate = false;
      this.cdRef.detectChanges();
      return;
    }

    this.intersectionObserver = new IntersectionObserver(
      (entries) => this.onCardsIntersect(entries),
      { root: this.container.nativeElement as HTMLElement, rootMargin: '200px 0px', threshold: 0 },
    );

    this.observeAll();

    this.cardElements.changes
      .pipe(this.untilDestroyed())
      .subscribe(() => {
        this.pruneHydratedIds();
        this.observeAll();
      });
  }

  private observeAll():void {
    if (!this.intersectionObserver) {
      return;
    }

    this.intersectionObserver.disconnect();
    this.cardElements.forEach((ref) => this.intersectionObserver!.observe(ref.nativeElement));
  }

  private onCardsIntersect(entries:IntersectionObserverEntry[]):void {
    let changed = false;

    entries.forEach((entry) => {
      if (!entry.isIntersecting) {
        return;
      }

      const el = entry.target as HTMLElement;
      const id = el.dataset.workPackageId;
      if (id && !this.hydratedIds.has(id)) {
        this.hydratedIds.add(id);
        changed = true;
      }

      this.intersectionObserver!.unobserve(el);
    });

    if (changed) {
      this.cdRef.detectChanges();
    }
  }

  /** Drop hydrated ids that are no longer present after a reorder/refresh/remove */
  private pruneHydratedIds():void {
    if (this.hydratedIds.size === 0) {
      return;
    }

    const present = new Set(this.workPackages.map((wp) => wp.id!));
    this.hydratedIds.forEach((id) => {
      if (!present.has(id)) {
        this.hydratedIds.delete(id);
      }
    });
  }

  public get workPackages():WorkPackageResource[] {
    return this.cardDragDrop.workPackages;
  }

  public set workPackages(workPackages:WorkPackageResource[]) {
    this.cardDragDrop.workPackages = workPackages;
  }

  public setReferenceMode(mode:boolean) {
    this.inReference = mode;
    this.cdRef.detectChanges();
  }

  public addNewCard() {
    this.cardDragDrop.addNewCard();
  }

  public removeCard(wp:WorkPackageResource) {
    this.cardDragDrop.removeCard(wp);
  }

  async onCardSaved(wp:WorkPackageResource) {
    await this.cardDragDrop.onCardSaved(wp);
  }

  public classes() {
    let classes = 'wp-cards-container ';
    classes += `-${this.orientation}`;
    classes += this.shrinkOnMobile ? ' -shrink' : '';

    return classes;
  }

  /**
   * Listen to newly created work packages to detect whether the WP is the one we created,
   * and properly reset inline create in this case
   */
  private registerCreationCallback() {
    this.wpCreate
      .onNewWorkPackage()
      .pipe(
        this.untilDestroyed(),
      )
      .subscribe(async (wp:WorkPackageResource) => {
        this.onCardSaved(wp);
      });
  }
}
