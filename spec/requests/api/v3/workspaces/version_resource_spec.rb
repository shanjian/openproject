# frozen_string_literal: true

# -- copyright
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
# ++

require "spec_helper"
require "rack/test"

RSpec.describe "GET workspaces/:id/versions" do
  include Rack::Test::Methods
  include API::V3::Utilities::PathHelper

  shared_let(:project) { create(:project, public: false) }
  shared_let(:permitted_user) { create(:user, member_with_permissions: { project => [:view_work_packages] }) }
  shared_let(:unpermitted_user) { create(:user, member_with_permissions: { project => [] }) }
  shared_let(:versions) { create_list(:version, 4, project:) }
  shared_let(:other_versions) { create_list(:version, 2) }

  subject(:response) { last_response }

  shared_context "with versions by workspace" do
    context "for a user with permissions to see the versions" do
      current_user { permitted_user }

      before do
        get get_path
      end

      it_behaves_like "API V3 collection response", 4, 4, "Version"
    end

    context "for a user without permissions to see the versions" do
      current_user { unpermitted_user }

      before do
        get get_path
      end

      it_behaves_like "unauthorized access"
    end
  end

  context "for workspaces/:id/versions" do
    let(:get_path) { api_v3_paths.versions_by_workspace project.id }

    include_context "with versions by workspace"
  end

  context "for projects/:id/versions" do
    let(:get_path) { api_v3_paths.versions_by_project project.id }

    include_context "with versions by workspace"
  end

  context "with active=true" do
    shared_let(:closed_version) { create(:version, project:, status: "closed") }
    shared_let(:locked_version) { create(:version, project:, status: "locked") }

    current_user { permitted_user }

    let(:get_path) { "#{api_v3_paths.versions_by_project(project.id)}?active=true" }

    before do
      get get_path
    end

    it_behaves_like "API V3 collection response", 4, 4, "Version"

    it "only returns open versions" do
      statuses = JSON.parse(response.body)["_embedded"]["elements"].pluck("status")
      expect(statuses).to all(eq("open"))
    end
  end

  describe "ordering" do
    shared_let(:ordering_project) { create(:project, public: false) }
    shared_let(:ordering_user) do
      create(:user, member_with_permissions: { ordering_project => [:view_work_packages] })
    end
    shared_let(:version_a) { create(:version, project: ordering_project, name: "Apple") }
    shared_let(:version_m) { create(:version, project: ordering_project, name: "Mango") }
    shared_let(:version_z) { create(:version, project: ordering_project, name: "Zebra") }

    current_user { ordering_user }

    def returned_names
      JSON.parse(last_response.body)["_embedded"]["elements"].pluck("name")
    end

    it "defaults to descending name order when no sortBy is given" do
      get api_v3_paths.versions_by_project(ordering_project.id)

      expect(returned_names).to eq(%w[Zebra Mango Apple])
    end

    it "honours an explicit ascending sortBy" do
      get "#{api_v3_paths.versions_by_project(ordering_project.id)}?sortBy=#{CGI.escape(JSON.dump([%w[name asc]]))}"

      expect(returned_names).to eq(%w[Apple Mango Zebra])
    end
  end
end
