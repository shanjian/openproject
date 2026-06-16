import {
  ChangeDetectionStrategy,
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  Injector,
  Input,
  OnDestroy,
  OnInit,
  Output,
  ViewChild,
} from '@angular/core';
import {
  LoadingIndicatorService,
  withLoadingIndicator,
} from 'core-app/core/loading-indicator/loading-indicator.service';
import { WorkPackageInlineCreateService } from 'core-app/features/work-packages/components/wp-inline-create/wp-inline-create.service';
import { BoardInlineCreateService } from 'core-app/features/boards/board/board-list/board-inline-create.service';
import { AbstractWidgetComponent } from 'core-app/shared/components/grids/widgets/abstract-widget.component';
import { I18nService } from 'core-app/core/i18n/i18n.service';
import { ToastService } from 'core-app/shared/components/toaster/toast.service';
import { IsolatedQuerySpace } from 'core-app/features/work-packages/directives/query-space/isolated-query-space';
import { Board } from 'core-app/features/boards/board/board';
import { AuthorisationService } from 'core-app/core/model-auth/model-auth.service';
import { Highlighting } from 'core-app/features/work-packages/components/wp-fast-table/builders/highlighting/highlighting.functions';
import { WorkPackageCardViewComponent } from 'core-app/features/work-packages/components/wp-card-view/wp-card-view.component';
import { WorkPackageStatesInitializationService } from 'core-app/features/work-packages/components/wp-list/wp-states-initialization.service';
import { BoardService } from 'core-app/features/boards/board/board.service';
import { HalResourceEditingService } from 'core-app/shared/components/fields/edit/services/hal-resource-editing.service';
import { HalResourceNotificationService } from 'core-app/features/hal/services/hal-resource-notification.service';
import { BoardActionsRegistryService } from 'core-app/features/boards/board/board-actions/board-actions-registry.service';
import { BoardActionService } from 'core-app/features/boards/board/board-actions/board-action.service';
import { ComponentType } from '@angular/cdk/portal';
import { CausedUpdatesService } from 'core-app/features/boards/board/caused-updates/caused-updates.service';
import { BoardListMenuComponent } from 'core-app/features/boards/board/board-list/board-list-menu.component';
import { debugLog } from 'core-app/shared/helpers/debug_output';
import { WorkPackageCardDragAndDropService } from 'core-app/features/work-packages/components/wp-card-view/services/wp-card-drag-and-drop.service';
import { BoardFiltersService } from 'core-app/features/boards/board/board-filter/board-filters.service';
import {
  StateService,
  TransitionService,
} from '@uirouter/core';
import { WorkPackageViewFocusService } from 'core-app/features/work-packages/routing/wp-view-base/view-services/wp-view-focus.service';
import { WorkPackageViewSelectionService } from 'core-app/features/work-packages/routing/wp-view-base/view-services/wp-view-selection.service';
import { BoardListCrossSelectionService } from 'core-app/features/boards/board/board-list/board-list-cross-selection.service';
import {
  debounceTime,
  filter,
  map,
} from 'rxjs/operators';
import { ChangeItem } from 'core-app/shared/components/fields/changeset/changeset';
import { WorkPackageChangeset } from 'core-app/features/work-packages/components/wp-edit/work-package-changeset';
import { SchemaCacheService } from 'core-app/core/schemas/schema-cache.service';
import { ApiV3Service } from 'core-app/core/apiv3/api-v3.service';
import { ApiV3Filter } from 'core-app/shared/helpers/api-v3/api-v3-filter-builder';
import { KeepTabService } from 'core-app/features/work-packages/components/wp-single-view-tabs/keep-tab/keep-tab.service';
import { HalResource } from 'core-app/features/hal/resources/hal-resource';
import { QueryResource } from 'core-app/features/hal/resources/query-resource';
import {
  HalEvent,
  HalEventsService,
} from 'core-app/features/hal/services/hal-events.service';
import { WorkPackageResource } from 'core-app/features/hal/resources/work-package-resource';
import { markPartialWorkPackage } from 'core-app/features/hal/helpers/partial-work-package';
import { firstValueFrom } from 'rxjs';
import { WorkPackageIsolatedQuerySpaceDirective } from 'core-app/features/work-packages/directives/query-space/wp-isolated-query-space.directive';
import { CurrentProjectService } from 'core-app/core/current-project/current-project.service';
import { PathHelperService } from 'core-app/core/path-helper/path-helper.service';
import { TimezoneService } from 'core-app/core/datetime/timezone.service';

