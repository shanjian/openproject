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

RSpec.describe Meetings::SidePanel::ParticipantsComponent, type: :component do
  shared_let(:project) { create(:project, enabled_module_names: %w[meetings]) }
  shared_let(:user) { create(:user, member_with_permissions: { project => %i[view_meetings] }) }
  shared_let(:other_user) { create(:user, member_with_permissions: { project => %i[view_meetings] }) }

  let(:state) { "open" }
  let(:meeting) { create(:meeting, project:, state:) }

  subject do
    render_inline(described_class.new(meeting:))
    page
  end

  before do
    login_as(user)
  end

  describe "response summary" do
    it "shows aggregate counts over invited participants, folding pending states" do
      create(:meeting_participant, meeting:, user:, invited: true, participation_status: "accepted")
      create(:meeting_participant, meeting:, user: other_user, invited: true, participation_status: "needs_action")

      expect(subject).to have_test_selector("participants-response-summary")
      summary = subject.find_by_id("participants-response-summary", visible: :all).text
      expect(summary).to include("1 accepted")
      expect(summary).to include("1 pending")
    end

    it "is omitted when nobody is invited" do
      create(:meeting_participant, meeting:, user:, invited: false)

      expect(subject).not_to have_test_selector("participants-response-summary")
    end
  end

  describe "your response block" do
    it "offers the three respond buttons to an invited participant" do
      create(:meeting_participant, meeting:, user:, invited: true)

      expect(subject).to have_test_selector("meeting-respond-block")
      expect(subject).to have_test_selector("meeting-respond-accepted")
      expect(subject).to have_test_selector("meeting-respond-tentative")
      expect(subject).to have_test_selector("meeting-respond-declined")
    end

    it "submits one-off responses through POST forms, not GET-able links" do
      create(:meeting_participant, meeting:, user:, invited: true)

      # An <a href> to the POST-only route would 404 on middle-click / plain GET
      expect(subject).to have_css(
        "form[action*='/meetings/#{meeting.id}/respond'][method='post'] " \
        "[data-test-selector='meeting-respond-accepted']"
      )
      expect(subject).to have_no_css("a[data-test-selector='meeting-respond-accepted']")
    end

    it "is hidden for non-participants" do
      create(:meeting_participant, meeting:, user: other_user, invited: true)

      expect(subject).not_to have_test_selector("meeting-respond-block")
    end

    context "when the meeting is closed" do
      let(:state) { "closed" }

      it "is hidden" do
        create(:meeting_participant, meeting:, user:, invited: true)

        expect(subject).not_to have_test_selector("meeting-respond-block")
      end
    end

    context "when the meeting is cancelled" do
      let(:state) { "cancelled" }

      it "is hidden" do
        create(:meeting_participant, meeting:, user:, invited: true)

        expect(subject).not_to have_test_selector("meeting-respond-block")
      end
    end
  end
end
