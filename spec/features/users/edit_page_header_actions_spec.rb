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

# Regression coverage for the user edit page header actions. `Primer::OpenProject::PageHeader`
# raises if more than 5 top-level actions are added (Profile + one action button per item can
# exceed that once invitation/password-reset links, status changes, and delete are all eligible
# at once), so these actions are bundled into a single "more" menu rather than individual buttons.
RSpec.describe "user edit page header actions" do
  shared_let(:admin) { create(:admin) }

  def expect_menu_with_content(*labels)
    expect(page).to have_css('[data-test-selector="user-more-dropdown-menu"]')
    labels.each { |label| expect(page).to have_content(label) }
  end

  context "as admin, with deletion enabled", with_settings: { users_deletable_by_admins: true } do
    it "renders for an active, unblocked target (previously the most common production case)" do
      login_as(admin)
      target = create(:user)
      visit edit_user_path(target)
      expect_menu_with_content("Send invitation", "Copy invitation link",
                                "Copy password reset link", "Lock", "Delete")
    end

    it "renders for an active, blocked target (worst case: 2 status actions)" do
      login_as(admin)
      target = create(:user)
      allow_any_instance_of(User).to receive(:failed_too_many_recent_login_attempts?).and_return(true)
      visit edit_user_path(target)
      expect_menu_with_content("Send invitation", "Copy invitation link",
                                "Copy password reset link", "Delete")
    end

    it "renders for a locked target" do
      login_as(admin)
      target = create(:locked_user)
      visit edit_user_path(target)
      expect_menu_with_content("Send invitation", "Copy invitation link", "Unlock", "Delete")
    end

    it "renders for an invited target" do
      login_as(admin)
      target = create(:invited_user)
      visit edit_user_path(target)
      expect_menu_with_content("Send invitation", "Copy invitation link", "Delete")
    end

    it "omits the password reset item for an LDAP-authenticated target" do
      login_as(admin)
      target = create(:user, ldap_auth_source: create(:ldap_auth_source))
      visit edit_user_path(target)
      expect(page).to have_no_content("Copy password reset link")
    end

    it "renders when the admin edits their own profile" do
      login_as(admin)
      visit edit_user_path(admin)
      expect(page).to have_content(admin.name)
    end
  end

  context "as a manage_user-only (non-admin, no create_user) viewer" do
    let(:viewer) { create(:user, global_permissions: %i[view_all_principals manage_user]) }

    it "shows only the password reset item for an active target" do
      login_as(viewer)
      target = create(:user)
      visit edit_user_path(target)
      expect_menu_with_content("Copy password reset link")
      expect(page).to have_no_content("Send invitation")
      expect(page).to have_no_content("Delete")
    end

    it "shows no menu at all for a locked target" do
      login_as(viewer)
      target = create(:locked_user)
      visit edit_user_path(target)
      expect(page).to have_no_css('[data-test-selector="user-more-dropdown-menu"]')
    end
  end
end