export interface DisabledButtonPlaceholder {
  text:string;
  icon:string;
}

@Component({
  selector: 'board-list',
  templateUrl: './board-list.component.html',
  styleUrls: ['./board-list.component.sass'],
  changeDetection: ChangeDetectionStrategy.OnPush,
  hostDirectives: [WorkPackageIsolatedQuerySpaceDirective],
  providers: [
    { provide: WorkPackageInlineCreateService, useClass: BoardInlineCreateService },
    BoardListMenuComponent,
    WorkPackageCardDragAndDropService,
  ],
  standalone: false,
})
export class BoardListComponent extends AbstractWidgetComponent implements OnInit, OnDestroy {
  /** Output fired upon query removal */
  @Output() onRemove = new EventEmitter<void>();

  /* Output fired after it is assured whether a user has the right to see the list */
  @Output() visibilityChange = new EventEmitter<boolean>();

  /** Access to the board resource */
  @Input() public board:Board;

  /** Access to the loading indicator element */
  @ViewChild('loadingIndicator', { static: true }) indicator:ElementRef<HTMLElement>;

  /** Access to the card view */
  @ViewChild(WorkPackageCardViewComponent) cardView:WorkPackageCardViewComponent;

  /** The query resource being loaded */
  public query:QueryResource;

  /** Query loading error, if present */
  public loadingError:string|undefined;

  /** The action attribute resource if any */
  public actionResource:HalResource|undefined;

  public actionResourceClass = '';

  public headerComponent:ComponentType<unknown>|undefined;

  /** Rename inFlight */
  public inFlight:boolean;

  /** Whether the add button should be shown */
  public showAddButton = false;

  private canAdd = firstValueFrom(this.wpInlineCreate.canAdd);

  public columnsQueryProps:any;

  /** Query props for the lightweight, non-blocking column totals request (assignee boards) */
  private sumsQueryProps:any;

  /**
   * The minimal set of fields a board card needs. Requesting these via `select`
   * routes the API through the SQL-projected representer (links + a few columns)
   * instead of serialising the full work package + embedded schemas for every
   * card, which is what kept the per-column loading spinner up. Status/type/
   * priority colors still render from their ids via the global highlighting CSS;
   * the assignee avatar is intentionally dropped for speed.
   */
  private static readonly cardSelectFields = [
    'elements/id',
    'elements/subject',
    'elements/status',
    'elements/type',
    'elements/priority',
    'elements/project',
    'elements/startDate',
    'elements/dueDate',
    // Compact card metadata line (story points, work, epic). storyPoints and
    // estimatedHours are bare columns; epic is a single indexed self-join in the
    // SQL representer - all still on the fast projection path.
    'elements/storyPoints',
    'elements/estimatedHours',
    'elements/epic',
    // Ask for the collection total so the column knows whether it is truncated by
    // the page size and can offer "load more". Without this the SQL projection
    // returns total = -1 (the count is only computed when explicitly selected).
    'total',
  ];

  /**
   * Page size for the initial column load. Matches the historical effective cap
   * (Setting.forced_single_page_size default) so existing boards render exactly as
   * before; columns with more cards now expose a "load more" control instead of
   * silently truncating. Each "load more" grows the single top-anchored page by
   * {@link pageSizeIncrement} (manual sort always renders one contiguous page).
   */
  private static readonly initialPageSize = 250;

