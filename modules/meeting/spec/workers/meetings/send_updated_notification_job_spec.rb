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

RSpec.describe Meetings::SendUpdatedNotificationJob do
  shared_let(:project) { create(:project, enabled_module_names: %w[meetings]) }
  shared_let(:actor) { create(:user, member_with_permissions: { project => %i[view_meetings edit_meetings] }) }
  shared_let(:participant_user) { create(:user, member_with_permissions: { project => %i[view_meetings] }) }

  let(:meeting) { create(:meeting, project:, notify: true, title: "New title") }
  let(:old_values) do
    {
      "old_start" => meeting.start_time - 1.hour,
      "old_duration" => meeting.duration,
      "old_location" => meeting.location,
      "old_title" => "Old title"
    }
  end

  before do
    create(:meeting_participant, meeting:, user: participant_user, invited: true)
    ActionMailer::Base.deliveries.clear
  end

  def perform!(actor_id: actor.id)
    described_class.perform_now(meeting, actor_id:, old_values:)
    perform_enqueued_jobs
  end

  it "delivers one mail diffing the stored old values against the current state" do
    perform!

    expect(ActionMailer::Base.deliveries.size).to eq 1
    mail = ActionMailer::Base.deliveries.first
    expect(mail.to).to contain_exactly(participant_user.mail)
    expect(mail.html_part.body).to include("Old title")
    expect(mail.html_part.body).to include("New title")
    expect(mail.html_part.body).to include(actor.name)
  end

  it "no-ops when the meeting was closed in the meantime" do
    meeting.update_column(:state, Meeting.states[:closed])

    perform!

    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it "no-ops when the meeting was cancelled in the meantime" do
    meeting.update_column(:state, Meeting.states[:cancelled])

    perform!

    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it "still delivers with the DeletedUser fallback when the actor account is gone" do
    perform!(actor_id: -1)

    expect(ActionMailer::Base.deliveries.size).to eq 1
    expect(ActionMailer::Base.deliveries.first.html_part.body)
      .to include(DeletedUser.first.name)
  end
end
