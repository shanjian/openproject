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

  it "refuses to create a project when the form omits the identifier" do
    post projects_path, params: { project: { name: "No Code", workspace_type: "project" } }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(Project.where(name: "No Code")).to be_empty
  end

  it "sends the user back to the details step with the name they typed" do
    post projects_path, params: { project: { name: "No Code", workspace_type: "project" } }

    expect(response.body).to include("No Code")
    expect(response.body).to include("project[identifier]")
  end

  it "refuses a blank identifier as well as a missing one" do
    post projects_path,
         params: { project: { name: "Blank Code", identifier: "  ", workspace_type: "project" } }

    expect(Project.where(name: "Blank Code")).to be_empty
  end

  # The guard is deliberately scoped to the creation form. Everything that does not post
  # through ProjectsController#create - the API, seeders, project copying - keeps
  # acts_as_url's slug-from-name fallback.
  it "still slugs the name for callers that bypass the form" do
    project = Projects::CreateService
      .new(user: User.current)
      .call(name: "Implicit Code", workspace_type: "project")
      .result

    expect(project.identifier).to eq "implicit-code"
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
