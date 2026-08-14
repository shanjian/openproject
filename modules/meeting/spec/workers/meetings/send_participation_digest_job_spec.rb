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

RSpec.describe Meetings::SendParticipationDigestJob do
  shared_let(:project) { create(:project, enabled_module_names: %w[meetings]) }
  shared_let(:author) { create(:user, member_with_permissions: { project => %i[view_meetings edit_meetings] }) }
  shared_let(:responder) { create(:user, member_with_permissions: { project => %i[view_meetings] }) }

  let(:since) { 10.minutes.ago }
  let(:meeting) { create(:meeting, project:, author:, state: "open") }

  def respond!(meeting, user, status, at: Time.current, invited: true, comment: nil)
    create(:meeting_participant,
           meeting:, user:, invited:,
           participation_status: status,
           participation_responded_at: at,
           comment:)
  end

  before { ActionMailer::Base.deliveries.clear }

  describe "one-off meetings" do
    it "mails the author one digest listing in-window responses" do
      respond!(meeting, responder, "accepted", comment: "See you there")

      described_class.perform_now(meeting, since:)

      expect(ActionMailer::Base.deliveries.size).to eq 1
      mail = ActionMailer::Base.deliveries.first
      expect(mail.to).to contain_exactly(author.mail)
      expect(mail.html_part.body).to include(responder.name)
      expect(mail.html_part.body).to include("Accepted")
      expect(mail.html_part.body).to include("See you there")
    end

    it "ignores responses stamped before the window" do
      respond!(meeting, responder, "accepted", at: 1.hour.ago)

      described_class.perform_now(meeting, since:)

      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it "ignores non-invited rows even when stamped in-window" do
      respond!(meeting, responder, "accepted", invited: false)

      described_class.perform_now(meeting, since:)

      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it "excludes the author's own response and skips the mail when nothing remains" do
      respond!(meeting, author, "accepted")

      described_class.perform_now(meeting, since:)

      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it "honors the author's global meeting_responses opt-out" do
      author.notification_settings.where(project: nil).update_all(meeting_responses: false)
      respond!(meeting, responder, "accepted")

      described_class.perform_now(meeting, since:)

      expect(ActionMailer::Base.deliveries).to be_empty
    ensure
      author.notification_settings.where(project: nil).update_all(meeting_responses: true)
    end

    it "is not suppressed by a project-scoped opt-out row" do
      create(:notification_setting, user: author, project:, meeting_responses: false)
      respond!(meeting, responder, "declined")

      described_class.perform_now(meeting, since:)

      expect(ActionMailer::Base.deliveries.size).to eq 1
    end

    it "no-ops on a cancelled meeting" do
      respond!(meeting, responder, "accepted")
      meeting.update_column(:state, Meeting.states[:cancelled])

      described_class.perform_now(meeting, since:)

      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it "still sends for a merely closed meeting" do
      respond!(meeting, responder, "accepted")
      meeting.update_column(:state, Meeting.states[:closed])

      described_class.perform_now(meeting, since:)

      expect(ActionMailer::Base.deliveries.size).to eq 1
    end

    it "skips when the author is locked" do
      respond!(meeting, responder, "accepted")
      author.locked!

      described_class.perform_now(meeting, since:)

      expect(ActionMailer::Base.deliveries).to be_empty
    ensure
      author.activate!
    end
  end

  describe "series", with_settings: { date_format: "%Y-%m-%d" } do
    let(:series) do
      create(:recurring_meeting,
             project:, author:,
             start_time: 1.week.ago.beginning_of_day + 10.hours,
             frequency: "daily", interval: 1,
             end_after: "specific_date", end_date: 1.month.from_now)
    end
    let(:occurrence) do
      create(:scheduled_meeting, :persisted,
             recurring_meeting: series,
             start_time: 2.days.from_now.beginning_of_day + 10.hours).meeting
    end

    it "labels template rows as all-future and occurrence rows with their date" do
      respond!(series.template, responder, "accepted")
      respond!(occurrence, responder, "tentative")

      described_class.perform_now(series, since:)

      expect(ActionMailer::Base.deliveries.size).to eq 1
      body = ActionMailer::Base.deliveries.first.html_part.body
      expect(body).to include("All future occurrences")
      expect(body).to include(occurrence.start_time.to_date.iso8601)
    end

    it "collapses a series-wide response into the all-future line only" do
      second_occurrence = create(:scheduled_meeting, :persisted,
                                 recurring_meeting: series,
                                 start_time: 3.days.from_now.beginning_of_day + 10.hours).meeting
      # One "this and all future" sweep stamps template + occurrences alike
      respond!(series.template, responder, "accepted")
      respond!(occurrence, responder, "accepted")
      respond!(second_occurrence, responder, "accepted")

      described_class.perform_now(series, since:)

      body = ActionMailer::Base.deliveries.first.html_part.body
      expect(body).to include("All future occurrences")
      expect(body).not_to include(occurrence.start_time.to_date.iso8601)
      expect(body).not_to include(second_occurrence.start_time.to_date.iso8601)
    end

    it "keeps occurrence rows whose status differs from the user's template row" do
      respond!(series.template, responder, "accepted")
      respond!(occurrence, responder, "declined")

      described_class.perform_now(series, since:)

      body = ActionMailer::Base.deliveries.first.html_part.body
      expect(body).to include("All future occurrences")
      expect(body).to include(occurrence.start_time.to_date.iso8601)
    end

    it "still digests responses to a naturally ended series (e.g. its final occurrence)" do
      # EndService deletes pending jobs explicitly; a mere has_ended? guard would
      # swallow responses to the last occurrence of any series that just ran out
      respond!(series.template, responder, "accepted")
      series.update_columns(end_after: RecurringMeeting.end_afters["specific_date"],
                            end_date: 2.days.ago)

      described_class.perform_now(series, since:)

      expect(ActionMailer::Base.deliveries.size).to eq 1
    end

    it "renders occurrence dates in the author's timezone and locale" do
      author.pref.update!(time_zone: "Pacific/Auckland")
      # 20:00 UTC is already the NEXT day in Auckland (+12/+13)
      late_occurrence = create(:scheduled_meeting, :persisted,
                               recurring_meeting: series,
                               start_time: 2.days.from_now.beginning_of_day + 20.hours).meeting
      respond!(late_occurrence, responder, "accepted")

      described_class.perform_now(series, since:)

      body = ActionMailer::Base.deliveries.first.html_part.body
      auckland_date = late_occurrence.start_time.in_time_zone("Pacific/Auckland").to_date.iso8601
      expect(body).to include(auckland_date)
      expect(body).not_to include(late_occurrence.start_time.utc.to_date.iso8601)
    ensure
      author.pref.update!(time_zone: nil)
    end
  end
end
