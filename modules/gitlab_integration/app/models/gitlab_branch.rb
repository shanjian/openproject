# frozen_string_literal: true

#-- encoding: UTF-8

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
# Copyright (C) the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See docs/COPYRIGHT.rdoc for more details.
#++

class GitlabBranch < ApplicationRecord
  # Mirrors GitlabMergeRequest / GitlabIssue, which associate work packages the
  # same way; a join model would diverge from the rest of the module.
  has_and_belongs_to_many :work_packages # rubocop:disable Rails/HasAndBelongsToMany

  validates :name,
            :gitlab_html_url,
            :repository,
            :gitlab_updated_at,
            presence: true

  scope :without_work_package, -> { where.missing(:work_packages) }

  # Builds the GitLab tree URL for a branch. The branch name is escaped per path
  # segment so refs containing URL-significant characters (e.g. `#`, which is a
  # valid Git ref char but would otherwise be read as a fragment) resolve to the
  # branch, while the `/` separators of the `{type}/{id}-{slug}` convention are
  # preserved as GitLab keeps them.
  def self.build_html_url(project_web_url, branch_name)
    escaped = branch_name.to_s.split("/").map { |segment| ERB::Util.url_encode(segment) }.join("/")
    "#{project_web_url}/-/tree/#{escaped}"
  end

  # A branch has no per-project iid; its web URL (which embeds the project path
  # and the branch name) is globally unique and stable, so it is the identity.
  def self.find_by_gitlab_identifiers(url:, initialize: false)
    raise ArgumentError, "needs an url" if url.blank?

    found = find_by(gitlab_html_url: url)

    if found
      found
    elsif initialize
      new(gitlab_html_url: url)
    end
  end
end
