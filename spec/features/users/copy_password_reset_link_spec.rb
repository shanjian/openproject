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

RSpec.describe "Copying a password reset link", :js do
  shared_let(:admin) { create(:admin) }
  shared_let(:active_user) { create(:user) }

  before do
    login_as admin
  end

  it "opens a dialog with the lost_password link, without sending an email" do
    visit edit_user_path(active_user)

    perform_enqueued_jobs do
      page.find('[data-test-selector="user-more-dropdown-menu"]').click
      click_on "Copy password reset link"
    end

    expect(page).to have_css("dialog##{Users::ShareableLinkDialogComponent::DIALOG_ID}", visible: true)

    token = Token::Recovery.find_by(user_id: active_user.id)
    expect(page).to have_css(
      "clipboard-copy[value*='/account/lost_password'][value*='token=#{token.value}']",
      visible: true
    )
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  context "when the viewer only has create_user, not manage_user" do
    let(:create_user_only) { create(:user, global_permissions: %i[view_all_principals create_user]) }

    before do
      login_as create_user_only
    end

    it "does not show the button" do
      visit user_path(active_user)

      expect(page).to have_no_link("Copy password reset link")
    end
  end

  context "when the target user is locked" do
    let(:locked_user) { create(:locked_user) }

    it "does not show the button" do
      visit user_path(locked_user)

      expect(page).to have_no_link("Copy password reset link")
    end
  end
end
