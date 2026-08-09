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
