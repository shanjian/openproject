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

import { GitActionsService } from './git-actions.service';
import { WorkPackageResource } from "core-app/features/hal/resources/work-package-resource";
import { TestBed, waitForAsync } from '@angular/core/testing';
import { PathHelperService } from "core-app/core/path-helper/path-helper.service";

describe('GitActionsService', function() {
  let service:GitActionsService;

  const createWorkPackage = (overrides = {}) => {
    const defaults = {
      id: '76954',
      subject: '[eet]Review and Deploy Retail Store',
      type: { name: 'Story' },
      pathHelper: new PathHelperService()
    };
    const workPackage = { ...defaults, ...overrides };
    return(workPackage as WorkPackageResource);
  };

  beforeEach(waitForAsync(() => {
    TestBed.configureTestingModule({
      providers: [
        GitActionsService
      ]
    }).compileComponents()
      .then(() => {
        service = TestBed.inject(GitActionsService);
      });
  }));

  beforeEach(() => {
    service = new GitActionsService();
  });

  it('produces a branch name without a suffix when none is given', () => {
    const wp = createWorkPackage();
    expect(service.branchName(wp)).toEqual('story/76954-eet-review-and-deploy-retail-store');
  });

  it('appends a given suffix to the branch name', () => {
    const wp = createWorkPackage();
    expect(service.branchName(wp, '0809-1430')).toEqual('story/76954-eet-review-and-deploy-retail-store-0809-1430');
  });

  describe('with a subject too long for the server-side branch name limit', () => {
    const longSubject = 'Premium Report - PandaSuite doesn\'t show share/comment function and numbers on '
      + 'desktop, breaking news banner breaks the full-screen experience, sticky bar at the top of '
      + 'article page doesn\'t transition to share/comment, different display sizes show cut-off text';

    it('trims the title so the suffixed name still fits the limit', () => {
      const wp = createWorkPackage({ id: '83439', subject: longSubject, type: { name: 'BUG' } });
      const name = service.branchName(wp, '0813-1200');

      expect(name.length).toBeLessThanOrEqual(GitActionsService.MAX_BRANCH_NAME_LENGTH);
      expect(name).toEqual('bug/83439-premium-report-pandasuite-doesn-t-show-share-comment-function-and-numbers-on-'
        + 'desktop-breaking-news-banner-breaks-the-full-screen-experience-sticky-bar-at-the-top-of-'
        + 'article-page-do-0813-1200');
    });

    it('keeps the work package id prefix and the whole suffix intact', () => {
      const wp = createWorkPackage({ id: '83439', subject: longSubject, type: { name: 'BUG' } });

      expect(service.branchName(wp, '0813-1200')).toMatch(/^bug\/83439-.*-0813-1200$/);
    });

    // Both names fill the limit exactly, so comparing their lengths proves nothing.
    // What matters is that the suffix is paid for out of the title's budget rather
    // than added on top of it, or clipped.
    it('pays for the suffix out of the title, keeping the suffix whole', () => {
      const wp = createWorkPackage({ id: '83439', subject: longSubject, type: { name: 'BUG' } });
      const suffix = '0813-1200';
      const prefix = 'bug/83439-';

      const suffixed = service.branchName(wp, suffix);
      const unsuffixed = service.branchName(wp);

      expect(suffixed.length).toEqual(GitActionsService.MAX_BRANCH_NAME_LENGTH);
      expect(unsuffixed.length).toEqual(GitActionsService.MAX_BRANCH_NAME_LENGTH);
      expect(suffixed.endsWith(`-${suffix}`)).toBe(true);

      // The title gives up exactly the characters the `-<suffix>` tail costs
      const titleWithSuffix = suffixed.slice(prefix.length, -(suffix.length + 1));
      const titleWithout = unsuffixed.slice(prefix.length);
      expect(titleWithout.length - titleWithSuffix.length).toEqual(suffix.length + 1);
      expect(titleWithout.startsWith(titleWithSuffix)).toBe(true);
    });

    it('scales the room reserved to the length of the suffix given', () => {
      const wp = createWorkPackage({ id: '83439', subject: longSubject, type: { name: 'BUG' } });

      expect(service.branchName(wp, 'x').length).toEqual(GitActionsService.MAX_BRANCH_NAME_LENGTH);
      expect(service.branchName(wp, 'x'.repeat(50)).length)
        .toEqual(GitActionsService.MAX_BRANCH_NAME_LENGTH);
      expect(service.branchName(wp, 'x'.repeat(50)).endsWith(`-${'x'.repeat(50)}`)).toBe(true);
    });

    it('does not leave a trailing dash where the title was cut', () => {
      // 'ab' lands exactly on the cut, so the following dash would be left dangling
      const filler = 'ab-'.repeat(80);
      const wp = createWorkPackage({ id: '76954', subject: filler, type: { name: 'Story' } });

      expect(service.branchName(wp, '0813-1200')).not.toMatch(/--0813-1200$/);
    });

    // A type name may be up to 255 characters, which overruns the whole budget on
    // its own, so trimming the title alone is not enough to stay within it.
    it('trims the type too when the type name alone overruns the limit', () => {
      const wp = createWorkPackage({ id: '76954', subject: longSubject, type: { name: 'T'.repeat(255) } });
      const name = service.branchName(wp, '0813-1200');

      expect(name.length).toBeLessThanOrEqual(GitActionsService.MAX_BRANCH_NAME_LENGTH);
      expect(name).toMatch(/^t+\/76954-/);
      expect(name.endsWith('-0813-1200')).toBe(true);
    });

    it('keeps the whole name within the limit for every type name length', () => {
      for (let typeLength = 1; typeLength <= 255; typeLength += 1) {
        const wp = createWorkPackage({ id: '76954', subject: longSubject, type: { name: 'T'.repeat(typeLength) } });
        const name = service.branchName(wp, '0813-1200');

        expect(name.length).toBeLessThanOrEqual(GitActionsService.MAX_BRANCH_NAME_LENGTH);
        // The server rejects any name that does not carry `<id>-` as a segment start
        expect(name).toMatch(/(^|\/)76954-/);
        expect(name).toMatch(/^[a-z0-9][a-z0-9\-/]*$/);
        expect(name.endsWith('-0813-1200')).toBe(true);
      }
    });

    it('does not double up the prefix dash when no room is left for the title', () => {
      const wp = createWorkPackage({ id: '76954', subject: longSubject, type: { name: 'a'.repeat(188) } });
      const name = service.branchName(wp, '0813-1200');

      expect(name).toEqual(`${'a'.repeat(183)}/76954-0813-1200`);
      expect(name.length).toBeLessThanOrEqual(GitActionsService.MAX_BRANCH_NAME_LENGTH);
    });
  });

  describe('with a subject that sanitizes to nothing', () => {
    it('keeps the id separator so the server still matches the work package', () => {
      const wp = createWorkPackage({ subject: '###' });

      expect(service.branchName(wp)).toEqual('story/76954-');
      expect(service.branchName(wp)).toMatch(/(^|\/)76954-/);
    });

    it('lets the suffix supply the separator when one is given', () => {
      const wp = createWorkPackage({ subject: '###' });

      expect(service.branchName(wp, '0813-1200')).toEqual('story/76954-0813-1200');
    });
  });

  it('formats the timestamp suffix as MMDD-HHmm, zero-padded', () => {
    const date = new Date(2026, 0, 5, 9, 3); // Jan 5th, 09:03 (month is 0-indexed)
    expect(service.timestampSuffix(date)).toEqual('0105-0903');
  });

  it('produces a plain-text commit message ending with the work package URL', () => {
    const wp = createWorkPackage();
    expect(service.commitMessage(wp)).toEqual(`OP#76954 [eet]Review and Deploy Retail Store

http://localhost:9876/work_packages/76954
`);
  });

  it('produces a Markdown-linked merge request message without a trailing URL line', () => {
    const wp = createWorkPackage();
    expect(service.mergeRequestMessage(wp))
      .toEqual('[OP#76954](http://localhost:9876/work_packages/76954) [eet]Review and Deploy Retail Store');
  });

  it('the display text matches the copyable text when the message has no second paragraph', () => {
    const wp = createWorkPackage();
    expect(service.mergeRequestMessageDisplayText(wp)).toEqual(service.mergeRequestMessage(wp));
  });

  it('embeds the suffixed branch name and plain-text commit message in the git command', () => {
    const wp = createWorkPackage();
    expect(service.gitCommand(wp, '0809-1430')).toEqual(`git checkout -b 'story/76954-eet-review-and-deploy-retail-store-0809-1430' && git commit --allow-empty -m 'OP#76954 [eet]Review and Deploy Retail Store

http://localhost:9876/work_packages/76954
'`);
  });

  it('shell-escapes output for the git-command', () => {
    const wp = createWorkPackage({ subject: "' && rm -rf / #" });
    expect(service.gitCommand(wp)).toEqual(`git checkout -b 'story/76954-and-and-rm-rf' && git commit --allow-empty -m 'OP#76954 \\' && rm -rf / #

http://localhost:9876/work_packages/76954
'`);
  });
});
