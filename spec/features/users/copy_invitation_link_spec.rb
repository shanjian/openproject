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

RSpec.describe "Copying an invitation link", :js do
  shared_let(:admin) { create(:admin) }
  shared_let(:invited_user) { create(:invited_user) }

  before do
    login_as admin
  end

  it "opens a dialog with the activation link, without sending an email" do
    visit edit_user_path(invited_user)

    perform_enqueued_jobs do
      page.find('[data-test-selector="user-more-dropdown-menu"]').click
      click_on "Copy invitation link"
    end

    expect(page).to have_css("dialog##{Users::ShareableLinkDialogComponent::DIALOG_ID}", visible: true, wait: 10)

    token = Token::Invitation.find_by(user_id: invited_user.id)
    expect(page).to have_css(
      "clipboard-copy[value*='/account/activate'][value*='token=#{token.value}']",
      visible: true
    )
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it "also opens the dialog from the user's show page (a separate action button, not the edit-page menu)" do
    visit user_path(invited_user)

    perform_enqueued_jobs do
      click_on "Copy invitation link"
    end

    expect(page).to have_css("dialog##{Users::ShareableLinkDialogComponent::DIALOG_ID}", visible: true, wait: 10)
  end

  context "when a regular user without create_user views their own profile" do
    let(:user) { create(:user) }

    before do
      login_as user
    end

    it "does not show the button" do
      visit user_path(user)

      expect(page).to have_no_link("Copy invitation link")
    end
  end
end
