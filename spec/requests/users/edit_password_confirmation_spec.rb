# frozen_string_literal: true

require "spec_helper"

# The contract asks for the current password when users change their own email, so the edit form
# has to carry the password confirmation dialog when (and only when) it edits the signed in user.
RSpec.describe "Password confirmation on the user edit form",
               :skip_csrf,
               type: :rails_request,
               with_config: { internal_password_confirmation: true } do
  shared_let(:admin) { create(:admin) }
  shared_let(:other_user) { create(:user) }

  before do
    login_as admin
  end

  def form_controllers
    Nokogiri::HTML(response.body).at_css("form[data-controller*='admin--users']")["data-controller"].split
  end

  it "attaches the dialog when an admin edits their own account" do
    get edit_user_path(admin)

    expect(response).to have_http_status(:ok)
    expect(form_controllers).to include("admin--users", "require-password-confirmation")
  end

  it "does not attach the dialog when an admin edits another user" do
    get edit_user_path(other_user)

    expect(response).to have_http_status(:ok)
    expect(form_controllers).to include("admin--users")
    expect(form_controllers).not_to include("require-password-confirmation")
  end

  context "when password confirmation is disabled", with_config: { internal_password_confirmation: false } do
    it "does not attach the dialog" do
      get edit_user_path(admin)

      expect(form_controllers).not_to include("require-password-confirmation")
    end
  end
end
