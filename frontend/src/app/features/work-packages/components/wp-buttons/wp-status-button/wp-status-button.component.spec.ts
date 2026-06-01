import { NO_ERRORS_SCHEMA } from '@angular/core';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { By } from '@angular/platform-browser';
import { of } from 'rxjs';
import { WorkPackageResource } from 'core-app/features/hal/resources/work-package-resource';
import { I18nService } from 'core-app/core/i18n/i18n.service';
import { SchemaCacheService } from 'core-app/core/schemas/schema-cache.service';
import { HalResourceEditingService } from 'core-app/shared/components/fields/edit/services/hal-resource-editing.service';
import { WorkPackageStatusButtonComponent } from './wp-status-button.component';

describe('WorkPackageStatusButtonComponent without a loaded schema', () => {
  let fixture:ComponentFixture<WorkPackageStatusButtonComponent>;

  // A board "select" work package: status is a link (name from title, id from href),
  // and there is no schema link / cached schema.
  const workPackage = {
    status: { id: '5', name: 'Open', $load: () => undefined },
    $links: {},
  } as unknown as WorkPackageResource;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      declarations: [WorkPackageStatusButtonComponent],
      providers: [
        { provide: I18nService, useValue: { t: () => '' } },
        {
          provide: SchemaCacheService,
          useValue: {
            getSchemaHref: () => undefined, // no schema link on a select payload
            state: () => ({ hasValue: () => false }), // schema not cached
            of: () => undefined,
          },
        },
        {
          provide: HalResourceEditingService,
          useValue: {
            temporaryEditResource: () => ({ values$: () => of(workPackage) }),
            typedState: () => ({ hasValue: () => false }),
          },
        },
      ],
      schemas: [NO_ERRORS_SCHEMA],
    }).compileComponents();

    fixture = TestBed.createComponent(WorkPackageStatusButtonComponent);
    fixture.componentInstance.workPackage = workPackage;
    fixture.detectChanges();
  });

  it('renders the status (name + highlight) instead of throwing', () => {
    const button = fixture.debugElement.query(By.css('[data-test-selector="op-wp-status-button"]'));

    expect(button).not.toBeNull();
    expect(fixture.nativeElement.textContent).toContain('Open');
    // Status color comes from the id via the global highlighting CSS, not the schema.
    expect(fixture.debugElement.query(By.css('.__hl_background_status_5'))).not.toBeNull();
  });

  it('treats the status as editable (not disabled) and not readonly when the schema is absent', () => {
    expect(fixture.componentInstance.allowed).toBe(true);
    expect(fixture.componentInstance.isReadonly).toBe(false);
    expect(fixture.componentInstance.buttonTitle).toBe('');
  });
});
