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
require "rack/test"

# The status dropdown is fed by the form's allowed values and a status change is saved with a PATCH.
# A blocked work package must still offer its closed statuses, and refuse them with a reason.
RSpec.describe "API v3 closing a blocked work package",
               content_type: :json do
  include API::V3::Utilities::PathHelper

  shared_let(:type) { create(:type) }
  shared_let(:project) { create(:project, types: [type]) }
  shared_let(:open_status) { create(:default_status) }
  shared_let(:closed_status) { create(:closed_status, name: "Done") }
  shared_let(:priority) { create(:default_priority) }
  shared_let(:role) { create(:project_role, permissions: %i[view_work_packages edit_work_packages]) }

  let(:work_package) { create(:work_package, project:, type:, status: open_status, priority:) }
  let(:blocker) { create(:work_package, project:, type:, status: open_status, priority:, subject: "Mixpanel cleanup") }

  current_user { create(:user, member_with_roles: { project => role }) }

  before_all do
    create(:workflow, type:, role:, old_status: open_status, new_status: closed_status)
  end

  before do
    create(:relation, relation_type: Relation::TYPE_BLOCKS, from: blocker, to: work_package)
  end

  describe "POST /api/v3/work_packages/:id/form" do
    it "lists the closed status among the allowed values" do
      post api_v3_paths.work_package_form(work_package.id), { lockVersion: work_package.lock_version }.to_json

      allowed = JSON.parse(last_response.body).dig("_embedded", "schema", "status", "_embedded", "allowedValues")

      expect(allowed.pluck("name")).to include("Done")
    end
  end

  describe "PATCH /api/v3/work_packages/:id" do
    let(:params) do
      {
        lockVersion: work_package.lock_version,
        _links: { status: { href: api_v3_paths.status(closed_status.id) } }
      }
    end

    it "refuses with a message naming the blocker, and keeps the status" do
      patch api_v3_paths.work_package(work_package.id), params.to_json

      body = JSON.parse(last_response.body)

      expect(last_response).to have_http_status(:unprocessable_entity)
      expect(body["errorIdentifier"]).to eq("urn:openproject-org:api:v3:errors:PropertyConstraintViolation")
      expect(body["message"]).to eq(
        "Status cannot be changed to closed while this work package is blocked by " \
        "##{blocker.id} \"Mixpanel cleanup\". Close that work package or remove the relation first."
      )
      expect(work_package.reload.status).to eq(open_status)
    end

    it "allows it once the blocker is closed" do
      blocker.update_column(:status_id, closed_status.id)

      patch api_v3_paths.work_package(work_package.id), params.to_json

      expect(last_response).to have_http_status(:ok)
      expect(work_package.reload.status).to eq(closed_status)
    end
  end
end
