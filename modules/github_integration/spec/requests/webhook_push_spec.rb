# frozen_string_literal: true

require_relative "../spec_helper"

# Goes through the real webhook endpoint: routing, API key authentication, the
# wrapping of the JSON body as the `payload` param and the event header.
RSpec.describe "GitHub push webhook" do
  shared_let(:project) { create(:project) }
  shared_let(:work_package) { create(:work_package, project:) }
  shared_let(:role) { create(:project_role, permissions: %i[view_work_packages add_work_package_comments]) }
  shared_let(:system_user) { create(:user, member_with_roles: { project => role }) }
  shared_let(:api_token) { Token::API.create!(user: system_user) }

  let(:branch_name) { "hotfix-OP##{work_package.id}" }
  let(:event) { "push" }
  let(:body) { webhook_payload("push", "branch_pushed", branch: branch_name) }
  let(:key) { api_token.plain_value }

  def deliver
    post "/webhooks/github?key=#{key}",
         body.to_json,
         "CONTENT_TYPE" => "application/json",
         "HTTP_X_GITHUB_EVENT" => event,
         "HTTP_X_GITHUB_DELIVERY" => "push-delivery-1"
  end

  it "answers with 200 and lists the pushed branch on the referenced work package" do
    expect { deliver }.to change(GithubBranch, :count).by(1)

    expect(last_response).to have_http_status(:ok)
    expect(work_package.reload.github_branches.pluck(:name)).to eq([branch_name])
  end

  context "with an unknown API key" do
    let(:key) { "not-a-valid-key" }

    it "does not record a branch" do
      expect { deliver }.not_to change(GithubBranch, :count)
    end
  end

  context "with an event OpenProject does not handle" do
    let(:event) { "star" }

    it "answers with 404 and does not record a branch" do
      expect { deliver }.not_to change(GithubBranch, :count)

      expect(last_response).to have_http_status(:not_found)
    end
  end
end
