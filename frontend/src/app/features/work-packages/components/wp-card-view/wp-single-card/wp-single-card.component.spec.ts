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
        { provide: TimezoneService, useValue: {} },
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
    beforeEach(() => {
      fixture.componentRef.setInput('hydrated', false);
      fixture.detectChanges();
    });

    it('renders only the lightweight placeholder', () => {
      expect(placeholder()).not.toBeNull();
      expect(subject()).toBeNull();
    });

    it('keeps the subject text so the card stays findable and readable', () => {
      const placeholderSubject = fixture.debugElement.query(
        By.css('[data-test-selector="op-wp-single-card--placeholder-subject"]'),
      );

      expect(placeholderSubject).not.toBeNull();
      expect(placeholderSubject.nativeElement.textContent).toContain('A subject');
    });

    it('requests hydration when focused', () => {
      const emit = spyOn(fixture.componentInstance.hydrateRequested, 'emit');

      placeholder().nativeElement.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));

      expect(emit).toHaveBeenCalledTimes(1);
    });

    it('does not subscribe to the selection state', () => {
      expect(selection.live$).not.toHaveBeenCalled();
    });

    it('hydrates and subscribes once flipped to hydrated', () => {
      fixture.componentRef.setInput('hydrated', true);
      fixture.detectChanges();

      expect(placeholder()).toBeNull();
      expect(subject()).not.toBeNull();
      expect(selection.live$).toHaveBeenCalledTimes(1);
    });
  });
});
