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
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

require "spec_helper"

# An "origin cause" records where a journal came from (an MCP assistant) rather than what changed.
# Two rules keep it trustworthy, see docs/development/mcp-write-tools-proposal.md:
#
# * it only aggregates with an identical cause, so it can neither be erased by, nor relabel, a
#   person's journal, and
# * it never forces a journal by itself, so a no-op write leaves no empty journal and no notification.
#
# The "existing causes" examples pin today's behaviour for every other cause, which must not move.
RSpec.describe Journals::CreateService, "with an origin cause", with_settings: { journal_aggregation_time_minutes: 5 } do
  let(:user) { create(:admin) }
  let(:other_user) { create(:user) }
  let(:type) { create(:type) }
  let(:project) { create(:project, types: [type]) }
  let!(:work_package) { create(:work_package, project:, type:, author: user) }

  let(:update_cause) { CauseOfChange::Base.new("mcp", { "tool" => "update_work_package" }) }
  let(:comment_cause) { CauseOfChange::Base.new("mcp", { "tool" => "create_work_package_comment" }) }

  def update!(**attrs)
    result = User.execute_as(user) do
      WorkPackages::UpdateService.new(user:, model: WorkPackage.find(work_package.id)).call(**attrs)
    end
    expect(result).to be_success, -> { result.errors.full_messages.to_s }
  end

  def comment!(text, cause:)
    wp = WorkPackage.find(work_package.id)
    User.execute_as(user) { AddWorkPackageNoteService.new(user:, work_package: wp).call(text, cause:) }
  end

  def journals
    Journal.where(journable_type: "WorkPackage", journable_id: work_package.id).order(:version)
  end

  before do
    create(:default_status)
    create(:default_priority)
    # The creation journal belongs to someone else, so nothing below aggregates into it.
    journals.update_all(user_id: other_user.id)
  end

  describe "aggregation" do
    it "does not merge an assistant's edit into a person's journal" do
      update!(subject: "Person edit")
      update!(description: "Assistant edit", journal_cause: update_cause)

      expect(journals.map(&:cause)).to eq([{}, {}, update_cause.to_hash])
    end

    it "keeps the marker when a person edits right after the assistant" do
      update!(description: "Assistant edit", journal_cause: update_cause)
      update!(subject: "Person edit")

      expect(journals.map(&:cause)).to eq([{}, update_cause.to_hash, {}])
    end

    it "keeps the marker on a comment when a person edits right after it" do
      comment!("Assistant comment", cause: comment_cause)
      update!(subject: "Person edit")

      expect(journals.map(&:cause)).to eq([{}, comment_cause.to_hash, {}])
      expect(journals.second.notes).to eq("Assistant comment")
    end

    it "does not merge a comment into a person's earlier edit" do
      update!(subject: "Person edit")
      comment!("Assistant comment", cause: comment_cause)

      expect(journals.map(&:cause)).to eq([{}, {}, comment_cause.to_hash])
    end

    it "still merges two identical assistant updates" do
      update!(description: "First", journal_cause: update_cause)
      update!(description: "Second", journal_cause: update_cause)

      expect(journals.map(&:cause)).to eq([{}, update_cause.to_hash])
    end

    it "does not merge assistant writes made by different tools" do
      update!(description: "Edit", journal_cause: update_cause)
      comment!("Comment", cause: comment_cause)

      expect(journals.map(&:cause)).to eq([{}, update_cause.to_hash, comment_cause.to_hash])
    end
  end

  describe "forced journals" do
    it "writes no journal for a no-op update" do
      update!(subject: WorkPackage.find(work_package.id).subject, journal_cause: update_cause)

      expect(journals.count).to eq(1)
    end

    it "writes one marked journal for an update that changes something" do
      update!(subject: "Changed", journal_cause: update_cause)

      expect(journals.map(&:cause)).to eq([{}, update_cause.to_hash])
    end

    it "does not relabel a person's journal when the assistant's update changes nothing" do
      update!(subject: "Person edit")
      update!(subject: "Person edit", journal_cause: update_cause)

      expect(journals.map(&:cause)).to eq([{}, {}])
    end

    it "still writes a journal for a comment, which is a note and not a bare cause" do
      comment!("Assistant comment", cause: comment_cause)

      expect(journals.map(&:cause)).to eq([{}, comment_cause.to_hash])
    end

    it "does not announce a journal that was not written" do
      events = []
      subscription = OpenProject::Notifications.subscribe(OpenProject::Events::JOURNAL_CREATED) { |payload| events << payload }

      begin
        update!(subject: WorkPackage.find(work_package.id).subject, journal_cause: update_cause)
      ensure
        OpenProject::Notifications.unsubscribe(OpenProject::Events::JOURNAL_CREATED, subscription)
      end

      expect(events).to be_empty
    end

    context "with an assignee who could be notified" do
      let(:recipient) { create(:user, member_with_permissions: { project => %i[view_work_packages work_package_assigned] }) }

      before do
        # Assigned through the service, so the assignment is journalled and is not a pending change
        # that the next journal would pick up.
        update!(assigned_to: recipient)
        Notification.delete_all
      end

      it "sends no notification for a no-op update" do
        perform_enqueued_jobs { update!(subject: WorkPackage.find(work_package.id).subject, journal_cause: update_cause) }

        expect(Notification.where(recipient_id: recipient.id)).to be_empty
      end

      it "still sends the notification for a real change" do
        perform_enqueued_jobs { update!(subject: "Changed", journal_cause: update_cause) }

        expect(Notification.where(recipient_id: recipient.id).count).to eq(1)
      end
    end
  end

  describe "existing causes are unchanged" do
    let(:system_cause) { Journal::CausedBySystemUpdate.new(feature: "progress_calculation_adjusted") }

    it "still merges a person's edit and a following edit that carries another cause" do
      update!(subject: "Person edit")
      update!(description: "System edit", journal_cause: system_cause)

      expect(journals.map(&:cause)).to eq([{}, system_cause.to_hash])
    end

    it "still lets a person's edit overwrite the cause it follows" do
      update!(description: "System edit", journal_cause: system_cause)
      update!(subject: "Person edit")

      expect(journals.map(&:cause)).to eq([{}, {}])
    end

    it "still writes a journal for a no-op update carrying that cause" do
      update!(subject: WorkPackage.find(work_package.id).subject, journal_cause: system_cause)

      expect(journals.map(&:cause)).to eq([{}, system_cause.to_hash])
    end
  end

  describe "services that save the work package more than once", with_ee: %i[work_package_subject_generation] do
    let(:create_cause) { CauseOfChange::Base.new("mcp", { "tool" => "create_work_package" }) }

    context "when a pattern generates the subject after the first save" do
      let(:patterned_type) do
        create(:type, patterns: { subject: { blueprint: "{{type}} {{id}} by {{author}}", enabled: true } })
      end
      let(:patterned_project) { create(:project, types: [patterned_type]) }

      it "leaves one marked journal when creating" do
        result = User.execute_as(user) do
          WorkPackages::CreateService.new(user:)
                                     .call(subject: "temporary", project: patterned_project, type: patterned_type,
                                           journal_cause: create_cause)
        end
        expect(result).to be_success, -> { result.errors.full_messages.to_s }

        created = result.result.reload
        expect(created.subject).to include(created.id.to_s) # the pattern ran, i.e. there was a second save
        expect(Journal.where(journable: created).map(&:cause)).to eq([create_cause.to_hash])
      end

      it "leaves one marked journal when updating regenerates the subject" do
        assignee_type = create(:type, patterns: { subject: { blueprint: "{{type}} for {{assignee}}", enabled: true } })
        assignee_project = create(:project, types: [assignee_type])
        assignee = create(:user, member_with_permissions: { assignee_project => %i[view_work_packages work_package_assigned] })
        patterned = create(:work_package, project: assignee_project, type: assignee_type, author: user)
        Journal.where(journable: patterned).update_all(user_id: other_user.id)

        result = User.execute_as(user) do
          WorkPackages::UpdateService.new(user:, model: WorkPackage.find(patterned.id))
                                     .call(assigned_to: assignee, journal_cause: update_cause)
        end
        expect(result).to be_success, -> { result.errors.full_messages.to_s }

        expect(patterned.reload.subject).to include(assignee.name) # the pattern ran
        expect(Journal.where(journable: patterned).order(:version).map(&:cause)).to eq([{}, update_cause.to_hash])
      end

      it "does not leave the cause behind on the returned work package" do
        result = User.execute_as(user) do
          WorkPackages::CreateService.new(user:)
                                     .call(subject: "temporary", project: patterned_project, type: patterned_type,
                                           journal_cause: create_cause)
        end

        expect(result.result.journal_cause).to be_nil
      end
    end
  end

  describe "releasing the cause when a call does not complete" do
    # Finish before start is refused by the contract whoever asks, unlike a blank subject.
    let(:invalid_dates) { { start_date: Date.new(2026, 11, 10), due_date: Date.new(2026, 11, 1), schedule_manually: true } }
    let(:create_cause) { CauseOfChange::Base.new("mcp", { "tool" => "create_work_package" }) }
    let(:instance_to_save) { WorkPackage.find(work_package.id) }

    it "does not leave it on the work package when creating raises" do
      service = WorkPackages::CreateService.new(user:)
      allow(service).to receive(:reschedule_related).and_raise("boom")
      new_work_package = WorkPackage.new

      expect do
        service.call(work_package: new_work_package, subject: "New", project:, type:, journal_cause: create_cause)
      end.to raise_error("boom")

      expect(new_work_package.journal_cause).to be_nil
    end

    it "does not leave it on the work package when creating fails validation" do
      new_work_package = WorkPackage.new

      result = WorkPackages::CreateService.new(user:)
                                          .call(work_package: new_work_package, subject: "New", project:, type:,
                                                journal_cause: create_cause, **invalid_dates)

      expect(result).to be_failure
      expect(new_work_package.journal_cause).to be_nil
    end

    it "does not leave it on the work package when updating raises" do
      service = WorkPackages::UpdateService.new(user:, model: instance_to_save)
      allow(service).to receive(:update_related_work_packages).and_raise("boom")

      expect { service.call(subject: "Changed", journal_cause: update_cause) }.to raise_error("boom")

      expect(instance_to_save.journal_cause).to be_nil
    end

    it "does not leave it on the work package when updating fails validation" do
      result = WorkPackages::UpdateService.new(user:, model: instance_to_save)
                                          .call(journal_cause: update_cause, **invalid_dates)

      expect(result).to be_failure
      expect(instance_to_save.journal_cause).to be_nil
    end

    it "does not leave it on the work package when commenting is refused" do
      outsider = create(:user)

      result = AddWorkPackageNoteService.new(user: outsider, work_package: instance_to_save)
                                        .call("Not allowed", cause: comment_cause)

      expect(result).to be_failure
      expect(instance_to_save.journal_cause).to be_nil
      expect(journals.count).to eq(1)
    end

    it "does not touch a cause that is not an origin cause when an update fails" do
      system_cause = Journal::CausedBySystemUpdate.new(feature: "progress_calculation_adjusted")

      result = WorkPackages::UpdateService.new(user:, model: instance_to_save)
                                          .call(journal_cause: system_cause, **invalid_dates)

      expect(result).to be_failure

      expect(instance_to_save.journal_cause).to eq(system_cause)
    end

    it "writes a comment without a cause exactly as before" do
      comment_without_cause = User.execute_as(user) do
        AddWorkPackageNoteService.new(user:, work_package: instance_to_save).call("Plain comment")
      end

      expect(comment_without_cause).to be_success
      expect(journals.map(&:cause)).to eq([{}, {}])
      expect(journals.last.notes).to eq("Plain comment")
    end
  end
end
