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

RSpec.describe Users::ShareableLinkDialogComponent, type: :component do
  let(:link) { "https://example.org/account/activate?token=abc123" }

  before do
    render_inline(described_class.new(link:, title: "Invitation link", description: "Share this with the user."))
  end

  it "renders as a dialog" do
    expect(page).to have_css("dialog##{described_class::DIALOG_ID}", visible: :all)
  end

  it "shows the title" do
    expect(page).to have_text("Invitation link")
  end

  it "shows the description" do
    expect(page).to have_text("Share this with the user.")
  end

  it "renders the link in a clipboard-copy element" do
    expect(page).to have_css("clipboard-copy[value='#{link}']", visible: :all)
  end

  it "renders a close button" do
    expect(page).to have_button("Close")
  end
end
