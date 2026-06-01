import { ElementRef, QueryList } from '@angular/core';
import { WorkPackageResource } from 'core-app/features/hal/resources/work-package-resource';
import { WorkPackageCardViewComponent } from './wp-card-view.component';

describe('WorkPackageCardViewComponent lazy hydration', () => {
  let component:WorkPackageCardViewComponent;
  let detectChanges:jasmine.Spy;
  let cardDragDrop:{ workPackages:WorkPackageResource[], init:() => void, destroy:() => void };
  let containerEl:HTMLElement;

  // Minimal fake IntersectionObserver capturing the observed/unobserved targets.
  class FakeIntersectionObserver {
    public static instances:FakeIntersectionObserver[] = [];

    public observed:Element[] = [];

    public unobserved:Element[] = [];

    public disconnectCount = 0;

    constructor(public callback:IntersectionObserverCallback, public options:IntersectionObserverInit) {
      FakeIntersectionObserver.instances.push(this);
    }

    observe(el:Element):void { this.observed.push(el); }

    unobserve(el:Element):void { this.unobserved.push(el); }

    disconnect():void { this.disconnectCount += 1; }
  }

  let originalIO:typeof IntersectionObserver|undefined;

  const wp = (id:string):WorkPackageResource => ({ id } as WorkPackageResource);

  const cardElementsFor = (...ids:string[]):QueryList<ElementRef<HTMLElement>> => {
    const refs = ids.map((id) => {
      const el = document.createElement('div');
      el.dataset.workPackageId = id;
      return new ElementRef(el);
    });
    const ql = new QueryList<ElementRef<HTMLElement>>();
    ql.reset(refs);
    return ql;
  };

  beforeEach(() => {
    originalIO = (window as unknown as { IntersectionObserver?:typeof IntersectionObserver }).IntersectionObserver;
    (window as unknown as { IntersectionObserver:unknown }).IntersectionObserver = FakeIntersectionObserver;
    FakeIntersectionObserver.instances = [];

    detectChanges = jasmine.createSpy('detectChanges');
    cardDragDrop = { workPackages: [], init: () => undefined, destroy: () => undefined };

    component = new WorkPackageCardViewComponent(
      {} as never, // querySpace
      {} as never, // states
      {} as never, // injector
      {} as never, // $state
      { t: (key:string) => key } as never, // I18n
      {} as never, // wpCreate
      { referenceComponentClass: null } as never, // wpInlineCreate
      {} as never, // notificationService
      {} as never, // halEvents
      {} as never, // authorisationService
      {} as never, // causedUpdates
      { detectChanges } as never, // cdRef
      {} as never, // pathHelper
      {} as never, // wpTableSelection
      {} as never, // wpViewOrder
      {} as never, // cardView
      cardDragDrop as never, // cardDragDrop
      {} as never, // deviceService
    );
    containerEl = document.createElement('div');
    component.container = new ElementRef(containerEl);
  });

  afterEach(() => {
    (window as unknown as { IntersectionObserver?:typeof IntersectionObserver }).IntersectionObserver = originalIO;
  });

  describe('isHydrated', () => {
    it('always returns true when lazyHydrate is off', () => {
      component.lazyHydrate = false;

      expect(component.isHydrated(wp('7'))).toBe(true);
    });

    it('returns true only for ids in hydratedIds when lazyHydrate is on', () => {
      component.lazyHydrate = true;

      expect(component.isHydrated(wp('7'))).toBe(false);

      component.hydratedIds.add('7');

      expect(component.isHydrated(wp('7'))).toBe(true);
      expect(component.isHydrated(wp('8'))).toBe(false);
    });

    it('always hydrates new (unsaved) resources even in lazy mode', () => {
      component.lazyHydrate = true;

      expect(component.isHydrated({ id: 'new' } as WorkPackageResource)).toBe(true);
      expect(component.isHydrated({ id: null } as unknown as WorkPackageResource)).toBe(true);
    });
  });

  describe('hydrate', () => {
    it('marks a card hydrated and triggers change detection', () => {
      component.hydrate(wp('9'));

      expect(component.hydratedIds.has('9')).toBe(true);
      expect(detectChanges).toHaveBeenCalledTimes(1);
    });

    it('is a no-op for an already hydrated card', () => {
      component.hydratedIds.add('9');

      component.hydrate(wp('9'));

      expect(detectChanges).not.toHaveBeenCalled();
    });
  });

  describe('setupLazyHydration', () => {
    it('creates a single observer scoped to the container with a pre-hydrate margin and observes every card', () => {
      component.lazyHydrate = true;
      component.cardElements = cardElementsFor('7', '8');

      (component as unknown as { setupLazyHydration:() => void }).setupLazyHydration();

      expect(FakeIntersectionObserver.instances.length).toBe(1);

      const io = FakeIntersectionObserver.instances[0];

      expect(io.options.root).toBe(containerEl);
      expect(io.options.rootMargin).toBe('200px 0px');
      expect(io.observed.map((el) => (el as HTMLElement).dataset.workPackageId)).toEqual(['7', '8']);
    });

    it('falls back to eager rendering when IntersectionObserver is unavailable', () => {
      delete (window as unknown as { IntersectionObserver?:typeof IntersectionObserver }).IntersectionObserver;
      component.lazyHydrate = true;
      component.cardElements = cardElementsFor('7');

      (component as unknown as { setupLazyHydration:() => void }).setupLazyHydration();

      expect(component.lazyHydrate).toBe(false);
      expect(detectChanges).toHaveBeenCalledTimes(1);
      expect(FakeIntersectionObserver.instances.length).toBe(0);
    });
  });

  describe('onCardsIntersect', () => {
    beforeEach(() => {
      component.lazyHydrate = true;
      component.cardElements = cardElementsFor('7', '8');
      (component as unknown as { setupLazyHydration:() => void }).setupLazyHydration();
    });

    it('hydrates intersecting cards, stops observing them, and triggers change detection', () => {
      const io = FakeIntersectionObserver.instances[0];
      const target = io.observed[0] as HTMLElement;

      (component as unknown as { onCardsIntersect:(e:Partial<IntersectionObserverEntry>[]) => void })
        .onCardsIntersect([{ isIntersecting: true, target }]);

      expect(component.hydratedIds.has('7')).toBe(true);
      expect(io.unobserved).toContain(target);
      expect(detectChanges).toHaveBeenCalledTimes(1);
    });

    it('ignores entries that are not intersecting', () => {
      const io = FakeIntersectionObserver.instances[0];
      const target = io.observed[1] as HTMLElement;

      (component as unknown as { onCardsIntersect:(e:Partial<IntersectionObserverEntry>[]) => void })
        .onCardsIntersect([{ isIntersecting: false, target }]);

      expect(component.hydratedIds.size).toBe(0);
      expect(detectChanges).not.toHaveBeenCalled();
    });
  });

  describe('pruneHydratedIds', () => {
    it('drops hydrated ids no longer present and keeps surviving ones', () => {
      component.hydratedIds = new Set(['7', '8']);
      cardDragDrop.workPackages = [wp('7')];

      (component as unknown as { pruneHydratedIds:() => void }).pruneHydratedIds();

      expect(component.hydratedIds.has('7')).toBe(true);
      expect(component.hydratedIds.has('8')).toBe(false);
    });
  });

  describe('seedInitialHydration', () => {
    it('eagerly hydrates the first screenful and leaves the rest for the observer', () => {
      component.lazyHydrate = true;
      cardDragDrop.workPackages = Array.from({ length: 30 }, (_, i) => wp(String(i)));

      (component as unknown as { seedInitialHydration:() => void }).seedInitialHydration();

      expect(component.hydratedIds.has('0')).toBe(true);
      expect(component.hydratedIds.has('24')).toBe(true); // 25th card (index 24)
      expect(component.hydratedIds.has('25')).toBe(false); // beyond the initial screenful
    });

    it('does nothing when lazyHydrate is off', () => {
      component.lazyHydrate = false;
      cardDragDrop.workPackages = [wp('0')];

      (component as unknown as { seedInitialHydration:() => void }).seedInitialHydration();

      expect(component.hydratedIds.size).toBe(0);
    });
  });
});
