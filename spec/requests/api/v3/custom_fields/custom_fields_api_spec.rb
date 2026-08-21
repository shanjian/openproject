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

RSpec.describe "API v3 custom fields", :webmock, content_type: :json do
  include API::V3::Utilities::PathHelper

  describe "GET /api/v3/custom_fields/:id" do
    shared_let(:type) { create(:type) }
    shared_let(:project) { create(:project, types: [type]) }
    shared_let(:custom_field) { create(:wp_custom_field, name: "Celestial Body", types: [type], projects: [project]) }

    let(:path) { api_v3_paths.custom_field(custom_field.id) }

    subject(:last_response) { get path }

    context "if the user is not logged in" do
      it_behaves_like "unauthenticated access"
    end

    context "with an admin" do
      current_user { create(:admin) }

      it "responds with the custom field" do
        expect(last_response).to have_http_status(:ok)
        expect(JSON.parse(last_response.body)).to include("id" => custom_field.id, "name" => "Celestial Body")
      end

      # The representer's self link advertises this path, so it has to resolve. It did not before
      # this endpoint was mounted, which meant every MCP custom field response pointed at a 404.
      it "is the path the representer's own self link points at" do
        expect(last_response).to have_http_status(:ok)
        expect(JSON.parse(last_response.body).dig("_links", "self", "href")).to eq(path)
      end

      it "matches the documented schema" do
        expect(last_response.body).to match_json_schema.from_docs("custom_field_model")
      end

      context "with a department custom field, a format upstream's schema does not list" do
        let!(:department_field) { create(:wp_custom_field, field_format: "department", types: [type], projects: [project]) }
        let(:path) { api_v3_paths.custom_field(department_field.id) }

        it "still matches the documented schema" do
          expect(last_response).to have_http_status(:ok)
          expect(last_response.body).to match_json_schema.from_docs("custom_field_model")
        end
      end
    end

    context "if the custom field does not exist" do
      current_user { create(:admin) }
      let(:path) { api_v3_paths.custom_field(0) }

      it_behaves_like "not found"
    end
  end
end
