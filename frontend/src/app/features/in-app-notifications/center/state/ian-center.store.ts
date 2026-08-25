import { Store, StoreConfig } from '@datorama/akita';
import { CollectionResponse } from 'core-app/core/state/resource-store';
import { ApiV3ListFilter } from 'core-app/core/apiv3/paths/apiv3-list-resource.interface';
import { NOTIFICATIONS_MAX_SIZE } from 'core-app/core/state/in-app-notifications/in-app-notification.model';
import {
  INotificationPageQueryParameters,
} from 'core-app/features/in-app-notifications/center/state/ian-center.service';

export type InAppNotificationFacet = 'unread'|'all';

export interface IanCenterState {
  params:{
    // APIv3 paginates by page number, which it calls `offset`. 1-based.
    offset:number;
    pageSize:number;
  };
  activeFacet:InAppNotificationFacet;
  filters:INotificationPageQueryParameters;

  activeCollection:CollectionResponse;

  /** Total number of notifications matching the active facet and filters, as reported by the API */
  total:number;

  /** Whether an additional page is currently being fetched */
  loadingMore:boolean;
}

export const IAN_FACET_FILTERS:Record<InAppNotificationFacet, ApiV3ListFilter[]> = {
  unread: [['readIAN', '=', false]],
  all: [],
};

export function createInitialState():IanCenterState {
  return {
    params: {
      pageSize: NOTIFICATIONS_MAX_SIZE,
      offset: 1,
    },
    filters: {},
    activeCollection: { ids: [] },
    activeFacet: 'unread',
    total: 0,
    loadingMore: false,
  };
}

@StoreConfig({ name: 'ian-center' })
export class IanCenterStore extends Store<IanCenterState> {
  constructor() {
    super(createInitialState());
  }
}
