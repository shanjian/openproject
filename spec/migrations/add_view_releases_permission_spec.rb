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

require "spec_helper"
require Rails.root.join("db/migrate/20260618120000_add_view_releases_permission")

RSpec.describe AddViewReleasesPermission, type: :model do
  describe "up migration" do
    it "adds view_releases to roles that can view work packages" do
      role = create(:project_role, permissions: %i[view_work_packages])

      ActiveRecord::Migration.suppress_messages { described_class.migrate(:up) }

      expect(role.reload.has_permission?(:view_releases)).to be true
    end

    it "leaves roles without view_work_packages untouched" do
      role = create(:project_role, permissions: %i[view_wiki_pages])

      ActiveRecord::Migration.suppress_messages { described_class.migrate(:up) }

      expect(role.reload.has_permission?(:view_releases)).to be false
    end

    it "does not grant the member-only permission to the builtin Non member role" do
      role = create(:non_member, permissions: %i[view_work_packages])

      ActiveRecord::Migration.suppress_messages { described_class.migrate(:up) }

      expect(role.reload.has_permission?(:view_releases)).to be false
    end

    it "does not grant the member-only permission to the builtin Anonymous role" do
      role = create(:anonymous_role, permissions: %i[view_work_packages])

      ActiveRecord::Migration.suppress_messages { described_class.migrate(:up) }

      expect(role.reload.has_permission?(:view_releases)).to be false
    end

    it "does not duplicate the permission when already present" do
      role = create(:project_role, permissions: %i[view_work_packages view_releases])

      ActiveRecord::Migration.suppress_messages { described_class.migrate(:up) }

      expect(role.reload.permissions.count(:view_releases)).to eq(1)
    end
  end

  describe "down migration" do
    it "removes view_releases from all roles" do
      role = create(:project_role, permissions: %i[view_work_packages view_releases])

      ActiveRecord::Migration.suppress_messages { described_class.migrate(:down) }

      expect(role.reload.has_permission?(:view_releases)).to be false
    end
  end
end
