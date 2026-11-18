# frozen_string_literal: true

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
# See COPYRIGHT and LICENSE files for more details.
#++

# A Git branch pushed to GitHub that references one or more work packages, either
# by OpenProject's `{type}/{id}-{title}` branch-naming convention or by an
# explicit `OP#<id>` in its name. It is created from `push` webhooks.
class GithubBranch < ApplicationRecord
  # Mirrors GithubPullRequest, which associates work packages the same way.
  has_and_belongs_to_many :work_packages # rubocop:disable Rails/HasAndBelongsToMany

  validates :name,
            :github_html_url,
            :repository,
            :github_updated_at,
            presence: true

  scope :without_work_package, -> { where.missing(:work_packages) }

  # Builds the GitHub tree URL for a branch. The branch name is escaped per path
  # segment so refs containing URL-significant characters (e.g. `#`, which is a
  # valid Git ref char but would otherwise be read as a fragment) resolve to the
  # branch, while the `/` separators of the `{type}/{id}-{title}` convention are
  # preserved as GitHub keeps them.
  def self.build_html_url(repository_html_url, branch_name)
    escaped = branch_name.to_s.split("/").map { |segment| ERB::Util.url_encode(segment) }.join("/")
    "#{repository_html_url}/tree/#{escaped}"
  end

  # A branch has no id of its own in the push payload; its web URL (which embeds
  # the repository and the branch name) is globally unique and stable, so it is
  # the identity.
  def self.find_by_github_identifiers(url:, initialize: false)
    raise ArgumentError, "needs an url" if url.blank?

    found = find_by(github_html_url: url)

    if found
      found
    elsif initialize
      new(github_html_url: url)
    end
  end
end
