import {
  AfterViewInit,
  ChangeDetectorRef,
  Component,
  inject,
  Input,
} from '@angular/core';
import { Board } from 'core-app/features/boards/board/board';
import { CurrentProjectService } from 'core-app/core/current-project/current-project.service';
import { WorkPackageStatesInitializationService } from 'core-app/features/work-packages/components/wp-list/wp-states-initialization.service';
import { IsolatedQuerySpace } from 'core-app/features/work-packages/directives/query-space/isolated-query-space';
import { WorkPackageViewFiltersService } from 'core-app/features/work-packages/routing/wp-view-base/view-services/wp-view-filters.service';
import { QueryFilterInstanceResource } from 'core-app/features/hal/resources/query-filter-instance-resource';
import { UrlParamsHelperService } from 'core-app/features/work-packages/components/wp-query/url-params-helper';
import { StateService } from '@uirouter/core';
import { debounceTime, skip, take } from 'rxjs/operators';
import { UntilDestroyedMixin } from 'core-app/shared/helpers/angular/until-destroyed.mixin';
import {
  firstValueFrom,
  Observable,
} from 'rxjs';
import { BoardFiltersService } from 'core-app/features/boards/board/board-filter/board-filters.service';
import { ApiV3Service } from 'core-app/core/apiv3/api-v3.service';
import { BoardActionsRegistryService } from 'core-app/features/boards/board/board-actions/board-actions-registry.service';
import { HalResource } from 'core-app/features/hal/resources/hal-resource';
import idFromLink from 'core-app/features/hal/helpers/id-from-link';
import {
  ApiV3Filter,
  ApiV3FilterValue,
  FilterOperator,
} from 'core-app/shared/helpers/api-v3/api-v3-filter-builder';
import { I18nService } from 'core-app/core/i18n/i18n.service';

interface QuickFilterOption {
  key:string;
  label:string;
  operator:'all'|FilterOperator;
  values:string[];
  identifier?:string;
}

const QUICK_FILTER_ALL = '__all__';
const QUICK_FILTER_NONE = '__none__';

@Component({
  selector: 'board-filter',
  templateUrl: './board-filter.component.html',
  styleUrls: ['./board-filter.component.sass'],
  standalone: false,
})
export class BoardFilterComponent extends UntilDestroyedMixin implements AfterViewInit {
  /** Current active */
  @Input() public board$:Observable<Board>;

  showQuickFilters = false;

  selectedAssignee = QUICK_FILTER_ALL;

  selectedVersion = QUICK_FILTER_ALL;

  assigneeOptions:QuickFilterOption[] = [];

  versionOptions:QuickFilterOption[] = [];

  text = {
    assignee: this.I18n.t('js.work_packages.properties.assignee'),
    version: this.I18n.t('js.work_packages.properties.version'),
    assignee_all: this.I18n.t('js.boards.quick_filters.assignee_all'),
    assignee_unassigned: this.I18n.t('js.boards.quick_filters.assignee_unassigned'),
    version_all: this.I18n.t('js.boards.quick_filters.version_all'),
    version_none: this.I18n.t('js.boards.quick_filters.version_none'),
  };

  initialized = false;

  private readonly cdRef = inject(ChangeDetectorRef);

  constructor(private readonly I18n:I18nService,
    private readonly currentProjectService:CurrentProjectService,
    private readonly querySpace:IsolatedQuerySpace,
    private readonly apiV3Service:ApiV3Service,
    private readonly wpStatesInitialization:WorkPackageStatesInitializationService,
    private readonly wpTableFilters:WorkPackageViewFiltersService,
    private readonly urlParamsHelper:UrlParamsHelperService,
    private readonly boardActions:BoardActionsRegistryService,
    private readonly boardFilters:BoardFiltersService,
    private readonly $state:StateService) {
    super();
  }

