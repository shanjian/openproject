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

import { ComponentFixture, TestBed } from '@angular/core/testing';
import { ChangeDetectionStrategy, Component, Input } from '@angular/core';
import { By } from '@angular/platform-browser';
import { of } from 'rxjs';
import { I18nService } from 'core-app/core/i18n/i18n.service';
import { WorkPackageResource } from 'core-app/features/hal/resources/work-package-resource';
import { BranchComponent } from 'core-app/features/plugins/linked/openproject-github_integration/branch/branch.component';
import { TabBranchesComponent } from 'core-app/features/plugins/linked/openproject-github_integration/tab-branches/tab-branches.component';
import { GithubBranchResourceService } from 'core-app/features/plugins/linked/openproject-github_integration/state/github-branch.service';
import { IGithubBranch } from 'core-app/features/plugins/linked/openproject-github_integration/state/github-branch.model';

@Component({
  selector: 'op-date-time',
  template: '<span></span>',
  changeDetection: ChangeDetectionStrategy.OnPush,
  standalone: false,
})
class OpDateTimeStubComponent {
  @Input() dateTimeValue:unknown;
}

describe('TabBranchesComponent', () => {
  let fixture:ComponentFixture<TabBranchesComponent>;
  let ofWorkPackageSpy:jasmine.Spy<GithubBranchResourceService['ofWorkPackage']>;
  let translateSpy:jasmine.Spy<I18nService['t']>;
  const workPackage = { id: '42' } as unknown as WorkPackageResource;

  const branches:IGithubBranch[] = [
    {
      id: 2,
      name: 'bug/42-newer',
      htmlUrl: 'https://github.com/test_user/test_repo/tree/bug/42-newer',
      repository: 'test_user/test_repo',
      githubUpdatedAt: '2021-04-02T08:00:00Z',
    },
    {
      id: 1,
      name: 'bug/42-older',
      htmlUrl: 'https://github.com/test_user/test_repo/tree/bug/42-older',
      repository: 'test_user/test_repo',
      githubUpdatedAt: '2021-04-01T08:00:00Z',
    },
  ];

  function create(result:IGithubBranch[]):void {
    ofWorkPackageSpy.and.returnValue(of(result));

    fixture = TestBed.createComponent(TabBranchesComponent);
    fixture.componentRef.setInput('workPackage', workPackage);
    fixture.detectChanges();
  }

  beforeEach(async () => {
    ofWorkPackageSpy = jasmine.createSpy('ofWorkPackage');
    translateSpy = jasmine.createSpy('t').and.callFake((key:string) => `translated ${key}`);

    await TestBed
      .configureTestingModule({
        declarations: [
          TabBranchesComponent,
          BranchComponent,
          OpDateTimeStubComponent,
        ],
        providers: [
          { provide: I18nService, useValue: { t: translateSpy } },
          { provide: GithubBranchResourceService, useValue: { ofWorkPackage: ofWorkPackageSpy } },
        ],
      })
      .compileComponents();
  });

  it('should create', () => {
    create(branches);

    expect(fixture.componentInstance).toBeTruthy();
  });

  it('requests the branches of the work package', () => {
    create(branches);

    expect(ofWorkPackageSpy).toHaveBeenCalledWith(workPackage);
  });

  it('displays a branch component per branch, in the order the API lists them', () => {
    create(branches);

    const rendered = fixture.debugElement.queryAll(By.css('op-github-branch'));

    expect(rendered.length).toBe(2);
    expect(rendered.map((el) => (el.nativeElement as HTMLElement).querySelector('.op-github-branch--link')?.textContent?.trim()))
      .toEqual(['bug/42-newer', 'bug/42-older']);
  });

  it('does not display the empty message when there are branches', () => {
    create(branches);

    expect(fixture.debugElement.query(By.css('.op-tab-content--text-box'))).toBeNull();
  });

  describe('when there are no branches', () => {
    beforeEach(() => create([]));

    it('displays no branch component', () => {
      expect(fixture.debugElement.queryAll(By.css('op-github-branch')).length).toBe(0);
    });

    it('displays the empty message with the id of the work package', () => {
      const message = fixture.debugElement.query(By.css('.op-tab-content--text-box'));

      expect(translateSpy).toHaveBeenCalledWith('js.github_integration.tab_branches.empty', { wp_id: '42' });
      expect(message.nativeElement.textContent.trim()).toBe('translated js.github_integration.tab_branches.empty');
    });
  });
});
