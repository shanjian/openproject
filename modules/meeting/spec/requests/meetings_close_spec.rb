# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Meeting close requests", :skip_csrf, type: :rails_request do
  shared_let(:project) { create(:project, enabled_module_names: %i[meetings]) }
  shared_let(:user) { create(:user, member_with_permissions: { project => %i[view_meetings edit_meetings] }) }

  let(:recurring_meeting) { create(:recurring_meeting, project:, author: user) }
  let!(:scheduled_meeting) do
    create(:scheduled_meeting,
           :persisted,
           recurring_meeting:,
           start_time: 1.hour.from_now)
  end
  let(:meeting) { scheduled_meeting.meeting }

  before do
    login_as(user)
  end

  describe "GET /close_dialog" do
    it "offers only this occurrence before the scheduled start" do
      get close_dialog_project_meeting_path(project, meeting), as: :turbo_stream

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t("meeting.close.scope_this_and_future"))
    end

    context "when the scheduled occurrence has started" do
      before do
        scheduled_meeting.update_column(:start_time, 1.hour.ago)
      end

      it "offers the series-ending scope" do
        get close_dialog_project_meeting_path(project, meeting), as: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t("meeting.close.scope_this_and_future"))
      end
    end
  end

  describe "POST /close" do
    it "closes an ineligible occurrence with only_this" do
      original_end_date = recurring_meeting.end_date

      post close_project_meeting_path(project, meeting),
           params: { scope: "only_this" },
           as: :turbo_stream

      expect(response).to have_http_status(:ok)
      expect(meeting.reload).to be_closed
      expect(recurring_meeting.reload.end_date).to eq(original_end_date)
    end

    it "rejects a forged this_and_future request before writing" do
      post close_project_meeting_path(project, meeting),
           params: { scope: "this_and_future" },
           as: :turbo_stream

      expect(response).to have_http_status(:unprocessable_entity)
      expect(meeting.reload).not_to be_closed
      expect(recurring_meeting.reload.end_date).not_to eq(Time.zone.yesterday)
    end

    context "when the occurrence has started" do
      let(:end_service) { instance_double(RecurringMeetings::EndService) }

      before do
        scheduled_meeting.update_column(:start_time, 1.hour.ago)
        allow(RecurringMeetings::EndService)
          .to receive(:new)
          .with(recurring_meeting, current_user: user)
          .and_return(end_service)
        allow(end_service)
          .to receive(:call)
          .with(end_date: scheduled_meeting.start_time.in_time_zone(recurring_meeting.time_zone).to_date)
          .and_return(ServiceResult.success)
      end

      it "closes the occurrence and ends the series from the occurrence date" do
        post close_project_meeting_path(project, meeting),
             params: { scope: "this_and_future" },
             as: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(meeting.reload).to be_closed
        expect(end_service).to have_received(:call)
      end

      context "when ending the series fails" do
        before do
          allow(end_service)
            .to receive(:call)
            .with(end_date: scheduled_meeting.start_time.in_time_zone(recurring_meeting.time_zone).to_date)
            .and_return(ServiceResult.failure(errors: { base: ["series end failed"] }))
        end

        it "keeps the occurrence closed and reports a partial failure" do
          post close_project_meeting_path(project, meeting),
               params: { scope: "this_and_future" },
               as: :turbo_stream

          expect(response).to have_http_status(:unprocessable_entity)
          expect(meeting.reload).to be_closed
          expect(response.body).to include(I18n.t("meeting.close.series_end_failed"))
          expect(response.body).to include("closeDialog")
        end
      end

      it "defaults unrecognized scopes to only_this" do
        post close_project_meeting_path(project, meeting),
             params: { scope: "unexpected" },
             as: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(meeting.reload).to be_closed
        expect(end_service).not_to have_received(:call)
      end
    end

    context "when closing the occurrence fails" do
      let(:end_service) { instance_double(RecurringMeetings::EndService) }

      before do
        scheduled_meeting.update_column(:start_time, 1.hour.ago)
        meeting.update_column(:state, Meeting.states[:cancelled])
        allow(RecurringMeetings::EndService).to receive(:new).and_return(end_service)
        allow(end_service).to receive(:call)
      end

      it "does not attempt to end the series" do
        post close_project_meeting_path(project, meeting),
             params: { scope: "this_and_future" },
             as: :turbo_stream

        expect(response).to have_http_status(:unprocessable_entity)
        expect(meeting.reload).to be_cancelled
        expect(response.body).to include("closeDialog")
        expect(RecurringMeetings::EndService).not_to have_received(:new)
      end
    end

    context "when the occurrence close races with another update" do
      before do
        scheduled_meeting.update_column(:start_time, 1.hour.ago)
        allow_any_instance_of(Meeting) # rubocop:disable RSpec/AnyInstance
          .to receive(:update)
          .with(state: :closed)
          .and_raise(ActiveRecord::StaleObjectError)
      end

      it "returns a turbo-stream error instead of raising" do
        post close_project_meeting_path(project, meeting),
             params: { scope: "only_this" },
             as: :turbo_stream

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include(I18n.t("meeting.close.stale"))
      end
    end
  end
end
