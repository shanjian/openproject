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

RSpec.describe Meetings::CancelService do
  shared_let(:project) { create(:project, enabled_module_names: %w[meetings]) }
  shared_let(:user) do
    create(:user, member_with_permissions: { project => %i[view_meetings edit_meetings] })
  end
  shared_let(:participant_user) { create(:user, member_with_permissions: { project => %i[view_meetings] }) }

  let(:state) { "open" }
  let(:notify) { true }
  let(:meeting) { create(:meeting, project:, notify:, state:) }
  let(:service) { described_class.new(meeting, current_user: user) }

  before do
    create(:meeting_participant, meeting:, user: participant_user, invited: true)
    ActionMailer::Base.deliveries.clear
  end

  describe "cancelling an open meeting" do
    it "sets the cancelled state and remembers the previous one" do
      result = service.call

      expect(result).to be_success
      expect(meeting.reload).to be_cancelled
      expect(meeting.state_before_cancellation).to eq Meeting.states["open"]
    end

    it "remembers an in_progress state" do
      meeting.update_column(:state, Meeting.states[:in_progress])

      expect(service.call).to be_success
      expect(meeting.reload.state_before_cancellation).to eq Meeting.states["in_progress"]
    end

    it "clears a pending batched update job" do
      allow(Meetings::SendUpdatedNotificationJob).to receive(:delete_jobs)

      service.call

      expect(Meetings::SendUpdatedNotificationJob).to have_received(:delete_jobs).with(meeting)
    end

    it "clears a pending participation digest job" do
      allow(Meetings::SendParticipationDigestJob).to receive(:delete_jobs)

      service.call

      expect(Meetings::SendParticipationDigestJob).to have_received(:delete_jobs).with(meeting)
    end

    context "when the meeting is muted" do
      let(:notify) { false }

      it "still sends the cancellation mail" do
        service.call
        perform_enqueued_jobs

        expect(ActionMailer::Base.deliveries.flat_map(&:to)).to contain_exactly(participant_user.mail)
      end
    end
  end

  describe "guards" do
    it "refuses closed meetings" do
      meeting.update_column(:state, Meeting.states[:closed])

      expect(service.call).to be_failure
      expect(meeting.reload).not_to be_cancelled
    end

    it "refuses drafts" do
      meeting.update_column(:state, Meeting.states[:draft])

      expect(service.call).to be_failure
    end

    it "refuses templates" do
      template = create(:onetime_template, project:)

      expect(described_class.new(template, current_user: user).call).to be_failure
    end

    it "refuses recurring occurrences" do
      series = create(:recurring_meeting, project:)
      occurrence = create(:meeting, project:, recurring_meeting: series, notify: true)

      expect(described_class.new(occurrence, current_user: user).call).to be_failure
    end

    it "refuses users without edit_meetings" do
      viewer = create(:user, member_with_permissions: { project => %i[view_meetings] })

      expect(described_class.new(meeting, current_user: viewer).call).to be_failure
      expect(meeting.reload).not_to be_cancelled
    end
  end
end