  private static readonly pageSizeIncrement = 250;

  /** Current target page size for this column; grown by loadMoreCards(). */
  private currentPageSize = BoardListComponent.initialPageSize;

  /** Number of cards currently loaded in this column. */
  public loadedCount = 0;

  /** Total number of cards matching this column, regardless of the page size. */
  public totalCount = 0;

  /** Whether a "load more" request is in flight. */
  public loadingMore = false;

  /** Accumulated story points across the column's work packages, or null when not summable */
  public storyPointsSum:number|null = null;

  /** Accumulated estimated time across the column's work packages, formatted for display, or null when not summable */
  public estimatedTimeSum:string|null = null;

  public text = {
    addCard: this.I18n.t('js.boards.add_card'),
    updateSuccessful: this.I18n.t('js.notice_successful_update'),
    areYouSure: this.I18n.t('js.text_are_you_sure'),
    unnamed_list: this.I18n.t('js.boards.label_unnamed_list'),
    click_to_remove: this.I18n.t('js.boards.click_to_remove_list'),
    loadMore: this.I18n.t('js.boards.load_more'),
    loadingMore: this.I18n.t('js.boards.loading_more'),
    totals: {
      story_points: this.I18n.t('js.boards.totals.story_points'),
      estimated_time: this.I18n.t('js.boards.totals.estimated_time'),
    },
  };

  /** Are we allowed to remove and drag & drop elements ? */
  public canDragInto = false;

  /** Initially focus the list */
  public initiallyFocused = false;

  /** Editing handler to be passed into card component */
  public workPackageAddedHandler = (workPackage:WorkPackageResource) => this.addWorkPackage(workPackage);

  /** Move check to be passed into card component */
  public canDragOutOf = false;

  public canDragOutOfHandler = (workPackage:WorkPackageResource) => this.canMove(workPackage);

  public buttonPlaceholder:DisabledButtonPlaceholder|undefined;

  constructor(
    readonly apiv3Service:ApiV3Service,
    readonly I18n:I18nService,
    readonly state:StateService,
    readonly cdRef:ChangeDetectorRef,
    readonly transitions:TransitionService,
    readonly boardFilters:BoardFiltersService,
    readonly toastService:ToastService,
    readonly querySpace:IsolatedQuerySpace,
    readonly halNotification:HalResourceNotificationService,
    readonly halEvents:HalEventsService,
    readonly wpStatesInitialization:WorkPackageStatesInitializationService,
    readonly wpViewFocusService:WorkPackageViewFocusService,
    readonly wpViewSelectionService:WorkPackageViewSelectionService,
    readonly boardListCrossSelectionService:BoardListCrossSelectionService,
    readonly authorisationService:AuthorisationService,
    readonly wpInlineCreate:WorkPackageInlineCreateService,
    readonly injector:Injector,
    readonly halEditing:HalResourceEditingService,
    readonly loadingIndicator:LoadingIndicatorService,
    readonly schemaCache:SchemaCacheService,
    readonly boardService:BoardService,
    readonly boardActionRegistry:BoardActionsRegistryService,
    readonly causedUpdates:CausedUpdatesService,
    readonly keepTab:KeepTabService,
    readonly currentProject:CurrentProjectService,
    readonly pathHelper:PathHelperService,
    readonly timezoneService:TimezoneService,
  ) {
    super(I18n, injector);
  }

