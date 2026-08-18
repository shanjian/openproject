require "spec_helper"

RSpec.describe "OKR Board page", js: true do
  shared_let(:project) { create(:project) }
  shared_let(:type) { create(:type) }
  let(:user) { create(:user, member_with_permissions: { project => %i[show_okr_board view_work_packages] }) }

  before do
    project.types << type
    project.enabled_module_names += ["okr_board"]
    project.save!
    create(:department_wp_custom_field, types: [type], projects: [project])
    create(:version, project:)
    login_as(user)
  end

  it "renders the work package table" do
    visit project_okr_board_path(project_id: project.id)

    expect(page).to have_selector(".work-package-table--container", wait: 10)
  end
end