  ngAfterViewInit():void {
    if (!this.board$) {
      return;
    }

    this.board$
      .pipe(take(1))
      .subscribe((board) => {
        this.showQuickFilters = this.isKanbanBoard(board);

        const queryProps = this.$state.params.query_props;
        const baselineFilters = this.normalizeFilters(board.filters);
        const initialFilters = queryProps ? this.parseQueryProps(queryProps, baselineFilters) : baselineFilters;
        this.boardFilters.initialize(initialFilters, baselineFilters);

        this.configureHiddenFilters(board);

        // Initially load the form once to be able to render filters
        this.loadQueryForm(initialFilters);

        // Update checksum service whenever filters change
        this.updateChecksumOnFilterChanges();

        if (this.showQuickFilters) {
          this.observeQuickFilterSelection();
          void this.initializeQuickFilters();
        }
      });
  }

  onAssigneeQuickFilterChange(key:string) {
    this.selectedAssignee = key;
    this.applyQuickFilterSelection('assignee', key, this.assigneeOptions);
  }

  onVersionQuickFilterChange(key:string) {
    this.selectedVersion = key;
    this.applyQuickFilterSelection('version', key, this.versionOptions);
  }

  private updateChecksumOnFilterChanges() {
    this.wpTableFilters
      .live$()
      .pipe(
        this.untilDestroyed(),
        skip(1),
        debounceTime(250),
      )
      .subscribe(() => {
        const filters:QueryFilterInstanceResource[] = this.wpTableFilters.current;
        const filterHash:ApiV3Filter[] = this.urlParamsHelper.buildV3GetFilters(filters);

        this.boardFilters.updatePersisted(filterHash);

        const query_props = this.boardFilters.hasPersistedChanges ? JSON.stringify(filterHash) : null;
        this.$state.go('.', { query_props }, { custom: { notify: false } });
      });
  }

  private loadQueryForm(filters:ApiV3Filter[]) {
    this
      .apiV3Service
      .queries
      .form
      .loadWithParams(
        { filters: JSON.stringify(filters) },
        undefined,
        this.currentProjectService.id,
      )
      .subscribe(([form, query]) => {
        this.querySpace.query.putValue(query);
        this.wpStatesInitialization.updateStatesFromForm(query, form);
      });
  }

  private configureHiddenFilters(board:Board) {
    if (board.isAction) {
      this.hideFilter(board.actionAttribute!);
    }
  }

  private hideFilter(filterName:string) {
    if (!this.wpTableFilters.hidden.includes(filterName)) {
      this.wpTableFilters.hidden.push(filterName);
    }
  }

  private isKanbanBoard(board:Board):boolean {
    return board.isAction && board.actionAttribute === 'status';
  }

  private async initializeQuickFilters() {
    const assigneeFallback = [
      this.quickFilterOption(QUICK_FILTER_ALL, this.text.assignee_all, 'all', []),
      this.quickFilterOption(QUICK_FILTER_NONE, this.text.assignee_unassigned, '!*', []),
    ];
    const versionFallback = [
      this.quickFilterOption(QUICK_FILTER_ALL, this.text.version_all, 'all', []),
      this.quickFilterOption(QUICK_FILTER_NONE, this.text.version_none, '!*', []),
    ];

    this.assigneeOptions = assigneeFallback;
    this.versionOptions = versionFallback;

    let assignees:HalResource[] = [];
    let versions:HalResource[] = [];

    try {
      [assignees, versions] = await Promise.all([
        firstValueFrom(this.boardActions.get('assignee').loadAvailable(new Set<string>(), '')),
        firstValueFrom(this.boardActions.get('version').loadAvailable(new Set<string>(), '')),
      ]);
    } catch (error) {
      // Keep the fallback options on failure, but surface the error rather
      // than swallowing it silently.
      console.error('Failed to load board quick filter options', error);
    }

    // The component may have been torn down while the options were loading.
    if (this.componentDestroyed) {
      return;
    }

    this.assigneeOptions = [
      ...assigneeFallback,
      ...assignees
        .filter((assignee) => this.assigneeOptionAllowed(assignee))
        .map((assignee) => this.resourceFilterOption(assignee)),
    ];

    this.versionOptions = [
      ...versionFallback,
      ...versions.map((version) => this.resourceFilterOption(version)),
    ];

    this.syncQuickFilterSelections();

    // The option lists load after an awaited HAL request that resolves outside
    // Angular's change detection, and this component sits under OnPush
    // ancestors, so a global tick would skip it. Run change detection on this
    // view directly so the quick-filter selects render the loaded options
    // instead of only the synchronously-set fallbacks.
    this.cdRef.detectChanges();
  }