  ngOnInit():void {
    // Unset the isNew flag
    this.initiallyFocused = this.resource.isNewWidget;
    this.resource.isNewWidget = false;

    // Set initial selection if split view open
    if (this.state.includes(`${this.state.current.data.baseRoute}.details`)) {
      const wpId = this.state.params.workPackageId;
      this.wpViewSelectionService.initializeSelection([wpId]);
    }

    // If this query space changes its focused or selected
    // work packages, update the board cross selection
    this
      .wpViewSelectionService
      .updates$()
      .pipe(
        debounceTime(100),
        this.untilDestroyed(),
      )
      .subscribe((selectionState) => {
        const selected = Object.keys(_.pickBy(selectionState.selected, (option, _) => option === true));

        const focused = this.wpViewFocusService.focusedWorkPackage;

        this.boardListCrossSelectionService.updateSelection({
          withinQuery: this.queryId,
          focusedWorkPackage: focused,
          allSelected: selected,
        });
      });

    // Apply focus and selection when changed in cross service
    this.boardListCrossSelectionService
      .selectionsForQuery(this.queryId)
      .pipe(
        this.untilDestroyed(),
      )
      .subscribe((selection) => {
        this.wpViewSelectionService.initializeSelection(selection.allSelected);
      });

    // Update query on filter change
    this.boardFilters
      .filters
      .values$()
      .pipe(
        this.untilDestroyed(),
      )
      .subscribe(() => {
        // A different filter set is a different result set, so start back at the
        // first page rather than keeping a previously grown page size.
        this.currentPageSize = BoardListComponent.initialPageSize;
        this.updateQuery(true);
      });

    // Listen to changes to action attribute
    this.listenToActionAttributeChanges();

    this.querySpace.query
      .values$()
      .pipe(
        this.untilDestroyed(),
      )
      // eslint-disable-next-line @typescript-eslint/no-misused-promises
      .subscribe(async (query) => {
        this.query = query;
        this.canDragOutOf = !!this.query.updateOrderedWorkPackages;
        await this.loadActionAttribute(query);
        this.cdRef.detectChanges();
      });
  }

  ngOnDestroy() {
    super.ngOnDestroy();
  }

  public get errorMessage() {
    return this.I18n.t('js.boards.error_loading_the_list', { error_message: this.loadingError });
  }

  public canMove(workPackage:WorkPackageResource) {
    return this.canDragOutOf && (!this.actionService || this.actionService.canMove(workPackage));
  }

  public get canManage() {
    return this.boardService.canManage(this.board);
  }

  public get canRename() {
    return this.canManage
      && !!this.query.updateImmediately
      && this.board.isFree;
  }

  public addReferenceCard() {
    this.cardView.setReferenceMode(true);
  }

  public addNewCard() {
    this.cardView.addNewCard();
  }

  public deleteList(query?:QueryResource) {
    query = query || this.query;

    if (!window.confirm(this.text.areYouSure)) {
      return;
    }

    this
      .apiv3Service
      .queries
      .id(query)
      .delete()
      .subscribe(() => this.onRemove.emit());
  }

  public renameQuery(query:QueryResource, value:string) {
    this.inFlight = true;
    this.query.name = value;
    this
      .apiv3Service
      .queries
      .id(this.query)
      .patch({ name: value })
      .subscribe(
        () => {
          this.inFlight = false;
          this.toastService.addSuccess(this.text.updateSuccessful);
        },
        (_error) => this.inFlight = false,
      );
  }

  private boardListActionColorClass(value?:HalResource):string {
    const attribute = this.board.actionAttribute!;
    if (value?.id) {
      return Highlighting.backgroundClass(attribute, value.id);
    }
    return '';
  }

  public get listName() {
    return this.query && this.query.name;
  }

  public showCardStatusButton() {
    return this.board.showStatusButton();
  }

  public refreshQueryUnlessCaused(query:QueryResource, visibly = true) {
    if (!this.causedUpdates.includes(query)) {
      debugLog(`Refreshing ${query.name} visibly due to external changes`);
      this.updateQuery(visibly);
    }
  }

  public updateQuery(visibly = true) {
    this.setQueryProps(this.boardFilters.current);
    this.loadQuery(visibly);
    this.loadColumnTotals();
  }

