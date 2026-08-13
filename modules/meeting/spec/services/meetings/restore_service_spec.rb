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

RSpec.describe Meetings::RestoreService do
  shared_let(:project) { create(:project, enabled_module_names: %w[meetings]) }
  shared_let(:user) do
    create(:user, member_with_permissions: { project => %i[view_meetings edit_meetings] })
  end
  shared_let(:participant_user) { create(:user, member_with_permissions: { project => %i[view_meetings] }) }

  let(:notify) { true }
  let(:meeting) do
    create(:meeting, project:, notify:,
                     state: "cancelled",
                     state_before_cancellation: Meeting.states["in_progress"])
  end
  let(:service) { described_class.new(meeting, current_user: user) }

  before do
    create(:meeting_participant, meeting:, user: participant_user, invited: true)
    ActionMailer::Base.deliveries.clear
  end

  it "restores the previous state and clears the marker" do
    result = service.call

    expect(result).to be_success
    expect(meeting.reload.state).to eq "in_progress"
    expect(meeting.state_before_cancellation).to be_nil
  end

  context "when the meeting is muted" do
    let(:notify) { false }

    it "re-sends the invitation so calendars re-add the event" do
      service.call
      perform_enqueued_jobs

      expect(ActionMailer::Base.deliveries.flat_map(&:to)).to contain_exactly(participant_user.mail)
    end
  end

  it "refuses meetings that are not cancelled" do
    meeting.update_columns(state: Meeting.states[:open], state_before_cancellation: nil)

    expect(service.call).to be_failure
  end

  it "refuses users without edit_meetings" do
    viewer = create(:user, member_with_permissions: { project => %i[view_meetings] })

    expect(described_class.new(meeting, current_user: viewer).call).to be_failure
    expect(meeting.reload.state).to eq "cancelled"
  end
end
