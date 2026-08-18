require "spec_helper"

RSpec.describe "OKR Board module registration" do
  it "registers the okr_board project module and show_okr_board permission" do
    expect(OpenProject::AccessControl.modules.map { |m| m[:name] }).to include(:okr_board)
    expect(OpenProject::AccessControl.permission(:show_okr_board)).not_to be_nil
    expect(OpenProject::AccessControl.permission(:show_okr_board).project_module).to eq(:okr_board)
  end

  it "grants show_okr_board to the default roles Boards grants its own view permission to" do
    %i[default_role_non_member default_role_member default_role_reader].each do |role|
      role_permissions = YAML.load_file(
        Rails.root.join("modules/okr_board/app/seeders/common.yml")
      )["modules_permissions"]["okr_board"]
      entry = role_permissions.find { |e| e["role"] == role.to_s }
      expect(entry["add"]).to include("show_okr_board")
    end
  end
end
