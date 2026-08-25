import { Injectable } from '@angular/core';
import { WpSingleViewStore } from './wp-single-view.store';
import {
  filter,
  map,
  switchMap,
  take,
} from 'rxjs/operators';
import { InAppNotificationsResourceService } from 'core-app/core/state/in-app-notifications/in-app-notifications.service';
import {
  ApiV3ListFilter,
  ApiV3ListParameters,
} from 'core-app/core/apiv3/paths/apiv3-list-resource.interface';
import {
  centerUpdatedInPlace,
  markNotificationsAsRead,
  notificationsMarkedRead,
} from 'core-app/core/state/in-app-notifications/in-app-notifications.actions';
import { ActionsService } from 'core-app/core/state/actions/actions.service';
import {
  EffectCallback,
  EffectHandler,
} from 'core-app/core/state/effects/effect-handler.decorator';
import { CurrentUserService } from 'core-app/core/current-user/current-user.service';
import { ID, Query } from '@datorama/akita';
import { Observable } from 'rxjs';
import { IHALCollection } from 'core-app/core/apiv3/types/hal-collection.type';
import { INotification } from 'core-app/core/state/in-app-notifications/in-app-notification.model';

@EffectHandler
@Injectable()
export class WpSingleViewService {
  id = 'WorkPackage Activity Store';

  protected store = new WpSingleViewStore();

  protected query = new Query(this.store);

  selectNotifications$ = this
    .query
    .select((state) => state.notifications.filters)
    .pipe(
      filter((filters) => filters.length > 0),
      switchMap(() => this.resourceService.collection(this.params)),
    );

  selectNotificationsCount$ = this
    .selectNotifications$
    .pipe(
      map((notifications) => notifications.length),
    );

  nonDateAlertNotificationsCount$ = this
    .selectNotifications$
    .pipe(
      map((notifications) => notifications.filter((notification) => notification.reason !== 'dateAlert')),
      map((notifications) => notifications.length),
    );

  hasNotifications$ = this
    .selectNotificationsCount$
    .pipe(
      map((count) => count > 0),
    );

  get params():ApiV3ListParameters {
    return {
      filters: this.query.getValue().notifications.filters,
      // Every unread notification on this work package has to be marked read, not just
      // the first API page. -1 is APIv3's magic value for the maximum page size.
      pageSize: -1,
    };
  }

  constructor(
    readonly actions$:ActionsService,
    readonly currentUser$:CurrentUserService,
    private resourceService:InAppNotificationsResourceService,
  ) {
  }

  /**
   * @param markAsRead Mark the work package's notifications as read once they are loaded.
   *                   Opening a work package counts as reading it.
   */
  setFilters(workPackageId:string, markAsRead = false):void {
    const filters:ApiV3ListFilter[] = [
      ['readIAN', '=', false],
      ['resourceId', '=', [workPackageId]],
      ['resourceType', '=', ['WorkPackage']],
    ];

    this.store.update(({ notifications }) => (
      {
        notifications: {
          ...notifications,
          filters,
        },
      }
    ));

    this
      .reload$()
      .subscribe((collection) => {
        if (markAsRead) {
          this.markCollectionAsRead(collection._embedded.elements.map((el) => el.id), true);
        }
      });
  }

  markAllAsRead():void {
    this
      .resourceService
      .collection(this.params)
      .pipe(
        take(1),
      )
      .subscribe((collection) => {
        this.markCollectionAsRead(collection.map((el) => el.id), false);
      });
  }

  reload():void {
    this.reload$().subscribe();
  }

  reload$():Observable<IHALCollection<INotification>> {
    return this
      .currentUser$
      .isLoggedIn$
      .pipe(
        take(1),
        filter((loggedIn) => loggedIn),
        switchMap(() => this.resourceService.fetchCollection(this.params)),
      );
  }

  private markCollectionAsRead(notifications:ID[], auto:boolean):void {
    if (notifications.length === 0) {
      return;
    }

    this.actions$.dispatch(
      markNotificationsAsRead({ origin: this.id, notifications, auto }),
    );
  }

  /**
   * Reload after notifications were successfully marked as read
   */
  @EffectCallback(notificationsMarkedRead)
  private reloadOnNotificationRead() {
    this.reload();
  }

  /**
   * Reload after notifications were successfully marked as read
   */
  @EffectCallback(centerUpdatedInPlace)
  private reloadOnCenterUpdate() {
    this.reload();
  }
}
