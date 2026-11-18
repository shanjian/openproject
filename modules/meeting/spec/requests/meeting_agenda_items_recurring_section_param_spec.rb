# frozen_string_literal: true

require "spec_helper"

# The agenda item form actions look the section up through the meeting of the route.
# For an occurrence of a recurring meeting the backlog is shared with the series template
# (Meeting#backlog), which must keep working next to the scoping of all other sections.
RSpec.describe "Meeting agenda item form section parameter in recurring meetings",
               :skip_csrf,
               type: :rails_request do
  shared_let(:project) { create(:project, enabled_module_names: %w[meetings]) }
  shared_let(:user) do
    create(:user, member_with_permissions: { project => %i[view_meetings manage_agendas] })
  end

  shared_let(:recurring_meeting) { create(:recurring_meeting, project:, author: user) }
  shared_let(:occurrence) { create(:meeting, project:, author: user, recurring_meeting:) }
  shared_let(:occurrence_section) { create(:meeting_section, meeting: occurrence, title: "Occurrence section title") }

  let(:template) { recurring_meeting.reload.template }
  let(:template_section) { create(:meeting_section, meeting: template, title: "Template section title") }
  let(:turbo_headers) { { "Accept" => "text/vnd.turbo-stream.html" } }

  before do
    login_as user
  end

  shared_examples "supports recurring meeting sections" do
    context "on an occurrence" do
      let(:meeting) { occurrence }

      it "renders the backlog shared with the series template" do
        expect(occurrence.backlog).to eq(template.backlog)

        get path, params: { meeting_section_id: occurrence.backlog.id }, headers: turbo_headers

        expect(response).to have_http_status(:ok)
      end

      it "renders a section of the occurrence" do
        get path, params: { meeting_section_id: occurrence_section.id }, headers: turbo_headers

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Occurrence section title")
      end

      it "does not render a section of the series template" do
        get path, params: { meeting_section_id: template_section.id }, headers: turbo_headers

        expect(response).to have_http_status(:not_found)
        expect(response.body).not_to include("Template section title")
      end
    end

    context "on the series template" do
      let(:meeting) { template }

      it "renders the backlog of the template" do
        get path, params: { meeting_section_id: template.backlog.id }, headers: turbo_headers

        expect(response).to have_http_status(:ok)
      end

      it "renders a section of the template" do
        get path, params: { meeting_section_id: template_section.id }, headers: turbo_headers

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Template section title")
      end

      it "does not render a section of an occurrence" do
        get path, params: { meeting_section_id: occurrence_section.id }, headers: turbo_headers

        expect(response).to have_http_status(:not_found)
        expect(response.body).not_to include("Occurrence section title")
      end
    end
  end

  describe "new" do
    let(:path) { new_project_meeting_agenda_item_path(project, meeting) }

    it_behaves_like "supports recurring meeting sections"
  end

  describe "cancel_new" do
    let(:path) { cancel_new_project_meeting_agenda_items_path(project, meeting) }

    it_behaves_like "supports recurring meeting sections"
  end
end
