import {
  ChangeDetectionStrategy,
  ChangeDetectorRef,
  Component,
  EventEmitter, inject,
  Input,
  OnChanges,
  OnInit,
  Output,
  SimpleChanges,
} from '@angular/core';
import {
  uiStateLinkClass,
} from 'core-app/features/work-packages/components/wp-fast-table/builders/ui-state-link-builder';
import { PathHelperService } from 'core-app/core/path-helper/path-helper.service';
import {
  Highlighting,
} from 'core-app/features/work-packages/components/wp-fast-table/builders/highlighting/highlighting.functions';
import { StateService, UIRouterGlobals } from '@uirouter/core';
import {
  WorkPackageViewSelectionService,
} from 'core-app/features/work-packages/routing/wp-view-base/view-services/wp-view-selection.service';
import {
  WorkPackageCardViewService,
} from 'core-app/features/work-packages/components/wp-card-view/services/wp-card-view.service';
import { I18nService } from 'core-app/core/i18n/i18n.service';
import {
  CardHighlightingMode,
} from 'core-app/features/work-packages/components/wp-fast-table/builders/highlighting/highlighting-mode.const';
import { CardViewOrientation } from 'core-app/features/work-packages/components/wp-card-view/wp-card-view.component';
import { UntilDestroyedMixin } from 'core-app/shared/helpers/angular/until-destroyed.mixin';
import {
  WorkPackageViewFocusService,
} from 'core-app/features/work-packages/routing/wp-view-base/view-services/wp-view-focus.service';
import { WorkPackageResource } from 'core-app/features/hal/resources/work-package-resource';
import { isClickedWithModifier } from 'core-app/shared/helpers/link-handling/link-handling';
import isNewResource from 'core-app/features/hal/helpers/is-new-resource';
import { TimezoneService } from 'core-app/core/datetime/timezone.service';
import { StatusResource } from 'core-app/features/hal/resources/status-resource';
import { combineLatest } from 'rxjs';
import { map } from 'rxjs/operators';
import { SchemaCacheService } from 'core-app/core/schemas/schema-cache.service';
import SpotDropAlignmentOption from 'core-app/spot/drop-alignment-options';
import { BaselineMode, getBaselineState } from 'core-app/features/work-packages/components/wp-baseline/baseline-helpers';
import {
  CombinedDateDisplayField,
} from 'core-app/shared/components/fields/display/field-types/combined-date-display.field';
import {
  KeepTabService
} from 'core-app/features/work-packages/components/wp-single-view-tabs/keep-tab/keep-tab.service';

@Component({
  selector: 'wp-single-card',
  styleUrls: ['./wp-single-card.component.sass'],
  templateUrl: './wp-single-card.component.html',
  changeDetection: ChangeDetectionStrategy.OnPush,
  standalone: false,
})
export class WorkPackageSingleCardComponent extends UntilDestroyedMixin implements OnInit, OnChanges {
  @Input() public workPackage:WorkPackageResource;

  @Input() public selectedWhenOpen = false;

  /**
   * Whether the card's expensive content and its selection subscription are
   * rendered. Defaults to true so existing callers (wp-grid, team planner) are
   * unaffected. Boards set this to false initially and flip it to true once the
   * card scrolls near the viewport (see WorkPackageCardViewComponent lazy hydration).
   */
  @Input() public hydrated = true;

  @Input() public showInfoButton = false;

  @Input() public showStatusButton = true;

  /** Render the assignee as a name (text) instead of an avatar. Used by boards. */
  @Input() public showAssigneeName = false;

  /**
   * Render the assignee at all. Suppressed on assignee boards, where the column
   * already is the assignee, so the avatar would be redundant. Defaults to true.
   */
  @Input() public showAssignee = true;

  /**
   * Render the compact metadata line (story points, work, epic) below the subject.
   * Boards only - the values are projected onto the card resource by the boards
   * card select (see BoardListComponent.cardSelectFields). Defaults to false so
   * other consumers (wp-grid, team planner) are unaffected.
   */
  @Input() public showCardMeta = false;

  @Input() public showRemoveButton = false;

  @Input() public highlightingMode:CardHighlightingMode = 'inline';

  @Input() public draggable = false;

  @Input() public orientation:CardViewOrientation = 'vertical';

  @Input() public shrinkOnMobile = false;

  @Input() public disabledInfo?:{ text:string, orientation:'left'|'right' };

  @Input() public showAsInlineCard = false;

  @Input() public showStartDate = true;

  @Input() public showEndDate = true;

  @Input() public isClosed = false;

