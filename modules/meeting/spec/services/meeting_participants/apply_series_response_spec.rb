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

RSpec.describe MeetingParticipants::ApplySeriesResponse do
  shared_let(:project) { create(:project, enabled_module_names: %w[meetings]) }
  shared_let(:user) { create(:user, member_with_permissions: { project => %i[view_meetings] }) }

  let(:series) do
    create(:recurring_meeting,
           project:,
           start_time: 1.week.ago.beginning_of_day + 10.hours,
           frequency: "daily", interval: 1,
           end_after: "specific_date", end_date: 1.month.from_now)
  end
  let!(:template_participant) do
    create(:meeting_participant, meeting: series.template, user:, invited: true)
  end
  let!(:future_pending) do
    occurrence = create(:scheduled_meeting, :persisted,
                        recurring_meeting: series,
                        start_time: 2.days.from_now.beginning_of_day + 10.hours).meeting
    create(:meeting_participant, meeting: occurrence, user:, invited: true,
                                 participation_status: "needs_action")
  end
  let!(:future_accepted) do
    occurrence = create(:scheduled_meeting, :persisted,
                        recurring_meeting: series,
                        start_time: 3.days.from_now.beginning_of_day + 10.hours).meeting
    create(:meeting_participant, meeting: occurrence, user:, invited: true,
                                 participation_status: "accepted")
  end
  let!(:past_pending) do
    occurrence = create(:scheduled_meeting, :persisted,
                        recurring_meeting: series,
                        start_time: 2.days.ago.beginning_of_day + 10.hours).meeting
    create(:meeting_participant, meeting: occurrence, user:, invited: true,
                                 participation_status: "needs_action")
  end

  let(:stamp) { Time.current.change(usec: 0) }
  let(:service) { described_class.new(series:, user:) }

  it "updates the template and all future occurrences when only_awaiting is false" do
    service.call(status: "declined", stamp:, only_awaiting: false)

    expect(template_participant.reload).to be_participation_declined
    expect(future_pending.reload).to be_participation_declined
    expect(future_accepted.reload).to be_participation_declined
    expect(template_participant.participation_responded_at).to eq stamp
    expect(future_pending.participation_responded_at).to eq stamp
  end

  it "only updates needs-action occurrences when only_awaiting is true (email semantics)" do
    service.call(status: "declined", stamp:, only_awaiting: true)

    expect(template_participant.reload).to be_participation_declined
    expect(future_pending.reload).to be_participation_declined
    expect(future_accepted.reload).to be_participation_accepted
  end

  it "never touches past occurrences" do
    service.call(status: "declined", stamp:, only_awaiting: false)

    expect(past_pending.reload).to be_participation_needs_action
    expect(past_pending.participation_responded_at).to be_nil
  end

  it "includes an explicitly passed row even when its occurrence already started" do
    service.call(status: "declined", stamp:, only_awaiting: false, also: past_pending)

    expect(past_pending.reload).to be_participation_declined
    expect(past_pending.participation_responded_at).to eq stamp
  end

  it "skips non-invited rows" do
    future_pending.update_column(:invited, false)
    template_participant.update_column(:invited, false)

    service.call(status: "declined", stamp:, only_awaiting: false)

    expect(future_pending.reload).to be_participation_needs_action
    expect(template_participant.reload).to be_participation_needs_action
    expect(future_accepted.reload).to be_participation_declined
  end

  it "returns a ServiceResult carrying the number of updated rows" do
    result = service.call(status: "declined", stamp:, only_awaiting: false)

    expect(result).to be_a(ServiceResult)
    expect(result).to be_success
    expect(result.result).to eq 3

    future_pending.destroy!
    future_accepted.destroy!
    template_participant.destroy!
    empty = described_class.new(series:, user:).call(status: "declined", stamp:, only_awaiting: false)
    expect(empty.result).to eq 0
  end

  it "writes the comment only when one is provided" do
    service.call(status: "accepted", stamp:, only_awaiting: false, comment: "Via email")
    expect(future_pending.reload.comment).to eq "Via email"

    service.call(status: "declined", stamp:, only_awaiting: false)
    expect(future_pending.reload.comment).to eq "Via email"
  end

  it "enqueues one digest keyed on the series with the stamp as window start" do
    expect do
      service.call(status: "accepted", stamp:, only_awaiting: false)
    end.to have_enqueued_job(Meetings::SendParticipationDigestJob)
      .with(series, since: stamp)
      .exactly(:once)
  end

  it "takes a row lock on the template meeting" do
    allow(Meeting).to receive(:lock).and_call_original

    service.call(status: "accepted", stamp:, only_awaiting: false)

    expect(Meeting).to have_received(:lock)
  end

  it "rolls back every row and enqueues nothing when a mid-sweep write fails" do
    calls = 0
    allow_any_instance_of(MeetingParticipant).to receive(:update!).and_wrap_original do |m, *args| # rubocop:disable RSpec/AnyInstance
      calls += 1
      raise "boom" if calls == 2

      m.call(*args)
    end

    expect do
      expect do
        service.call(status: "declined", stamp:, only_awaiting: false)
      end.to raise_error("boom")
    end.not_to have_enqueued_job(Meetings::SendParticipationDigestJob)

    expect(template_participant.reload).to be_participation_needs_action
    expect(future_pending.reload).to be_participation_needs_action
  end
end
