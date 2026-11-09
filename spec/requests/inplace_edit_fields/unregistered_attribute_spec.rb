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

# The attribute in the URL is sent to the model with `public_send`. Without an allowlist
# a GET request could therefore call any public method of a visible project, e.g. `destroy`.
RSpec.describe "Inplace edit fields with attributes that are not registered", type: :rails_request do
  shared_let(:project) { create(:project, public: true) }
  shared_let(:viewer) { create(:user, member_with_permissions: { project => %i[view_project] }) }

  let(:headers) { { "Accept" => "text/vnd.turbo-stream.html" } }

  def request_for(attribute, action)
    get "/inplace_edit_fields/Project/#{project.id}/#{attribute}/#{action}", headers:
  end

  context "when logged in with only the permission to view the project" do
    before { login_as viewer }

    actions = %w[reset edit]

    %w[destroy touch destroy_descendants remove_owned_labels to_json name].each do |attribute|
      actions.each do |action|
        it "answers 404 for #{attribute}/#{action} and leaves the project untouched" do
          updated_at = project.reload.updated_at

          request_for(attribute, action)

          expect(response).to have_http_status(:not_found)
          expect(Project).to exist(project.id)
          expect(project.reload.updated_at).to eq(updated_at)
        end
      end
    end

    it "still renders a registered attribute" do
      request_for("description", "reset")

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
    end
  end

  context "when not logged in, on a public project" do
    before do
      create(:anonymous_role, permissions: %i[view_project])
      Setting.login_required = false
    end

    it "answers 404 and does not call the method" do
      request_for("destroy", "reset")

      expect(response).to have_http_status(:not_found)
      expect(Project).to exist(project.id)
    end
  end
end