  @Input() public showAsGhost = false;

  @Output() onRemove = new EventEmitter<WorkPackageResource>();

  @Output() stateLinkClicked = new EventEmitter<{ workPackageId:string, requestedState:string }>();

  @Output() cardClicked = new EventEmitter<{ workPackageId:string, event:MouseEvent }>();

  @Output() cardDblClicked = new EventEmitter<{ workPackageId:string, event:MouseEvent }>();

  @Output() cardContextMenu = new EventEmitter<{ workPackageId:string, event:MouseEvent }>();

  /** Emitted when a not-yet-hydrated (lazy) card is focused, so it can be hydrated */
  @Output() hydrateRequested = new EventEmitter<void>();

  readonly pathHelper = inject(PathHelperService);
  readonly I18n = inject(I18nService);
  readonly $state = inject(StateService);
  readonly uiRouterGlobals = inject(UIRouterGlobals);
  readonly wpTableSelection = inject(WorkPackageViewSelectionService);
  readonly wpTableFocus = inject(WorkPackageViewFocusService);
  readonly cardView = inject(WorkPackageCardViewService);
  readonly cdRef = inject(ChangeDetectorRef);
  readonly timezoneService = inject(TimezoneService);
  readonly schemaCache = inject(SchemaCacheService);
  readonly keepTabService = inject(KeepTabService);

  public uiStateLinkClass:string = uiStateLinkClass;

  public selected = false;

  public baselineMode:BaselineMode;

  public text = {
    removeCard: this.I18n.t('js.card.remove_from_list'),
    detailsView: this.I18n.t('js.button_open_details'),
    baseLineIconAdded: this.I18n.t('js.baseline.icon_tooltip.added'),
    baseLineIconChanged: this.I18n.t('js.baseline.icon_tooltip.changed'),
    baseLineIconRemoved: this.I18n.t('js.baseline.icon_tooltip.removed'),
    assigneeAlt:(assignee:string) =>
      this.I18n.t('js.label_assignee_alt_text', { name: assignee }),
    storyPointsLabel: this.I18n.t('js.card.meta.story_points_label'),
    workLabel: this.I18n.t('js.card.meta.work_label'),
    epicLabel: this.I18n.t('js.card.meta.epic_label'),
    storyPoints:(count:number) => this.I18n.t('js.card.meta.story_points', { count }),
  };

  public isNewResource = isNewResource;

  public tooltipPosition = SpotDropAlignmentOption.BottomLeft;

  combinedDateDisplayField = CombinedDateDisplayField;

  private selectionSubscribed = false;

  ngOnInit():void {
    if (this.hydrated) {
      this.subscribeSelection();
    }
  }

  ngOnChanges(changes:SimpleChanges):void {
    // When a lazily-rendered card scrolls into view, hydrated flips to true.
    // Start the selection subscription at that point (only once). The card body
    // itself re-renders via the same change-detection pass that flipped the input.
    if (changes.hydrated?.currentValue === true) {
      this.subscribeSelection();
    }
  }

  // Update selection state
  private subscribeSelection():void {
    if (this.selectionSubscribed) {
      return;
    }
    this.selectionSubscribed = true;

    combineLatest([
      this.wpTableSelection.live$(),
      this.uiRouterGlobals.params$,
    ])
      .pipe(
        this.untilDestroyed(),
        map(() => {
          if (this.selectedWhenOpen) {
            return this.uiRouterGlobals.params.workPackageId === this.workPackage.id;
          }

          return this.wpTableSelection.isSelected(this.workPackage.id!);
        }),
      )
      .subscribe((selected) => {
        this.selected = selected;
        this.cdRef.detectChanges();
      });
  }

  public classIdentifier(wp:WorkPackageResource):string {
    return this.cardView.classIdentifier(wp);
  }

  // Hydrate a lazily-rendered card when it receives focus (keyboard / assistive
  // technology), so the full card is reachable without relying on scroll.
  public requestHydration():void {
    if (!this.hydrated) {
      this.hydrateRequested.emit();
    }
  }

  public emitStateLinkClicked(event:MouseEvent, wp:WorkPackageResource, detail?:boolean):void {
    if (isClickedWithModifier(event)) {
      return;
    }

    const classIdentifier = this.classIdentifier(wp);
    const stateToEmit = detail ? 'split' : 'show';

    this.wpTableSelection.setSelection(wp.id!, this.cardView.findRenderedCard(classIdentifier));
    this.wpTableFocus.updateFocus(wp.id!);
    this.stateLinkClicked.emit({ workPackageId: wp.id!, requestedState: stateToEmit });
    event.preventDefault();
  }

