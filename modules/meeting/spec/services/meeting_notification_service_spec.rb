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

RSpec.describe MeetingNotificationService do
  shared_let(:project) { create(:project, enabled_module_names: %w[meetings]) }
  shared_let(:actor) { create(:user, member_with_permissions: { project => %i[view_meetings] }) }
  shared_let(:opted_in_user) { create(:user, member_with_permissions: { project => %i[view_meetings] }) }
  shared_let(:opted_out_user) do
    create(:user, member_with_permissions: { project => %i[view_meetings] }).tap do |user|
      user.notification_settings.where(project: nil).update_all(meeting_updated: false)
    end
  end

  let(:notify) { true }
  let(:meeting) { create(:meeting, project:, notify:) }
  let(:changes) do
    {
      old_start: meeting.start_time - 1.hour, new_start: meeting.start_time,
      old_duration: meeting.duration, new_duration: meeting.duration,
      old_location: meeting.location, new_location: meeting.location,
      old_title: meeting.title, new_title: meeting.title
    }
  end

  let(:service) { described_class.new(meeting) }

  before do
    [opted_in_user, opted_out_user].each do |user|
      create(:meeting_participant, meeting:, user:, invited: true)
    end
    ActionMailer::Base.deliveries.clear
  end

  def delivered_recipients
    perform_enqueued_jobs
    ActionMailer::Base.deliveries.flat_map(&:to)
  end

  describe ":updated" do
    it "skips recipients who globally opted out of meeting updates" do
      result = service.call(:updated, actor:, changes: changes)

      expect(result).to be_success
      expect(delivered_recipients).to contain_exactly(opted_in_user.mail)
    end

    it "does not let a project-scoped opt-out suppress the mail" do
      opted_in_user.notification_settings.where(project: nil).update_all(meeting_updated: true)
      create(:notification_setting, user: opted_in_user, project:, meeting_updated: false)

      result = service.call(:updated, actor:, changes: changes)

      expect(result).to be_success
      expect(delivered_recipients).to include(opted_in_user.mail)
    end

    context "when the meeting is muted" do
      let(:notify) { false }

      it "sends nothing" do
        result = service.call(:updated, actor:, changes: changes)

        expect(result).to be_failure
        expect(delivered_recipients).to be_empty
      end
    end
  end

  describe ":cancelled" do
    context "when the meeting is muted" do
      let(:notify) { false }

      it "still notifies every participant, including opted-out ones" do
        result = service.call(:cancelled, actor:)

        expect(result).to be_success
        expect(delivered_recipients).to contain_exactly(opted_in_user.mail, opted_out_user.mail)
      end
    end
  end

  describe ":invited with force" do
    context "when the meeting is muted" do
      let(:notify) { false }

      it "sends to every participant" do
        result = service.call(:invited, force: true)

        expect(result).to be_success
        expect(delivered_recipients).to contain_exactly(opted_in_user.mail, opted_out_user.mail)
      end

      it "sends nothing without force" do
        result = service.call(:invited)

        expect(result).to be_failure
        expect(delivered_recipients).to be_empty
      end
    end
  end

  describe "explicit actor" do
    it "renders the mail with the given actor instead of User.current" do
      service.call(:updated, actor:, changes: changes)
      perform_enqueued_jobs

      mail = ActionMailer::Base.deliveries.last
      expect(mail.body.encoded).to include(actor.name)
    end
  end
end
