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

RSpec.describe "Admin label prefixes", :skip_csrf, type: :rails_request do
  shared_let(:archtech) { create(:project, name: "ArchTech", identifier: "at") }
  shared_let(:webext) { create(:project, name: "Web Ext", identifier: "web-ext") }

  def submit(prefixes)
    put admin_settings_label_prefixes_path,
        params: { projects: prefixes.transform_values { |value| { label_prefix: value } } }
  end

  context "as a system admin" do
    current_user { create(:admin) }

    it "lists every project with a computed candidate" do
      get admin_settings_label_prefixes_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("projects[#{archtech.id}][label_prefix]")
      # candidates are computed, never stored - the project still has no prefix
      expect(response.body).to include("AT")
      expect(archtech.reload.label_prefix).to be_nil
    end

    it "derives a candidate by stripping separators, not by copying the identifier" do
      get admin_settings_label_prefixes_path

      # web-ext would make WEB-EXT-Bounce ambiguous, so the hyphen goes
      expect(response.body).to include("WEBEXT")
    end

    it "saves a prefix" do
      submit(archtech.id => "AT")

      expect(archtech.reload.label_prefix).to eq "AT"
    end

    it "rejects an over-long prefix and keeps the old value" do
      submit(archtech.id => "TOOLONG")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(archtech.reload.label_prefix).to be_nil
    end

    it "refuses to give two projects the same prefix" do
      submit(archtech.id => "AT")
      submit(webext.id => "AT")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(webext.reload.label_prefix).to be_nil
    end

    it "stores a cleared prefix as NULL, so several projects can have none" do
      submit(archtech.id => "AT")
      submit(archtech.id => "")

      expect(archtech.reload.label_prefix).to be_nil
      expect(webext.reload.label_prefix).to be_nil
    end

    it "is idempotent - resubmitting the same values changes nothing" do
      submit(archtech.id => "AT")
      updated_at = archtech.reload.updated_at

      submit(archtech.id => "AT")

      expect(archtech.reload.updated_at).to eq updated_at
    end

    it "stops offering a candidate once it is taken by another project" do
      submit(webext.id => "AT")

      get admin_settings_label_prefixes_path

      # ArchTech's candidate would have been AT; it is no longer free
      expect(response.body).to include(I18n.t("label_prefixes.no_candidate"))
    end
  end

  describe "changing a prefix that already has labels" do
    current_user { create(:admin) }

    shared_let(:field) do
      create(:list_wp_custom_field, name: "Labels", multi_value: true, possible_values: %w[ML-Shared])
    end

    before do
      field.update_columns(allow_project_values: true,
                           option_pattern: '\A[A-Z][A-Z0-9]{1,5}-[A-Z][A-Za-z0-9]*\z')
      archtech.update_column(:label_prefix, "AT")
    end

    # Without this the labels keep a prefix the project no longer has: unrenameable, since
    # the naming rule would reject their own value, and the freed prefix could be handed to
    # another project which then creates colliding names.
    it "renames the project's own labels to the new prefix" do
      label = create(:custom_option, custom_field: field, value: "AT-Bounce", project: archtech)

      submit(archtech.id => "ARCH")

      expect(archtech.reload.label_prefix).to eq "ARCH"
      expect(label.reload.value).to eq "ARCH-Bounce"
    end

    it "refuses to clear a prefix while the project owns labels" do
      create(:custom_option, custom_field: field, value: "AT-Bounce", project: archtech)

      submit(archtech.id => "")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(archtech.reload.label_prefix).to eq "AT"
    end

    it "still allows clearing a prefix when no labels exist" do
      submit(archtech.id => "")

      expect(archtech.reload.label_prefix).to be_nil
    end
  end

  context "as a project admin" do
    current_user { create(:user) }

    it "is not reachable" do
      get admin_settings_label_prefixes_path

      expect(response).not_to have_http_status(:ok)
    end
  end
end
