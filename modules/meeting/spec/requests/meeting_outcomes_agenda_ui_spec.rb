# frozen_string_literal: true

require "spec_helper"

# Exercises the Turbo UI controller for meeting outcomes. Together with the contract specs this
# guards that the agenda item of an outcome is only writable on create, without breaking
# creating or editing outcomes from the meeting agenda.
RSpec.describe "Meeting outcomes in the agenda UI",
               :skip_csrf,
               type: :rails_request do
  shared_let(:project) { create(:project, enabled_module_names: %w[meetings work_package_tracking]) }
  shared_let(:user) do
    create(:user,
           member_with_permissions: {
             project => %i[view_meetings manage_agendas manage_outcomes view_work_packages add_work_packages]
           })
  end

  shared_let(:meeting) { create(:meeting, project:, author: user, state: :in_progress) }
  shared_let(:agenda_item) { create(:meeting_agenda_item, meeting:) }
  shared_let(:other_agenda_item) { create(:meeting_agenda_item, meeting:) }

  let!(:outcome) { create(:meeting_outcome, meeting_agenda_item: agenda_item, notes: "Original notes") }
  let(:turbo_headers) { { "Accept" => "text/vnd.turbo-stream.html" } }

  before do
    login_as user
  end

  describe "update" do
    let(:path) { project_meeting_agenda_item_outcome_path(project, meeting, agenda_item, outcome) }

    it "updates the notes and keeps the agenda item" do
      patch path, params: { meeting_outcome: { notes: "Changed notes" } }, headers: turbo_headers

      expect(response).to have_http_status(:ok)
      expect(outcome.reload.notes).to eq("Changed notes")
      expect(outcome.meeting_agenda_item).to eq(agenda_item)
    end

    it "does not move the outcome to another agenda item" do
      patch path,
            params: { meeting_outcome: { notes: "Changed notes", meeting_agenda_item_id: other_agenda_item.id } },
            headers: turbo_headers

      expect(outcome.reload.meeting_agenda_item).to eq(agenda_item)
    end
  end

  describe "create" do
    let(:path) { project_meeting_agenda_item_outcomes_path(project, meeting, agenda_item) }

    it "creates an outcome for the agenda item of the route" do
      expect do
        post path, params: { meeting_outcome: { notes: "New outcome" } }, headers: turbo_headers
      end.to change(MeetingOutcome, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(MeetingOutcome.find_by(notes: "New outcome").meeting_agenda_item).to eq(agenda_item)
    end

    it "creates an outcome linking an existing work package" do
      work_package = create(:work_package, project:)

      expect do
        post path,
             params: { meeting_outcome: { work_package_id: work_package.id } },
             headers: turbo_headers
      end.to change(MeetingOutcome, :count).by(1)

      expect(MeetingOutcome.order(:id).last).to have_attributes(meeting_agenda_item: agenda_item, work_package:)
    end
  end

  describe "create_work_package" do
    let(:path) { create_work_package_project_meeting_agenda_item_outcomes_path(project, meeting, agenda_item) }
    let!(:type) { create(:type_task) }

    before do
      create(:default_status)
      create(:default_priority)
      project.types << type
    end

    it "creates a work package and an outcome for the agenda item of the route" do
      expect do
        post path,
             params: { work_package: { subject: "Created from outcome", type_id: type.id } },
             headers: turbo_headers
      end.to change(WorkPackage, :count).by(1).and change(MeetingOutcome, :count).by(1)

      work_package = WorkPackage.find_by!(subject: "Created from outcome")
      expect(MeetingOutcome.order(:id).last)
        .to have_attributes(meeting_agenda_item: agenda_item, work_package:, kind: "work_package")
    end
  end
end
