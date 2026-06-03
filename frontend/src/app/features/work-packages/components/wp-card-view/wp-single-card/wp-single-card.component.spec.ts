import { NO_ERRORS_SCHEMA } from '@angular/core';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { By } from '@angular/platform-browser';
import { of } from 'rxjs';
import { StateService, UIRouterGlobals } from '@uirouter/core';
import { WorkPackageResource } from 'core-app/features/hal/resources/work-package-resource';
import { PathHelperService } from 'core-app/core/path-helper/path-helper.service';
import { I18nService } from 'core-app/core/i18n/i18n.service';
import { WorkPackageViewSelectionService } from 'core-app/features/work-packages/routing/wp-view-base/view-services/wp-view-selection.service';
import { WorkPackageViewFocusService } from 'core-app/features/work-packages/routing/wp-view-base/view-services/wp-view-focus.service';
import { WorkPackageCardViewService } from 'core-app/features/work-packages/components/wp-card-view/services/wp-card-view.service';
import { TimezoneService } from 'core-app/core/datetime/timezone.service';
import { SchemaCacheService } from 'core-app/core/schemas/schema-cache.service';
import { KeepTabService } from 'core-app/features/work-packages/components/wp-single-view-tabs/keep-tab/keep-tab.service';
import { WorkPackageSingleCardComponent } from './wp-single-card.component';