  private quickFilterOption(
    key:string,
    label:string,
    operator:'all'|FilterOperator,
    values:string[],
    identifier?:string,
  ):QuickFilterOption {
    return {
      key,
      label,
      operator,
      values,
      identifier,
    };
  }

  private resourceFilterOption(resource:HalResource):QuickFilterOption {
    const identifier = this.valueIdentifier(resource)!;
    return this.quickFilterOption(`id:${identifier}`, resource.name, '=', [identifier], identifier);
  }

  private assigneeOptionAllowed(assignee:HalResource):boolean {
    const assigneeType = (assignee as { _type?:string })._type;
    if (assignee.id === null || assigneeType !== 'User') {
      return false;
    }

    return !!this.valueIdentifier(assignee);
  }

  private applyQuickFilterSelection(
    filterName:'assignee'|'version',
    key:string,
    options:QuickFilterOption[],
  ) {
    const filterKey = this.currentFilterKey(filterName);
    const selected = options.find((option) => option.key === key);

    if (!selected || selected.operator === 'all') {
      this.boardFilters.setTemporary(filterKey, null);
      return;
    }

    this.boardFilters.setTemporary(filterKey, {
      [filterKey]: {
        operator: selected.operator,
        values: selected.values,
      },
    });
  }

  private syncQuickFilterSelections() {
    this.selectedAssignee = this.selectedQuickFilter('assignee', this.assigneeOptions);
    this.selectedVersion = this.selectedQuickFilter('version', this.versionOptions);
  }

  private selectedQuickFilter(
    filterName:'assignee'|'version',
    options:QuickFilterOption[],
  ) {
    const filter = this.currentFilterValue(filterName);
    if (!filter) {
      return QUICK_FILTER_ALL;
    }

    if (filter.operator === '!*') {
      return QUICK_FILTER_NONE;
    }

    if (filter.operator !== '=') {
      return QUICK_FILTER_ALL;
    }

    const identifier = this.valueIdentifier(filter.values[0] as string|number|undefined);
    const selectedOption = options.find((option) => option.identifier === identifier);

    return selectedOption?.key ?? QUICK_FILTER_ALL;
  }

  private currentFilterValue(filterName:'assignee'|'version'):ApiV3FilterValue|undefined {
    const filter = this.currentFilterEntry(filterName);
    const key = filter && Object.keys(filter)[0];

    if (!filter || !key) {
      return undefined;
    }

    return filter[key];
  }

  private currentFilterKey(filterName:'assignee'|'version'):string {
    const filter = this.currentFilterEntry(filterName);
    return filter ? (Object.keys(filter)[0] || filterName) : filterName;
  }

  private currentFilterEntry(filterName:'assignee'|'version'):ApiV3Filter|undefined {
    const filterKeys = this.filterKeys(filterName);
    return this.boardFilters.current.find((currentFilter) => filterKeys.includes(Object.keys(currentFilter)[0]));
  }

  private filterKeys(filterName:'assignee'|'version'):string[] {
    if (filterName === 'assignee') {
      return ['assignee', 'assignee_id', 'assigned_to_id'];
    }

    return ['version', 'version_id'];
  }

  private valueIdentifier(value:HalResource|string|number|undefined|null):string|undefined {
    if (value === null || value === undefined) {
      return undefined;
    }

    if (typeof value === 'string' || typeof value === 'number') {
      return value.toString();
    }

    if (value.id !== null && value.id !== undefined) {
      return value.id.toString();
    }

    if (value.href) {
      return idFromLink(value.href);
    }

    return undefined;
  }

  private observeQuickFilterSelection() {
    this.boardFilters
      .filters
      .values$()
      .pipe(
        this.untilDestroyed(),
      )
      .subscribe(() => this.syncQuickFilterSelections());
  }

  private parseQueryProps(queryProps:string, fallback:ApiV3Filter[]):ApiV3Filter[] {
    try {
      const parsed = JSON.parse(queryProps) as unknown;
      return this.normalizeFilters(parsed);
    } catch {
      return fallback;
    }
  }

  private normalizeFilters(filters:unknown):ApiV3Filter[] {
    return Array.isArray(filters) ? filters as ApiV3Filter[] : [];
  }
}
