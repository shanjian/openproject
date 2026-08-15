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

require "rails_helper"

RSpec.describe Meetings::SidePanel::StateComponent, type: :component do
  shared_let(:project) { create(:project, enabled_module_names: %w[meetings]) }
  let(:meeting) do
    create(:meeting, project:,
                     state: "cancelled", state_before_cancellation: Meeting.states["open"])
  end

  subject do
    render_inline(described_class.new(meeting:))
    page
  end

  before do
    login_as(user)
  end

  context "with edit_meetings permission" do
    let(:user) { create(:user, member_with_permissions: { project => %i[view_meetings edit_meetings] }) }

    it "offers the Restore button on a cancelled meeting" do
      expect(subject).to have_test_selector("restore-meeting-button")
    end
  end

  context "with only manage_agendas permission" do
    let(:user) { create(:user, member_with_permissions: { project => %i[view_meetings manage_agendas] }) }

    it "does not offer Restore (the endpoint requires edit_meetings)" do
      expect(subject).to have_test_selector("meeting-cancelled-label")
      expect(subject).not_to have_test_selector("restore-meeting-button")
    end
  end

  context "with an in-progress meeting" do
    let(:user) { create(:user, member_with_permissions: { project => %i[view_meetings edit_meetings] }) }
    let(:meeting) { create(:meeting, project:, state: "in_progress") }

    it "routes the close button to the dialog with GET" do
      expect(subject).to have_css('[data-test-selector="close-meeting-button"][data-method="GET"]')
    end
  end
end
