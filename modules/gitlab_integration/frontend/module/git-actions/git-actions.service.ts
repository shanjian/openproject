//-- copyright
// OpenProject is an open source project management software.
// Copyright (C) 2023 Ben Tey
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License version 3.
//
// OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
// Copyright (C) 2006-2013 Jean-Philippe Lang
// Copyright (C) 2010-2013 the ChiliProject Team
// Copyright (C) the OpenProject GmbH
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
// See docs/COPYRIGHT.rdoc for more details.
//++

import { Injectable } from '@angular/core';
import { WorkPackageResource } from "core-app/features/hal/resources/work-package-resource";

// probably not providable in root when we want to cache the formatter and set custom templates
@Injectable({
  providedIn: 'root',
})
export class GitActionsService {
  // Mirrors the length allowed by CreateBranchService::BRANCH_NAME_PATTERN. Long
  // work package subjects have to be trimmed here rather than rejected on
  // submit, since this name is what gets displayed, copied and created.
  public static readonly MAX_BRANCH_NAME_LENGTH = 200;

  private sanitizeBranchString(str:string):string {
    // See https://stackoverflow.com/a/3651867 for how these rules came in.
    // This sanitization tries to be harsher than those rules
    return str
      .replace(/&/g, "and ") // & becomes and
      .replace(/\W+/g, "-") // Replace any consecutive non ascii characters by a single dash as they might make trouble in some tools.
      .replace(/^-/g, "") // Dash at the start is removed
      .replace(/-$/g, "") // Dash at the end is removed
      .trim();
  }

  private formattingInput(workPackage: WorkPackageResource) {
    const type = workPackage.type.name || '';
    const id = workPackage.id || '';
    const title = workPackage.subject;
    const url = window.location.origin + workPackage.pathHelper.workPackagePath(id);
    const description = '';

    return({
      id, type, title, url, description
    });
  }

  private sanitizeShellInput(str:string):string {
    return `${str.replace(/'/g, '\\\'')}`;
  }

  // Lets follow-up branches for the same work package (continuing or patching
  // prior work) get a distinct name instead of colliding with the first branch.
  public timestampSuffix(date:Date = new Date()):string {
    const pad = (value:number) => value.toString().padStart(2, '0');
    const month = pad(date.getMonth() + 1);
    const day = pad(date.getDate());
    const hours = pad(date.getHours());
    const minutes = pad(date.getMinutes());
    return `${month}${day}-${hours}${minutes}`;
  }

  // Only the title slug is shortened when the name would exceed
  // MAX_BRANCH_NAME_LENGTH: the `<type>/<id>-` prefix is what
  // NotificationHandler::Helper#branch_follows_convention? matches branches back
  // to work packages with, and the suffix is what keeps follow-up branches for
  // the same work package distinct, so both keep their full length.
  public branchName(workPackage:WorkPackageResource, suffix?:string):string {
    const { type, id, title } = this.formattingInput(workPackage);
    const prefix = `${this.sanitizeBranchString(type)}/${id}-`.toLocaleLowerCase();
    const tail = suffix ? `-${suffix}` : '';
    const slug = this.sanitizeBranchString(title).toLocaleLowerCase();
    const room = GitActionsService.MAX_BRANCH_NAME_LENGTH - prefix.length - tail.length;

    if (slug.length <= room) {
      return `${prefix}${slug}${tail}`;
    }

    // Trailing dashes would otherwise be left behind by cutting mid-word, and an
    // empty slug would leave the prefix's dash doubled up against the suffix.
    const trimmed = slug.slice(0, Math.max(room, 0)).replace(/-+$/, '');
    return trimmed ? `${prefix}${trimmed}${tail}` : `${prefix.replace(/-$/, '')}${tail}`;
  }

  public commitMessage(workPackage:WorkPackageResource):string {
    const { title, id, description, url } = this.formattingInput(workPackage);
    return `OP#${id} ${title}

${description}

${url}
`.replace(/\n\n+/g, '\n\n');
  }

  public commitMessageDisplayText(workPackage:WorkPackageResource):string {
    return this.commitMessage(workPackage).replace(/\n\n/g, ' ');
  }

  // Markdown-formatted, meant for pasting into a GitLab merge request description
  // (which renders Markdown) rather than for `git commit -m`, so it carries a
  // clickable OP# link instead of the plain-text commit message's trailing URL line.
  public mergeRequestMessage(workPackage:WorkPackageResource):string {
    const { title, id, description, url } = this.formattingInput(workPackage);
    const header = `[OP#${id}](${url}) ${title}`;
    return description ? `${header}\n\n${description}` : header;
  }

  public mergeRequestMessageDisplayText(workPackage:WorkPackageResource):string {
    return this.mergeRequestMessage(workPackage).replace(/\n\n/g, ' ');
  }

  public gitCommand(workPackage:WorkPackageResource, suffix?:string):string {
    const branch = this.branchName(workPackage, suffix);
    const commit = this.commitMessage(workPackage);
    return `git checkout -b '${this.sanitizeShellInput(branch)}' && git commit --allow-empty -m '${this.sanitizeShellInput(commit)}'`;
  }
}