describe('WorkPackageSingleCardComponent', () => {
  let fixture:ComponentFixture<WorkPackageSingleCardComponent>;
  let selection:{ live$:jasmine.Spy, isSelected:jasmine.Spy };

  const workPackage = {
    id: '1',
    subject: 'A subject',
    type: { id: '5', name: 'Task' },
    status: { id: '1', name: 'New' },
    project: { name: 'Demo project' },
    assignee: undefined,
    startDate: null,
    dueDate: null,
    bcfViewpoints: undefined,
    attributesByTimestamp: undefined,
  } as unknown as WorkPackageResource;

  const placeholder = () => fixture.debugElement.query(By.css('.op-wp-single-card_placeholder'));
  const subject = () => fixture.debugElement.query(By.css('[data-test-selector="op-wp-single-card--content-subject"]'));

  beforeEach(async () => {
    selection = {
      live$: jasmine.createSpy('live$').and.returnValue(of({})),
      isSelected: jasmine.createSpy('isSelected').and.returnValue(false),
    };

    await TestBed.configureTestingModule({
      declarations: [WorkPackageSingleCardComponent],
      providers: [
        { provide: PathHelperService, useValue: {} },
        { provide: I18nService, useValue: { t: (key:string) => key } },
        { provide: StateService, useValue: { href: () => '' } },
        { provide: UIRouterGlobals, useValue: { params$: of({}), params: {} } },
        { provide: WorkPackageViewSelectionService, useValue: selection },
        { provide: WorkPackageViewFocusService, useValue: { updateFocus: () => undefined } },
        { provide: WorkPackageCardViewService, useValue: { classIdentifier: (wp:WorkPackageResource) => `wp-row-${wp.id}` } },
        {
          provide: TimezoneService,
          useValue: {
            toISODuration: (value:number) => `PT${value}H`,
            formattedChronicDuration: () => '1 d',
          },
        },
        { provide: SchemaCacheService, useValue: { of: () => ({}) } },
        { provide: KeepTabService, useValue: { currentShowHref: () => '' } },
      ],
      schemas: [NO_ERRORS_SCHEMA],
    }).compileComponents();

    fixture = TestBed.createComponent(WorkPackageSingleCardComponent);
    fixture.componentInstance.workPackage = workPackage;
  });

  describe('when hydrated (default)', () => {
    beforeEach(() => {
      fixture.detectChanges();
    });

    it('renders the full card content and no placeholder', () => {
      expect(placeholder()).toBeNull();
      expect(subject()).not.toBeNull();
      expect(subject().nativeElement.textContent).toContain('A subject');
    });

    it('subscribes to the selection state', () => {
      expect(selection.live$).toHaveBeenCalledTimes(1);
    });
  });

  describe('assignee display', () => {
    const assigned = {
      ...workPackage,
      assignee: { name: 'Jane Doe' },
    } as unknown as WorkPackageResource;

    const assigneeEl = () => fixture.debugElement.query(
      By.css('[data-test-selector="op-wp-single-card--content-assignee"]'),
    );

    it('shows the assignee name as text when showAssigneeName is true', () => {
      fixture.componentInstance.workPackage = assigned;
      fixture.componentRef.setInput('showAssigneeName', true);
      fixture.detectChanges();

      expect(assigneeEl().nativeElement.tagName.toLowerCase()).toBe('span');
      expect(assigneeEl().nativeElement.textContent).toContain('Jane Doe');
      expect(fixture.debugElement.query(By.css('op-principal'))).toBeNull();
    });

    it('renders the avatar (op-principal) by default', () => {
      fixture.componentInstance.workPackage = assigned;
      fixture.detectChanges();

      expect(fixture.debugElement.query(By.css('op-principal'))).not.toBeNull();
    });
  });

  describe('when not hydrated', () => {
    const statusButton = () => fixture.debugElement.query(By.css('wp-status-button'));
    const statusBadge = () => fixture.debugElement.query(
      By.css('[data-test-selector="op-wp-single-card--content-status-badge"]'),
    );

    beforeEach(() => {
      fixture.componentRef.setInput('hydrated', false);
      fixture.detectChanges();
    });

    it('flags the card as a placeholder but still renders the shared content layout', () => {
      expect(placeholder()).not.toBeNull();
      // Same layout as the hydrated card: the subject (and other cheap payload
      // values) render regardless of hydration.
      expect(subject()).not.toBeNull();
      expect(subject().nativeElement.textContent).toContain('A subject');
    });

    it('defers only the heavy interactive widgets (status dropdown)', () => {
      expect(statusButton()).toBeNull();
    });

    it('shows a static status pill (name + color) in place of the dropdown', () => {
      expect(statusBadge()).not.toBeNull();
      expect(statusBadge().nativeElement.textContent).toContain('New');
      expect(statusBadge().nativeElement.classList).toContain('__hl_background_status_1');
    });

    it('requests hydration when focused', () => {
      const emit = spyOn(fixture.componentInstance.hydrateRequested, 'emit');

      placeholder().nativeElement.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));

      expect(emit).toHaveBeenCalledTimes(1);
    });

    it('does not subscribe to the selection state', () => {
      expect(selection.live$).not.toHaveBeenCalled();
    });

    it('hydrates (status dropdown appears) and subscribes once flipped to hydrated', () => {
      fixture.componentRef.setInput('hydrated', true);
      fixture.detectChanges();

      expect(placeholder()).toBeNull();
      expect(subject()).not.toBeNull();
      expect(statusButton()).not.toBeNull();
      expect(statusBadge()).toBeNull();
      expect(selection.live$).toHaveBeenCalledTimes(1);
    });
  });

  describe('compact meta on boards (showCardMeta)', () => {
    const withMeta = {
      ...workPackage,
      storyPoints: 3,
      estimatedHours: 5,
      epic: { name: 'Login epic' },
    } as unknown as WorkPackageResource;

    const points = () => fixture.debugElement.query(By.css('[data-test-selector="op-wp-single-card--content-points"]'));
    const epic = () => fixture.debugElement.query(By.css('[data-test-selector="op-wp-single-card--meta-epic"]'));

    beforeEach(() => {
      fixture.componentInstance.workPackage = withMeta;
      fixture.componentRef.setInput('showCardMeta', true);
    });

    // The values come from the (already-loaded) select payload, so the single
    // shared layout shows them whether or not the card is hydrated - no backend.
    it('renders epic and story points/work without hydration', () => {
      fixture.componentRef.setInput('hydrated', false);
      fixture.detectChanges();

      expect(placeholder()).not.toBeNull();
      expect(epic()).not.toBeNull();
      expect(epic().nativeElement.textContent).toContain('Login epic');
      expect(points()).not.toBeNull();
      expect(points().nativeElement.textContent).toContain('js.card.meta.story_points');
      // Work is formatted via the standard chronic-duration formatter (days + hours)
      expect(points().nativeElement.textContent).toContain('1 d');
    });

    it('renders epic and story points/work on the hydrated card', () => {
      fixture.componentRef.setInput('hydrated', true);
      fixture.detectChanges();

      expect(points()).not.toBeNull();
      expect(epic().nativeElement.textContent).toContain('Login epic');
    });
  });
});