  public cardClasses():Record<string, boolean> {
    const base = 'op-wp-single-card';

    return {
      [`${base}_selected`]: this.selected,
      [`${base}_draggable`]: this.draggable,
      [`${base}_new`]: isNewResource(this.workPackage),
      [`${base}_shrink`]: this.shrinkOnMobile,
      [`${base}_inline`]: this.showAsInlineCard,
      [`${base}_closed`]: this.isClosed,
      [`${base}_ghosted`]: this.showAsGhost,
      [`${base}-${this.workPackage.id}`]: !!this.workPackage.id,
      [`${base}_${this.orientation}`]: true,
    };
  }

  cardTitle():string {
    return `${this.workPackage.subject} (${(this.workPackage.status as StatusResource).name})`;
  }

  public baselineIcon(workPackage:WorkPackageResource) {
    this.baselineMode = getBaselineState(workPackage, this.schemaCache);
    return this.baselineMode;
  }

  public wpTypeAttribute(wp:WorkPackageResource):string {
    return wp.type.name;
  }

  public wpSubject(wp:WorkPackageResource):string {
    return wp.subject;
  }

  public wpProjectName(wp:WorkPackageResource):string {
    return wp.project?.name;
  }

  /** Story points for the compact meta line, or null when unset/zero. */
  public cardStoryPoints(wp:WorkPackageResource):number|null {
    const value = (wp as unknown as { storyPoints?:number|null }).storyPoints;
    return typeof value === 'number' && value > 0 ? value : null;
  }

  /** Estimated effort ("Work") for the compact meta line (e.g. "5h"), or null when unset/zero. */
  public cardWork(wp:WorkPackageResource):string|null {
    const hours = (wp as unknown as { estimatedHours?:number|null }).estimatedHours;
    if (typeof hours !== 'number' || hours <= 0) {
      return null;
    }
    // Round to 2 decimals; i18n renders compactly as "5 h" / "4.5 h" (matches the
    // board column total format).
    const rounded = Math.round(hours * 100) / 100;
    return this.I18n.t('js.units.hour', { count: rounded });
  }

  /** Whether story points and/or work are present (the right-aligned first-line group). */
  public hasCardPoints(wp:WorkPackageResource):boolean {
    return this.cardStoryPoints(wp) !== null || this.cardWork(wp) !== null;
  }

  /**
   * Static start/due text for the not-yet-hydrated card, mirroring the combined
   * date display-field. Values come from the select payload, so no hydration or
   * backend access is needed; hydration swaps in the interactive display-field.
   */
  public cardDates(wp:WorkPackageResource):string|null {
    const start = wp.startDate;
    const due = wp.dueDate;
    if (!start && !due) {
      return null;
    }

    const format = (date:string) => this.timezoneService.formattedDate(date, 'MMM DD, YYYY');
    if (start && due && start !== due) {
      return `${format(start)} - ${format(due)}`;
    }

    return format(due || start);
  }

  public fullWorkPackageLink(wp:WorkPackageResource):string {
    return this.keepTabService.currentShowHref(wp.id!);
  }

  public cardHighlightingClass(wp:WorkPackageResource):string {
    return this.cardHighlighting(wp);
  }

  public typeHighlightingClass(wp:WorkPackageResource):string {
    return this.attributeHighlighting('type', wp);
  }

  // Status color for the lightweight placeholder badge. Derived from the status
  // id via the global highlighting CSS, so it needs no schema and no full card.
  public statusHighlightClass(wp:WorkPackageResource):string {
    return Highlighting.backgroundClass('status', (wp.status as StatusResource).id!);
  }

  public onRemoved(wp:WorkPackageResource):void {
    this.onRemove.emit(wp);
  }

  public cardCoverImageShown(wp:WorkPackageResource):boolean {
    return this.bcfSnapshotPath(wp) !== null;
  }

  public bcfSnapshotPath(wp:WorkPackageResource):string|null {
    return wp.bcfViewpoints && wp.bcfViewpoints.length > 0 ? `${wp.bcfViewpoints[0].href}/snapshot` : null;
  }

  private cardHighlighting(wp:WorkPackageResource):string {
    if (['status', 'priority', 'type'].includes(this.highlightingMode)) {
      return Highlighting.backgroundClass(this.highlightingMode, wp[this.highlightingMode].id);
    }
    return '';
  }

  private attributeHighlighting(type:string, wp:WorkPackageResource):string {
    return Highlighting.inlineClass(type, wp.type.id!);
  }
}
