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

RSpec.describe MeetingParticipants::RespondService do
  shared_let(:project) { create(:project, enabled_module_names: %w[meetings]) }
  shared_let(:user) { create(:user, member_with_permissions: { project => %i[view_meetings] }) }

  let(:state) { "open" }
  let(:meeting) { create(:meeting, project:, state:) }
  let!(:participant) { create(:meeting_participant, meeting:, user:, invited: true) }

  def call(status: "accepted", scope: nil, on: meeting)
    described_class.new(on, current_user: user).call(status:, scope:)
  end

  describe "one-off meetings" do
    it "sets the status and stamps the response time" do
      result = call(status: "tentative")

      expect(result).to be_success
      expect(participant.reload).to be_participation_tentative
      expect(participant.participation_responded_at).to be_present
      expect(participant.comment).to be_nil
    end

    it "clears a stale email comment so the digest cannot pair it with the new status" do
      participant.update_column(:comment, "Can't make it — traveling")

      expect(call(status: "accepted")).to be_success
      expect(participant.reload.comment).to be_nil
    end

    it "returns a failure instead of raising when the write blows up mid-flight" do
      allow_any_instance_of(MeetingParticipant) # rubocop:disable RSpec/AnyInstance
        .to receive(:update!).and_raise(ActiveRecord::RecordInvalid)

      result = nil
      expect { result = call }.not_to raise_error
      expect(result).to be_failure
    end

    it "enqueues the digest keyed on the meeting" do
      expect { call }.to(have_enqueued_job(Meetings::SendParticipationDigestJob)
        .with { |target, since:| expect([target, since.present?]).to eq [meeting, true] })
    end

    it "rejects invalid statuses" do
      expect(call(status: "needs_action")).to be_failure
      expect(call(status: "unknown")).to be_failure
      expect(participant.reload).to be_participation_needs_action
    end

    it "rejects users without a participant row" do
      other = create(:user, member_with_permissions: { project => %i[view_meetings] })

      result = described_class.new(meeting, current_user: other).call(status: "accepted")

      expect(result).to be_failure
    end

    it "rejects non-invited participants" do
      participant.update_column(:invited, false)

      expect(call).to be_failure
    end

    %w[draft closed cancelled].each do |bad_state|
      it "rejects #{bad_state} meetings" do
        meeting.update_column(:state, Meeting.states[bad_state])

        expect(call).to be_failure
        expect(participant.reload).to be_participation_needs_action
      end
    end

    it "rejects templates" do
      template = create(:onetime_template, project:)
      create(:meeting_participant, meeting: template, user:, invited: true)

      expect(call(on: template)).to be_failure
    end

    it "ignores the series scope on one-offs" do
      expect(call(scope: "series")).to be_success
      expect(participant.reload).to be_participation_accepted
    end
  end

  describe "recurring occurrences" do
    let(:series) do
      create(:recurring_meeting,
             project:,
             start_time: 1.week.ago.beginning_of_day + 10.hours,
             frequency: "daily", interval: 1,
             end_after: "specific_date", end_date: 1.month.from_now)
    end
    let(:occurrence) do
      create(:scheduled_meeting, :persisted,
             recurring_meeting: series,
             start_time: 2.days.from_now.beginning_of_day + 10.hours).meeting
    end
    let!(:occurrence_participant) do
      create(:meeting_participant, meeting: occurrence, user:, invited: true)
    end
    let!(:template_participant) do
      create(:meeting_participant, meeting: series.template, user:, invited: true)
    end
    let!(:other_future_participant) do
      other = create(:scheduled_meeting, :persisted,
                     recurring_meeting: series,
                     start_time: 3.days.from_now.beginning_of_day + 10.hours).meeting
      create(:meeting_participant, meeting: other, user:, invited: true,
                                   participation_status: "declined")
    end

    it "updates only the occurrence for scope=occurrence" do
      result = described_class.new(occurrence, current_user: user).call(status: "accepted", scope: "occurrence")

      expect(result).to be_success
      expect(occurrence_participant.reload).to be_participation_accepted
      expect(template_participant.reload).to be_participation_needs_action
      expect(other_future_participant.reload).to be_participation_declined
    end

    it "updates the template and all future occurrences for scope=series" do
      result = described_class.new(occurrence, current_user: user).call(status: "accepted", scope: "series")

      expect(result).to be_success
      expect(occurrence_participant.reload).to be_participation_accepted
      expect(template_participant.reload).to be_participation_accepted
      expect(other_future_participant.reload).to be_participation_accepted
    end

    it "clears stale comments on every row the series sweep touches" do
      occurrence_participant.update_column(:comment, "old comment")
      template_participant.update_column(:comment, "old comment")

      result = described_class.new(occurrence, current_user: user).call(status: "accepted", scope: "series")

      expect(result).to be_success
      expect(occurrence_participant.reload.comment).to be_nil
      expect(template_participant.reload.comment).to be_nil
    end

    it "updates the responded-on occurrence for scope=series even when it has already started" do
      started = create(:scheduled_meeting, :persisted,
                       recurring_meeting: series,
                       start_time: 10.minutes.ago).meeting
      started_participant = create(:meeting_participant, meeting: started, user:, invited: true)

      result = described_class.new(started, current_user: user).call(status: "declined", scope: "series")

      expect(result).to be_success
      expect(started_participant.reload).to be_participation_declined
      expect(started_participant.participation_responded_at).to be_present
      expect(template_participant.reload).to be_participation_declined
    end

    it "enqueues the digest keyed on the series" do
      expect do
        described_class.new(occurrence, current_user: user).call(status: "accepted", scope: "occurrence")
      end.to(have_enqueued_job(Meetings::SendParticipationDigestJob)
        .with { |target, since:| expect([target, since.present?]).to eq [series, true] })
    end
  end
end
