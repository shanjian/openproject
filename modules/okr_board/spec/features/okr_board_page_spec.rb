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

  it "keeps the native filter panel visible alongside the quick filters" do
    visit project_okr_board_path(project_id: project.id)

    expect(page).to have_selector("op-filter-container", wait: 10)
    expect(page).to have_selector("okr-board-filter")
  end

  it "restores the selected unit and version after a reload" do
    create(:department, lastname: "Marketing")
    create(:version, project:, name: "2026 Q3")

    visit project_okr_board_path(project_id: project.id)

    # The quick filter's dropdown options only populate once the query form response
    # (which embeds every filter's allowedValues) resolves, which can take longer than
    # Capybara's default wait -- wait for the real option before selecting it.
    expect(page).to have_select("okr-board-unit-select", with_options: ["Marketing"], wait: 20)
    expect(page).to have_select("okr-board-version-select", with_options: ["2026 Q3"], wait: 20)

    select "Marketing", from: "okr-board-unit-select"
    select "2026 Q3", from: "okr-board-version-select"

    current_url_with_filters = page.current_url
    visit current_url_with_filters

    expect(page).to have_select("okr-board-unit-select", selected: "Marketing", wait: 20)
    expect(page).to have_select("okr-board-version-select", selected: "2026 Q3", wait: 20)
  end
end
