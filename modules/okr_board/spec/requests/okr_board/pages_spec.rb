# frozen_string_literal: true

require "spec_helper"

RSpec.describe "GET /projects/:project_id/okr_board" do
  shared_let(:project) { create(:project) }
  shared_let(:type) { create(:type) }
  let(:user) { create(:user, member_with_permissions: { project => %i[show_okr_board view_work_packages] }) }

  before do
    project.types << type
    project.enabled_module_names += ["okr_board"]
    project.save!
    login_as(user)
  end

  context "without a qualifying custom field or version" do
    it "renders the empty state, not the Angular layout" do
      get project_okr_board_path(project_id: project.id)

      expect(last_response).to have_http_status(:ok)
      expect(last_response.body).to include(ERB::Util.html_escape(I18n.t("okr_board.empty_state.title")))
      expect(last_response.body).not_to include("openproject-base")
    end
  end

  context "with a qualifying custom field and a version" do
    let!(:custom_field) do
      create(:department_wp_custom_field, types: [type], projects: [project])
    end

    before do
      create(:version, project:)
    end

    it "renders the Angular bootstrap layout", :skip_xhr_header do
      get project_okr_board_path(project_id: project.id)

      expect(last_response).to have_http_status(:ok)
      expect(last_response.body).not_to include(ERB::Util.html_escape(I18n.t("okr_board.empty_state.title")))
      expect(last_response.body).to include("openproject-base")
    end

    it "exposes the qualifying custom field's filter id to the frontend" do
      get project_okr_board_path(project_id: project.id)

      expect(last_response.body).to include(
        %(id="okr-board-bootstrap" data-department-filter="#{custom_field.column_name}")
      )
    end
  end

  context "without view_work_packages" do
    let(:user) { create(:user, member_with_permissions: { project => %i[show_okr_board] }) }

    it "denies access" do
      get project_okr_board_path(project_id: project.id)

      expect(last_response).to have_http_status(:forbidden).or have_http_status(:found)
    end
  end
end
