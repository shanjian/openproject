//-- copyright
// OpenProject is an open source project management software.
// Copyright (C) the OpenProject GmbH
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License version 3.
//
// OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
// Copyright (C) 2006-2013 Jean-Philippe Lang
// Copyright (C) 2010-2013 the ChiliProject Team
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 2
// of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
//
// See COPYRIGHT and LICENSE files for more details.
//++

import { Subject } from 'rxjs';
import { WorkPackagesListService } from 'core-app/features/work-packages/components/wp-list/wp-list.service';
import { QueryResource } from 'core-app/features/hal/resources/query-resource';
import { QueryFormResource } from 'core-app/features/hal/resources/query-form-resource';

// Construct the service with positional args without depending on Angular DI.
// Only apiV3Service (7th) and wpStatesInitialization (13th) are exercised by loadForm;
// the remaining dependencies are not touched, so null placeholders are sufficient.
type ListServiceCtor = new (...args:unknown[]) => WorkPackagesListService;

describe('WorkPackagesListService.loadForm', () => {
  let loadCalls:number;
  // A fresh stream per load() call, so completing one does not turn a later
  // firstValueFrom() into an EmptyError rejection.
  let streams:Subject<[unknown, unknown]>[];
  let initializedFor:QueryResource[];
  let service:WorkPackagesListService;

  const form = { href: '/api/v3/queries/704/form' } as unknown as QueryFormResource;

  function query(overrides:Partial<{ id:string; project:{ href:string }; name:string }> = {}):QueryResource {
    return {
      id: '704',
      name: 'Sprint',
      project: { href: '/api/v3/projects/web' },
      ...overrides,
    } as unknown as QueryResource;
  }

  function settle(index:number, withQuery:QueryResource):void {
    streams[index].next([form, withQuery]);
    streams[index].complete();
  }

  beforeEach(() => {
    loadCalls = 0;
    streams = [];
    initializedFor = [];

    const apiV3Service = {
      queries: {
        form: {
          load: () => {
            const stream = new Subject<[unknown, unknown]>();
            streams.push(stream);
            loadCalls += 1;
            return stream.asObservable();
          },
        },
      },
    };

    const wpStatesInitialization = {
      updateStatesFromForm: (q:QueryResource) => {
        initializedFor.push(q);
      },
    };

    service = new (WorkPackagesListService as unknown as ListServiceCtor)(
      null, // injector
      null, // toastService
      null, // I18n
      null, // UrlParamsHelper
      null, // authorisationService
      null, // $state
      apiV3Service,
      null, // states
      null, // querySpace
      null, // pagination
      null, // configuration
      null, // wpTablePagination
      wpStatesInitialization,
      null, // wpListInvalidQueryService
      null, // wpQueryView
      null, // submenuService
    );
  });

  it('issues a single request when called concurrently for the same query', async () => {
    const q = query();
    const p1 = service.loadForm(q);
    const p2 = service.loadForm(q);

    expect(loadCalls).toEqual(1);

    settle(0, q);

    await expectAsync(p1).toBeResolvedTo(form);
    await expectAsync(p2).toBeResolvedTo(form);
  });

  it('still initializes each caller\'s own query when the request is deduped', async () => {
    // Two distinct query resources for the same saved query (e.g. an initial load
    // and a refreshed-params re-emission). They share one request, but each must
    // still get its own updateStatesFromForm side effect.
    const first = query();
    const refreshed = query();

    const p1 = service.loadForm(first);
    const p2 = service.loadForm(refreshed);

    expect(loadCalls).toEqual(1);

    settle(0, first);
    await Promise.all([p1, p2]);

    expect(initializedFor).toContain(first);
    expect(initializedFor).toContain(refreshed);
  });

  it('does not share the in-flight request across different project scopes', () => {
    // Default/new queries have no id; only the project scope distinguishes the
    // form request, so they must not collide on a shared key.
    const inWeb = query({ id: undefined, name: undefined, project: { href: '/api/v3/projects/web' } });
    const inDocs = query({ id: undefined, name: undefined, project: { href: '/api/v3/projects/docs' } });

    void service.loadForm(inWeb);
    void service.loadForm(inDocs);

    expect(loadCalls).toEqual(2);
  });

  it('issues a fresh request once the previous load has settled', async () => {
    const q = query();
    const p1 = service.loadForm(q);
    settle(0, q);
    await p1;

    // The in-flight entry is cleared after settling, so a later reload goes through
    // (its stream stays pending, which is fine - we only assert a new request fired).
    void service.loadForm(q);

    expect(loadCalls).toEqual(2);
  });
});