  private get columnFilters():ApiV3Filter[] {
    return (this.resource.options.filters || []) as ApiV3Filter[];
  }

  /**
   * The open-status filter we add/remove to hide/show closed work packages.
   * It lives in the widget's persisted `options.filters` — the same channel
   * the action attribute filter rides — so it is reliably applied on every
   * column load (unlike a separate boolean flag, which was not).
   */
  private isOpenStatusFilter(filter:ApiV3Filter):boolean {
    return 'status' in filter && filter.status.operator === 'o';
  }

  /**
   * Whether this column shows closed work packages. Derived from the presence
   * of the open-status filter so the menu state and the actual query can never
   * disagree. Boards include closed by default (no filter present).
   */
  public get includeClosed():boolean {
    return !this.columnFilters.some((filter) => this.isOpenStatusFilter(filter));
  }

  /**
   * Persists the per-column "include closed items" state by adding/removing the
   * open-status filter on the widget (shared board config) and reloads the
   * column.
   */
  public setIncludeClosed(includeClosed:boolean):void {
    const filters = this.columnFilters.filter((filter) => !this.isOpenStatusFilter(filter));
    if (!includeClosed) {
      filters.push({ status: { operator: 'o', values: [] } });
    }

    this.resource.options = { ...this.resource.options, filters };
    // Reflect the new state in the (re-opened) menu and header right away,
    // independent of the board save round-trip.
    this.cdRef.detectChanges();
    this.updateQuery(true);
    this.boardService
      .save(this.board)
      .subscribe(
        () => this.toastService.addSuccess(this.text.updateSuccessful),
        (_error:unknown) => this.halNotification.handleRawError(_error),
      );
  }

  /** Whether this column shows accumulated story point / estimated time totals */
  private get showsTotals():boolean {
    return this.board.actionAttribute === 'assignee';
  }

  /**
   * Whether cards should show the assignee name. Suppressed on assignee boards,
   * where every card in a column has the same assignee (the column is the
   * assignee), so it would be redundant. Shown on all other board types.
   */
  public get showAssigneeName():boolean {
    return this.board.actionAttribute !== 'assignee';
  }

  private async loadActionAttribute(query:QueryResource):Promise<void> {
    if (!this.board.isAction) {
      this.actionResource = undefined;
      this.headerComponent = undefined;
      this.canDragInto = !!query.updateOrderedWorkPackages;
      const canAdd = await this.canAdd;
      this.showAddButton = this.canDragInto && canAdd;
      return;
    }

    const actionService = this.actionService!;
    const id = actionService.getActionValueId(query);

    // Test if we loaded the resource already
    if (this.actionResource && id === this.actionResource.href) {
      return;
    }

    // Load the resource
    return actionService
      .getLoadedActionValue(query)
      .then(async (resource) => {
        this.actionResource = resource;
        this.headerComponent = actionService.headerComponent();
        this.buttonPlaceholder = actionService.disabledAddButtonPlaceholder(resource);
        this.actionResourceClass = this.boardListActionColorClass(resource);
        this.canDragInto = actionService.dragIntoAllowed(query, resource);

        const canWriteAttribute = await actionService.canAddToQuery(query);
        const canAdd = await this.canAdd;
        this.showAddButton = this.canDragInto && canAdd && canWriteAttribute;
        this.cdRef.detectChanges();
      });
  }

  /**
   * Return the linked action service
   */
  private get actionService():BoardActionService|undefined {
    if (this.board.actionAttribute) {
      return this.boardActionRegistry.get(this.board.actionAttribute);
    }

    return undefined;
  }

