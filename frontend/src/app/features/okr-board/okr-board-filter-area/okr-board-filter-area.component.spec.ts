import { ComponentFixture, TestBed } from '@angular/core/testing';
import { NO_ERRORS_SCHEMA } from '@angular/core';
import { OkrBoardFilterAreaComponent } from './okr-board-filter-area.component';

describe('OkrBoardFilterAreaComponent', () => {
  let fixture:ComponentFixture<OkrBoardFilterAreaComponent>;

  beforeEach(() => {
    TestBed.configureTestingModule({
      declarations: [OkrBoardFilterAreaComponent],
      schemas: [NO_ERRORS_SCHEMA],
    });
    fixture = TestBed.createComponent(OkrBoardFilterAreaComponent);
    fixture.detectChanges();
  });

  it('renders both the quick filter bar and the native filter container', () => {
    const el:HTMLElement = fixture.nativeElement as HTMLElement;
    expect(el.querySelector('okr-board-filter')).not.toBeNull();
    expect(el.querySelector('op-filter-container')).not.toBeNull();
  });

  it('enables the native filter container\'s own toggle button', () => {
    // WorkPackageFilterContainerComponent's `showFilterButton` input defaults to false,
    // and its filter panel only ever becomes visible via that button's click handler
    // (WorkPackageFiltersService#toggleVisibility()) -- without this binding there is no
    // way for a user to ever open the native filter panel this component wraps.
    const el:HTMLElement = fixture.nativeElement as HTMLElement;
    const container = el.querySelector('op-filter-container') as unknown as { showFilterButton:boolean };
    expect(container.showFilterButton).toBe(true);
  });
});
