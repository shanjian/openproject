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
import { I18nService } from 'core-app/core/i18n/i18n.service';
import { BranchComponent } from 'core-app/features/plugins/linked/openproject-github_integration/branch/branch.component';
import { IGithubBranch } from 'core-app/features/plugins/linked/openproject-github_integration/state/github-branch.model';

@Component({
  selector: 'op-date-time',
  template: '<span class="date-time-stub">{{ dateTimeValue }}</span>',
  changeDetection: ChangeDetectionStrategy.OnPush,
  standalone: false,
})
class OpDateTimeStubComponent {
  @Input() dateTimeValue:unknown;
}

describe('BranchComponent', () => {
  let fixture:ComponentFixture<BranchComponent>;

  const I18nServiceStub = {
    t: (key:string) => `translated ${key}`,
  };

  const branch:IGithubBranch = {
    id: 1,
    name: 'bug/42-fix-the-crash',
    htmlUrl: 'https://github.com/test_user/test_repo/tree/bug/42-fix-the-crash',
    repository: 'test_user/test_repo',
    lastCommitSha: 'a265d6b7bcf836b77ed9e32f824b231585c6a355',
    lastCommitMessage: 'Fix the crash on startup',
    lastCommitHtmlUrl: 'https://github.com/test_user/test_repo/commit/a265d6b7bcf836b77ed9e32f824b231585c6a355',
    lastCommitAuthor: 'Some Committer',
    githubUpdatedAt: '2021-04-01T08:15:30Z',
  };

  function render(overrides:Partial<IGithubBranch> = {}):void {
    fixture.componentRef.setInput('branch', { ...branch, ...overrides });
    fixture.detectChanges();
  }

  function text(selector:string):string|undefined {
    const element = fixture.debugElement.query(By.css(selector));
    return (element?.nativeElement as HTMLElement|undefined)?.textContent?.trim();
  }

  beforeEach(async () => {
    await TestBed
      .configureTestingModule({
        declarations: [
          BranchComponent,
          OpDateTimeStubComponent,
        ],
        providers: [
          { provide: I18nService, useValue: I18nServiceStub },
        ],
      })
      .compileComponents();

    fixture = TestBed.createComponent(BranchComponent);
  });

  it('should create', () => {
    render();

    expect(fixture.componentInstance).toBeTruthy();
  });

  it('links the branch name to the branch on GitHub', () => {
    render();

    const link = fixture.debugElement.query(By.css('.op-github-branch--link'));

    expect(link.nativeElement.textContent.trim()).toBe('bug/42-fix-the-crash');
    expect(link.nativeElement.getAttribute('href')).toBe(branch.htmlUrl);
    expect(link.nativeElement.getAttribute('target')).toBe('_blank');
    expect(link.nativeElement.getAttribute('rel')).toContain('noopener');
  });

  it('shows the repository', () => {
    render();

    expect(text('.op-github-branch--repository')).toBe('test_user/test_repo');
  });

  it('shows the short sha of the tip commit, linked to it, and its message', () => {
    render();

    const link = fixture.debugElement.query(By.css('.op-github-branch--commit-link'));

    expect(link.nativeElement.textContent.trim()).toBe('a265d6b7');
    expect(link.nativeElement.getAttribute('href')).toBe(branch.lastCommitHtmlUrl);
    expect(text('.op-github-branch--commit-message')).toBe('Fix the crash on startup');
  });

  it('shows the short sha without a link when the commit has no url', () => {
    render({ lastCommitHtmlUrl: null });

    expect(fixture.debugElement.query(By.css('.op-github-branch--commit-link'))).toBeNull();
    expect(text('.op-github-branch--commit-sha')).toBe('a265d6b7');
  });

  it('omits the commit when the tip is unknown', () => {
    render({ lastCommitSha: null, lastCommitMessage: null, lastCommitHtmlUrl: null });

    expect(fixture.debugElement.query(By.css('.op-github-branch--commit'))).toBeNull();
  });

  it('omits the commit message when there is none', () => {
    render({ lastCommitMessage: null });

    expect(fixture.debugElement.query(By.css('.op-github-branch--commit-message'))).toBeNull();
    expect(fixture.debugElement.query(By.css('.op-github-branch--commit-link'))).not.toBeNull();
  });

  it('shows the author and when the branch was last updated', () => {
    render();

    expect(text('.op-github-branch--author')).toBe('Some Committer');
    expect(text('.op-github-branch--date')).toContain('translated js.label_last_updated_on');
    expect(text('.date-time-stub')).toBe('2021-04-01T08:15:30Z');
  });

  it('omits the author when it is unknown', () => {
    render({ lastCommitAuthor: null });

    expect(fixture.debugElement.query(By.css('.op-github-branch--author'))).toBeNull();
    expect(fixture.debugElement.query(By.css('.op-github-branch--date'))).not.toBeNull();
  });
});