  /**
   * Handler to properly update the work package, when
   * adding to this query requires saving a changeset.
   * @param workPackage
   */
  private addWorkPackage(workPackage:WorkPackageResource) {
    const query = this.querySpace.query.value!;
    const changeset:WorkPackageChangeset = this.halEditing.changeFor(workPackage);

    // Assign to the action attribute if this is an action board
    this.actionService?.assignToWorkPackage(changeset, query);

    if (changeset.isEmpty()) {
      // Ensure work package and its schema is loaded
      return this.apiv3Service.work_packages.cache.updateWorkPackage(workPackage);
    }
    // Save changes to the work package, which reloads it as well
    return this.halEditing.save(changeset);
  }

  private get queryId():string {
    return (this.resource.options.queryId as number|string).toString();
  }

  private loadQuery(visibly = true) {
    let observable = this
      .apiv3Service
      .queries
      .find(this.columnsQueryProps, this.queryId);

    // Spread arguments on pipe does not work:
    // https://github.com/ReactiveX/rxjs/issues/3989
    if (visibly) {
      observable = observable.pipe(withLoadingIndicator(this.indicatorInstance, 50));
    }

    observable
      .subscribe(
        (query) => {
          // The board fetches a projected `select` payload, so these work packages are
          // partial. Mark them before they enter the shared cache so the detail/full
          // view reloads the complete resource instead of rendering the card subset.
          query.results.elements.forEach((wp) => markPartialWorkPackage(wp));
          this.wpStatesInitialization.updateQuerySpace(query, query.results);
          this.updateCardCounts(query);
          this.loadingMore = false;
          this.cdRef.markForCheck();
        },
        (error) => {
          this.loadingMore = false;
          const userIsNotAllowedToSeeSubprojectError = 'urn:openproject-org:api:v3:errors:InvalidQuery';
          // eslint-disable-next-line @typescript-eslint/no-unsafe-member-access
          if (error.errorIdentifier === userIsNotAllowedToSeeSubprojectError) {
            this.visibilityChange.emit(false);
          }
          this.loadingError = this.halNotification.retrieveErrorMessage(error);
          this.cdRef.detectChanges();
        },
      );
  }

  private get indicatorInstance() {
    return this.loadingIndicator.indicator(this.indicator.nativeElement);
  }

  /**
   * Record how many of the column's cards are loaded versus how many match in
   * total. `total` is -1 when the API could not compute it (e.g. the `total`
   * select was dropped); guard against that so we never offer a misleading
   * "load more".
   */
  private updateCardCounts(query:QueryResource):void {
    this.loadedCount = query.results.count;
    this.totalCount = query.results.total;
  }

  /** Whether the column holds more cards than are currently loaded. */
  public get hasMoreCards():boolean {
    return this.totalCount > this.loadedCount;
  }

  /** Human-readable "showing X of Y" label for the load-more control. */
  public get cardsShownText():string {
    return this.I18n.t('js.boards.cards_shown', { loaded: this.loadedCount, total: this.totalCount });
  }

  /**
   * Grow the single top-anchored page and reload the column. We re-fetch from the
   * top (rather than appending an offset window) because manual sort requires a
   * contiguous page for stable drag positions; see the server-side
   * `manually_sorted_page_size`. Loaded invisibly so only the button shows a
   * pending state instead of flashing the whole-column spinner.
   */
  public loadMoreCards():void {
    if (this.loadingMore || !this.hasMoreCards) {
      return;
    }

    this.loadingMore = true;
    this.currentPageSize += BoardListComponent.pageSizeIncrement;
    this.setQueryProps(this.boardFilters.current);
    this.loadQuery(false);
  }

  /**
   * Load the column totals (story points / estimated time) for assignee boards.
   *
   * The card payload uses the `select` path, which does not return `totalSums`,
   * so the totals are fetched in a separate, cheap request that asks for the
   * sums only (`pageSize: 0` skips hydrating any work packages). It is NOT
   * wrapped in the loading indicator, so it fills in asynchronously without
   * prolonging the column spinner.
   */
  private loadColumnTotals() {
    if (!this.showsTotals) {
      this.updateTotals(undefined);
      return;
    }

    this
      .apiv3Service
      .queries
      .find(this.sumsQueryProps, this.queryId)
      .subscribe(
        (query) => {
          this.updateTotals(query.results.totalSums);
          this.cdRef.markForCheck();
        },
        // Totals are non-critical; ignore errors (the cards themselves report load failures)
        () => undefined,
      );
  }

