# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Project creation identifier", :skip_csrf, type: :rails_request do
  current_user { create(:admin) }

  it "offers an identifier field on the new project form" do
    get new_project_path(step: 2)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("project[identifier]")
  end

  it "uses the identifier given on the form rather than slugging the name" do
    post projects_path,
         params: { project: { name: "Explicit Code", identifier: "excode", workspace_type: "project" } }

    expect(response).to have_http_status(:redirect)
    expect(Project.find_by(name: "Explicit Code").identifier).to eq "excode"
  end

  # The form marks the field required, but the model-level fallback stays in place so that
  # the API, seeders and project copying can still create projects without one.
  it "still slugs the name when no identifier is supplied" do
    post projects_path, params: { project: { name: "Implicit Code", workspace_type: "project" } }

    expect(Project.find_by(name: "Implicit Code").identifier).to eq "implicit-code"
  end

  # An explicitly supplied identifier skips acts_as_url's uniquifying step (see
  # OpenProject::ActsAsUrl::Adapter::OpActiveRecord#ensure_unique_url!), so the uniqueness
  # validation has to surface instead of the identifier being silently suffixed with "-1".
  it "rejects a duplicate identifier rather than silently suffixing it" do
    create(:project, name: "Taken", identifier: "taken")

    post projects_path,
         params: { project: { name: "Second", identifier: "taken", workspace_type: "project" } }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(Project.where(name: "Second")).to be_empty
  end
end
