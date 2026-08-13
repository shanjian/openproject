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

RSpec.describe Meetings::DeleteService do
  shared_let(:project) { create(:project, enabled_module_names: %i[meetings]) }
  shared_let(:current_user) do
    create(:user, member_with_permissions: { project => %i[view_meetings delete_meetings] })
  end
  shared_let(:participant_user) { create(:user, member_with_permissions: { project => %i[view_meetings] }) }

  let(:state) { "open" }
  let(:meeting) { create(:meeting, project:, notify: false, state:) }

  subject { described_class.new(user: current_user, model: meeting).call }

  before do
    create(:meeting_participant, meeting:, user: participant_user, invited: true)
    ActionMailer::Base.deliveries.clear
  end

  it "sends the cancellation mail even when the meeting is muted" do
    expect(subject).to be_success
    perform_enqueued_jobs

    expect(ActionMailer::Base.deliveries.flat_map(&:to)).to include(participant_user.mail)
  end

  it "clears a pending batched update job" do
    allow(Meetings::SendUpdatedNotificationJob).to receive(:delete_jobs)

    expect(subject).to be_success

    expect(Meetings::SendUpdatedNotificationJob).to have_received(:delete_jobs).with(meeting)
  end

  context "with a draft meeting" do
    let(:state) { "draft" }

    it "sends no cancellation mail (nobody was ever invited)" do
      expect(subject).to be_success
      perform_enqueued_jobs

      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end
end