  private setQueryProps(filters:ApiV3Filter[]) {
    const existingFilters = (this.resource.options.filters || []) as ApiV3Filter[];

    // The open-status filter (when closed items are hidden) is part of
    // `options.filters`, so it flows through here like any other column filter.
    const newFilters = existingFilters.concat(filters);
    const serializedFilters = JSON.stringify(newFilters);

    const selectFields = [...BoardListComponent.cardSelectFields];
    if (this.showAssigneeName) {
      selectFields.push('elements/assignee');
    }

    this.columnsQueryProps = {
      select: selectFields.join(','),
      showHierarchies: false,
      pageSize: this.currentPageSize,
      filters: serializedFilters,
    };

    // Sums-only request used by loadColumnTotals (no select -> full path returns totalSums;
    // pageSize 0 -> aggregate only, no work packages hydrated).
    this.sumsQueryProps = {
      showSums: true,
      pageSize: 0,
      filters: serializedFilters,
    };
  }

  private updateTotals(totalSums:Record<string, unknown>|undefined):void {
    if (!totalSums) {
      this.storyPointsSum = null;
      this.estimatedTimeSum = null;
      return;
    }

    const storyPoints = totalSums.storyPoints as number|null|undefined;
    this.storyPointsSum = typeof storyPoints === 'number' && storyPoints > 0 ? storyPoints : null;

    const estimatedTime = totalSums.estimatedTime as string|null|undefined;
    if (estimatedTime && this.timezoneService.toHours(estimatedTime) > 0) {
      // Days + hours per the instance's duration format (e.g. 8h -> "1d"), to match
      // the per-card Work display and the rest of OpenProject.
      this.estimatedTimeSum = this.timezoneService.formattedChronicDuration(estimatedTime);
    } else {
      this.estimatedTimeSum = null;
    }
  }

  private listenToActionAttributeChanges() {
    // If we don't have an action attribute
    // nothing to do
    if (!this.board.actionAttribute) {
      return;
    }

    // Listen to hal events to detect changes to an action attribute
    this.halEvents
      .events$
      .pipe(
        filter((event) => event.resourceType === 'WorkPackage'),
        // Only allow updates, otherwise this causes an error reloading the list
        // before the work package can be added to the query order
        filter((event) => event.eventType === 'updated'),
        map((event:HalEvent) => event.commit?.changes[this.actionService!.filterName]),
        filter((value) => !!value),
        filter((value:ChangeItem) => {
          // Compare the from and to values from the committed changes
          // with the current actionResource
          const current = this.actionResource?.href;
          const to = (value.to as HalResource|undefined)?.href;
          const from = (value.from as HalResource|undefined)?.href;

          return !!current && (current === to || current === from);
        }),
      )
      .subscribe(() => {
        this.updateQuery(true);
      });
  }

  openFullViewOnDoubleClick(event:{ workPackageId:string, double:boolean }) {
    if (event.double) {
      const projectIdentifier = this.currentProject.identifier;
      const link = this.pathHelper.genericWorkPackagePath(projectIdentifier, event.workPackageId) + window.location.search;
      Turbo.visit(link, { action: 'advance' });
    }
  }

  openStateLink(event:{ workPackageId:string; requestedState:string }) {
    const params = { workPackageId: event.workPackageId };

    if (event.requestedState === 'split') {
      this.keepTab.goCurrentDetailsState(params);
    } else {
      this.keepTab.goCurrentShowState(params.workPackageId);
    }
  }

  private schema(workPackage:WorkPackageResource) {
    return this.schemaCache.of(workPackage);
  }
}
