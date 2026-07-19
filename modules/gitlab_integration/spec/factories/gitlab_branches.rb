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

FactoryBot.define do
  factory :gitlab_branch do
    sequence(:name) { |n| "task/#{n}-some-work" }
    sequence(:gitlab_html_url) { |n| "https://gitlab.com/test_user/test_repo/-/tree/task/#{n}-some-work" }
    sequence(:repository) { |n| "test_user/repo_#{n}" }

    last_commit_sha { "a265d6b7bcf836b77ed9e32f824b231585c6a355" }
    last_commit_message { "Some commit" }
    last_commit_html_url { "https://gitlab.com/test_user/test_repo/-/commit/a265d6b7" }
    last_commit_author { "Some Committer" }
    gitlab_updated_at { Time.current }
  end
end
