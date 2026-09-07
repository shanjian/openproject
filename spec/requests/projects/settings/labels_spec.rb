# frozen_string_literal: true

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++
require "spec_helper"

RSpec.describe "Project labels settings", :skip_csrf, type: :rails_request do
  shared_let(:field) do
    create(:list_wp_custom_field, name: "Labels", multi_value: true, possible_values: %w[ML-Shared])
  end
  shared_let(:project) { create(:project, label_prefix: "AT") }
  shared_let(:role) { create(:project_role, permissions: %i[view_project manage_project_labels]) }
  shared_let(:manager) { create(:user, member_with_roles: { project => role }) }

  before do
    field.update_columns(allow_project_values: true,
                         option_pattern: '\A[A-Z][A-Z0-9]{1,5}-[A-Z][A-Za-z0-9]*\z')
  end

  context "as a project admin" do
    current_user { manager }

    it "lists the project's own labels and the shared ones" do
      mine = create(:custom_option, custom_field: field, value: "AT-Bounce", project:)

      get project_settings_labels_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(mine.value)
      expect(response.body).to include("ML-Shared")
    end

    it "creates a label under the project's prefix" do
      post project_settings_labels_path(project), params: { custom_option: { value: "AT-Bounce" } }

      expect(field.custom_options.where(project:).pluck(:value)).to include("AT-Bounce")
    end

    it "refuses a label that does not carry the prefix" do
      post project_settings_labels_path(project), params: { custom_option: { value: "ZZ-Nope" } }

      expect(field.custom_options.where(project:)).to be_empty
    end

    it "renames its own label" do
      option = create(:custom_option, custom_field: field, value: "AT-Bounce", project:)

      patch project_settings_label_path(project, option), params: { custom_option: { value: "AT-Renamed" } }

      expect(option.reload.value).to eq "AT-Renamed"
    end

    it "does not rename a shared label" do
      system_label = field.custom_options.system_level.first

      patch project_settings_label_path(project, system_label), params: { custom_option: { value: "AT-Hijack" } }

      expect(system_label.reload.value).to eq "ML-Shared"
    end

    it "deletes its own label and the values pointing at it" do
      option = create(:custom_option, custom_field: field, value: "AT-Gone", project:)

      delete project_settings_label_path(project, option)

      expect(CustomOption.where(id: option.id)).to be_empty
    end

    it "explains itself when the project has no prefix" do
      project.update_column(:label_prefix, nil)

      get project_settings_labels_path(project)

      expect(response.body).to include(I18n.t("project_labels.no_prefix"))
    end
  end

  describe "when no field accepts project values" do
    current_user { manager }

    before { field.update_column(:allow_project_values, false) }

    it "says so rather than rendering an empty screen" do
      get project_settings_labels_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("project_labels.not_enabled"))
    end

    # The mutating actions used to hand nil to the service, whose guard dereferences it -
    # a 500 on an instance where nobody has enabled the feature yet.
    it "redirects rather than raising when a label is submitted" do
      post project_settings_labels_path(project), params: { custom_option: { value: "AT-Bounce" } }

      expect(response).to have_http_status(:redirect)
      expect(field.custom_options.where(project:)).to be_empty
    end
  end

  describe "with more than one project-aware field" do
    shared_let(:second_field) do
      create(:list_wp_custom_field, name: "Zulu labels", multi_value: true, possible_values: %w[ZZ-Shared])
    end

    current_user { manager }

    before do
      second_field.update_columns(allow_project_values: true,
                                  option_pattern: '\A[A-Z][A-Z0-9]{1,5}-[A-Z][A-Za-z0-9]*\z')
    end

    # The screen used to manage only the alphabetically first field, leaving the others'
    # labels unreachable even though the admin form can enable any of them.
    it "lists every one of them" do
      get project_settings_labels_path(project)

      expect(response.body).to include(field.name)
      expect(response.body).to include(second_field.name)
    end

    it "creates the label on the field it was submitted for" do
      post project_settings_labels_path(project),
           params: { custom_field_id: second_field.id, custom_option: { value: "AT-Zulu" } }

      expect(second_field.custom_options.where(project:).pluck(:value)).to include("AT-Zulu")
      expect(field.custom_options.where(project:)).to be_empty
    end
  end

  context "as a member without the permission" do
    shared_let(:plain_role) { create(:project_role, permissions: %i[view_project]) }
    shared_let(:member) { create(:user, member_with_roles: { project => plain_role }) }

    current_user { member }

    it "is not reachable" do
      get project_settings_labels_path(project)

      expect(response).not_to have_http_status(:ok)
    end
  end
end
