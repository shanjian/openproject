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

require_relative "../spec_helper"

RSpec.describe Meeting do
  shared_let (:user1) { create(:user) }
  shared_let (:user2) { create(:user) }

  let(:project) { create(:project, members: project_members) }
  let(:meeting) { create(:meeting, :author_participates, project:, author: user1) }
  let(:project_members) { {} }

  let(:role) { create(:project_role, permissions: [:view_meetings]) }

  it { is_expected.to belong_to :project }
  it { is_expected.to belong_to :author }
  it { is_expected.to validate_presence_of :title }

  describe "new instance" do
    let(:meeting) { build(:meeting, project:, title: "dingens") }

    describe "to_s" do
      it { expect(meeting.to_s).to eq("dingens") }
    end

    describe "start_date" do
      it { expect(meeting.start_date).to eq(Date.tomorrow.iso8601) }
    end

    describe "start_month" do
      it { expect(meeting.start_month).to eq(Date.tomorrow.month) }
    end

    describe "start_year" do
      it { expect(meeting.start_year).to eq(Date.tomorrow.year) }
    end

    describe "end_time" do
      it { expect(meeting.end_time).to eq(Date.tomorrow + 11.hours) }
    end

    describe "date validations" do
      it "marks invalid start dates" do
        meeting.start_date = "-"
        expect(meeting.start_date).to eq("-")
        expect(meeting.start_time).to be_nil
        expect(meeting).not_to be_valid
        expect(meeting.errors.count).to eq(1)
      end

      it "marks invalid start hours" do
        meeting.start_time_hour = "-"
        expect(meeting.start_time_hour).to eq("-")
        expect(meeting.start_time).to be_nil
        expect(meeting).not_to be_valid
        expect(meeting.errors.count).to eq(1)
      end

      it "is not invalid when setting date_time explicitly" do
        meeting.start_time = DateTime.now
        expect(meeting).to be_valid
      end

      it "raises an error trying to set invalid time" do
        expect { meeting.start_time = "-" }.to raise_error(Date::Error)
      end

      it "accepts changes after invalid dates" do
        meeting.start_date = "-"
        expect(meeting.start_time).to be_nil
        expect(meeting).not_to be_valid
        expect(meeting.errors[:start_date]).to contain_exactly "is not a valid date. Required format: YYYY-MM-DD."

        meeting.start_date = Time.zone.today.iso8601
        expect(meeting).to be_valid

        meeting.save!
        expect(meeting.start_time).to eq(Time.zone.today + 10.hours)
      end
    end
  end

  describe "#editable?" do
    let(:user) { create(:user, member_with_permissions: { project => %i[view_meetings edit_meetings] }) }

    it "is false for cancelled meetings" do
      meeting = create(:meeting, project:, state: "cancelled")

      expect(meeting.editable?(user)).to be false
    end
  end

  describe "#cancellable?" do
    it "is true for open and in_progress one-off meetings" do
      expect(create(:meeting, project:, state: "open")).to be_cancellable
      expect(create(:meeting, project:, state: "in_progress")).to be_cancellable
    end

    it "is false for closed, draft, cancelled, template, and recurring meetings" do
      series = create(:recurring_meeting, project:)

      expect(create(:meeting, project:, state: "closed")).not_to be_cancellable
      expect(create(:meeting, project:, state: "draft")).not_to be_cancellable
      expect(create(:meeting, project:, state: "cancelled")).not_to be_cancellable
      expect(create(:onetime_template, project:)).not_to be_cancellable
      expect(create(:meeting, project:, recurring_meeting: series)).not_to be_cancellable
    end
  end

  describe "#send_emails?" do
    it "is true for a persisted, notifying, open meeting" do
      meeting = create(:meeting, project:, notify: true)

      expect(meeting.send_emails?).to be true
    end

    it "is false for closed meetings" do
      meeting = create(:meeting, project:, notify: true, state: "closed")

      expect(meeting.send_emails?).to be false
    end
  end

  describe "close notification" do
    let(:participant_user) { create(:user, member_with_permissions: { project => %i[view_meetings] }) }
    let(:notify) { true }
    let(:meeting) { create(:meeting, project:, notify:, state: "in_progress") }

    before do
      create(:meeting_participant, meeting:, user: participant_user, invited: true)
      ActionMailer::Base.deliveries.clear
    end

    it "mails the participants when the meeting is closed" do
      meeting.closed!
      perform_enqueued_jobs

      expect(ActionMailer::Base.deliveries.flat_map(&:to)).to contain_exactly(participant_user.mail)
      expect(ActionMailer::Base.deliveries.first.subject).to include("Closed")
    end

    it "sends nothing when reopening" do
      meeting.update_column(:state, described_class.states[:closed])

      meeting.open!
      perform_enqueued_jobs

      expect(ActionMailer::Base.deliveries).to be_empty
    end

    context "when the meeting is muted" do
      let(:notify) { false }

      it "sends nothing" do
        meeting.closed!
        perform_enqueued_jobs

        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it "skips recipients who globally opted out of meeting updates" do
      participant_user.notification_settings.where(project: nil).update_all(meeting_updated: false)

      meeting.closed!
      perform_enqueued_jobs

      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end

  describe "update mail batching" do
    it "enqueues the delayed job carrying the pre-edit baseline" do
      meeting = create(:meeting, project:, notify: true, title: "Old title")

      # rubocop:disable Style/MultilineBlockChain
      expect do
        meeting.update(title: "New title")
      end.to have_enqueued_job(Meetings::SendUpdatedNotificationJob).with do |_meeting, actor_id:, old_values:|
        expect(actor_id).to eq User.current.id
        expect(old_values[:old_title]).to eq "Old title"
      end
      # rubocop:enable Style/MultilineBlockChain
    end
  end

  describe "participants and author as watchers" do
    let(:project_members) { { user1 => role, user2 => role } }

    before do
      meeting.participants.build(user: user2)
      meeting.save!
    end

    it { expect(meeting.watchers.collect(&:user)).to contain_exactly(user1, user2) }
  end

  describe "Timezones" do
    shared_examples "uses that zone" do |zone|
      it do
        meeting.start_date = "2016-07-01"
        expect(meeting.start_time.zone).to eq(zone)
      end
    end

    context "default zone" do
      it_behaves_like "uses that zone", "UTC"
    end

    context "other timezone set" do
      current_user { build_stubbed(:user, preferences: { time_zone: "EST" }) }

      it_behaves_like "uses that zone", "EST"
    end
  end

  describe "acts_as_watchable" do
    it "is watchable" do
      expect(described_class).to include(OpenProject::Acts::Watchable::InstanceMethods)
    end

    it "uses the :view_meetings permission" do
      expect(described_class.acts_as_watchable_permission).to eq(:view_meetings)
    end
  end

  describe "duration" do
    it "accepts a float" do
      meeting.duration = 1.5
      expect(meeting).to be_valid
      expect(meeting.duration).to eq(1.5)
      expect(meeting.formatted_duration).to eq("1.5h")
    end

    it "accepts a string to be parsed by chronic" do
      meeting.duration = "30m"
      expect(meeting).to be_valid
      expect(meeting.duration).to eq(0.5)
      expect(meeting.formatted_duration).to eq("0.5h")
    end

    it "doesn't raise on nil" do
      meeting.duration = nil
      expect(meeting).not_to be_valid
      expect(meeting.errors[:duration]).to include("is not a number.")
      expect(meeting.formatted_duration).to be_nil
    end
  end

  describe "uid" do
    it "assigns a uid on create" do
      meeting = described_class.new(project:, author: user1)
      expect(meeting.uid).to be_present
      expect(meeting.uid).to include "@#{Setting.host_name}"
    end
  end

  describe "#destroy" do
    context "with an attachment" do
      let!(:meeting) { create(:meeting, project: project) }
      let!(:attachment) { create(:attachment, container: meeting) }

      it "does not raise an exception (Regression #61632)" do
        expect { meeting.destroy! }.not_to raise_error
        expect { meeting.reload }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe ".templates_visible_in_project" do
    shared_let(:ancestor_project) { create(:project) }
    shared_let(:current_project) { create(:project, parent: ancestor_project) }
    shared_let(:descendant_project) { create(:project, parent: current_project) }
    shared_let(:unrelated_project) { create(:project) }

    shared_let(:user) { create(:user, member_with_permissions: { current_project => [:view_meetings] }) }

    subject { described_class.templates_visible_in_project(current_project, user) }

    context "with templates in the same project" do
      shared_let(:template_none) { create(:onetime_template, project: current_project, sharing: :none) }
      shared_let(:template_descendants) { create(:onetime_template, project: current_project, sharing: :descendants) }
      shared_let(:template_system) { create(:onetime_template, project: current_project, sharing: :system) }

      it { expect(subject).to include(template_none) }
      it { expect(subject).to include(template_descendants) }
      it { expect(subject).to include(template_system) }
    end

    context "with templates in an unrelated project" do
      shared_let(:template_none) { create(:onetime_template, project: unrelated_project, sharing: :none) }
      shared_let(:template_descendants) { create(:onetime_template, project: unrelated_project, sharing: :descendants) }
      shared_let(:template_system) { create(:onetime_template, project: unrelated_project, sharing: :system) }

      it { expect(subject).not_to include(template_none) }
      it { expect(subject).not_to include(template_descendants) }
      it { expect(subject).to include(template_system) }
    end

    context "with templates in a descendant project" do
      shared_let(:template_none) { create(:onetime_template, project: descendant_project, sharing: :none) }
      shared_let(:template_descendants) { create(:onetime_template, project: descendant_project, sharing: :descendants) }
      shared_let(:template_system) { create(:onetime_template, project: descendant_project, sharing: :system) }

      it { expect(subject).not_to include(template_none) }
      it { expect(subject).not_to include(template_descendants) }
      it { expect(subject).to include(template_system) }
    end

    context "with templates in an ancestor project" do
      shared_let(:template_none) { create(:onetime_template, project: ancestor_project, sharing: :none) }
      shared_let(:template_descendants) { create(:onetime_template, project: ancestor_project, sharing: :descendants) }
      shared_let(:template_system) { create(:onetime_template, project: ancestor_project, sharing: :system) }

      it { expect(subject).not_to include(template_none) }
      it { expect(subject).to include(template_descendants) }
      it { expect(subject).to include(template_system) }
    end
  end

  describe "sharing" do
    context "for a regular meeting" do
      let(:meeting) { build(:meeting, project:, sharing: :none) }

      it "is invalid" do
        expect(meeting).not_to be_valid
        expect(meeting.errors[:sharing]).to be_present
      end
    end

    context "for a series template" do
      let(:recurring) { create(:recurring_meeting, project:) }
      let(:meeting) { build(:meeting_template, sharing: :none, recurring_meeting: recurring) }

      it "is invalid" do
        expect(meeting).not_to be_valid
        expect(meeting.errors[:sharing]).to be_present
      end
    end

    context "for an onetime template" do
      let(:meeting) { build(:onetime_template, project:, sharing: :none) }

      it "is valid" do
        expect(meeting).to be_valid
      end
    end
  end
end
