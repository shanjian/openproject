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

RSpec.describe RecurringMeetings::SendUpdatedNotificationJob do
  shared_let(:project) { create(:project, enabled_module_names: %w[meetings]) }
  shared_let(:actor) { create(:user, member_with_permissions: { project => %i[view_meetings edit_meetings] }) }
  shared_let(:recipient) { create(:user, member_with_permissions: { project => %i[view_meetings] }) }

  let(:series) do
    create(:recurring_meeting,
           project:,
           frequency: "daily",
           interval: 1,
           end_after: "specific_date",
           end_date: 1.month.from_now)
  end

  # Snapshot representing the schedule before an edit switched it to daily
  let(:old_schedule_attributes) do
    series.attributes.slice(*described_class::SCHEDULE_ATTRS).merge("frequency" => "weekly")
  end
  let(:old_location) { "Old location" }

  before do
    series.template.participants.delete_all
    series.template.participants << MeetingParticipant.new(user: recipient, invited: true)
    ActionMailer::Base.deliveries.clear
  end

  def perform!(actor_id: actor.id)
    described_class.perform_now(series,
                                actor_id:,
                                old_schedule_attributes:,
                                old_location:)
    perform_enqueued_jobs
  end

  it "sends the series update mail rendering the old schedule from the snapshot" do
    perform!

    expect(ActionMailer::Base.deliveries.size).to eq 1
    mail = ActionMailer::Base.deliveries.first
    expect(mail.to).to contain_exactly(recipient.mail)
    expect(mail.html_part.body).to include("Every week")
    expect(mail.html_part.body).to include("Old location")
  end

  it "skips delivery when the series has ended in the meantime" do
    series.update_columns(end_after: RecurringMeeting.end_afters["specific_date"],
                          end_date: 2.days.ago)

    perform!

    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it "skips delivery when the series is muted" do
    series.template.update_column(:notify, false)

    perform!

    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it "skips recipients who globally opted out of meeting updates" do
    recipient.notification_settings.where(project: nil).update_all(meeting_updated: false)

    perform!

    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it "still delivers with the DeletedUser fallback when the actor account is gone" do
    perform!(actor_id: -1)

    expect(ActionMailer::Base.deliveries.size).to eq 1
  end
end
