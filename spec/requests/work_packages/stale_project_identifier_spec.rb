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

# A project identifier that has been renamed leaves every deep link that was shared
# outside OpenProject pointing at a project that no longer resolves. Because the work
# package id is globally unique, such links are still unambiguous and are redirected to
# the canonical route rather than served as a 404.
RSpec.describe "Work package links with a stale project identifier", type: :rails_request do
  shared_let(:project) { create(:project, identifier: "adt") }
  shared_let(:other_project) { create(:project, identifier: "prtl") }
  shared_let(:child_project) { create(:project, identifier: "adt-child", parent: project) }
  shared_let(:work_package) { create(:work_package, project:) }
  shared_let(:child_work_package) { create(:work_package, project: child_project) }

  shared_let(:user) do
    create(:user, member_with_permissions: { project => %i[view_work_packages],
                                             other_project => %i[view_work_packages],
                                             child_project => %i[view_work_packages] })
  end

  current_user { user }

  # The identifier "ad" was renamed to "adt", so it no longer resolves to any project.
  let(:stale_identifier) { "ad" }

  def canonical_url(tab: "activity")
    "/projects/#{project.identifier}/work_packages/#{work_package.id}/#{tab}"
  end

  context "when the identifier no longer resolves to any project" do
    it "redirects permanently to the canonical route" do
      get "/projects/#{stale_identifier}/work_packages/#{work_package.id}"

      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to(canonical_url)
    end

    it "keeps the requested tab" do
      get "/projects/#{stale_identifier}/work_packages/#{work_package.id}/relations"

      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to(canonical_url(tab: "relations"))
    end

    it "reaches the work package in a single redirect" do
      get "/projects/#{stale_identifier}/work_packages/#{work_package.id}/activity"
      follow_redirect!

      expect(response).to have_http_status(:ok)
    end

    # WORK_PACKAGES_ROUTES declares query_id, query_props, name and
    # start_onboarding_tour, and modules add their own on top, so the whole query string
    # is carried over rather than an allowlisted subset of it.
    it "keeps every parameter the link was shared with" do
      get "/projects/#{stale_identifier}/work_packages/#{work_package.id}/activity",
          params: { query_id: "42", query_props: '{"c":["id"]}',
                    name: "My saved view", start_onboarding_tour: "true", sprint_id: "7" }

      expect(response).to have_http_status(:moved_permanently)

      location = URI.parse(response.headers["Location"])
      expect(Rack::Utils.parse_query(location.query))
        .to eq("query_id" => "42", "query_props" => '{"c":["id"]}',
               "name" => "My saved view", "start_onboarding_tour" => "true", "sprint_id" => "7")
    end
  end

  # A project list contains the work packages of its descendants, and the frontend builds
  # full screen links from the project whose list is open rather than from the work
  # package itself, so a project that is not the work package's own is a normal,
  # meaningful context and must survive untouched. Canonicalizing it away would discard
  # the parent project context on every click through a subproject work package -- and
  # permanently, the redirect being cacheable.
  context "when the identifier resolves to an ancestor of the work package's project" do
    it "renders the work package, keeping the project context the link was built with" do
      get "/projects/#{project.identifier}/work_packages/#{child_work_package.id}/activity"

      expect(response).to have_http_status(:ok)
    end

    it "keeps that context in the split view too" do
      get "/projects/#{project.identifier}/work_packages/details/#{child_work_package.id}/overview"

      expect(response).to have_http_status(:ok)
    end
  end

  # An identifier freed by a rename can later be handed to an unrelated project. The
  # work package was never reachable through that project's list, so using it as the
  # page's context would quietly misrepresent where the work package lives.
  context "when the identifier resolves to a project the work package is unreachable through" do
    it "redirects permanently to the project the work package actually belongs to" do
      get "/projects/#{other_project.identifier}/work_packages/#{work_package.id}/activity"

      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to(canonical_url)
    end

    it "canonicalizes the split view as well" do
      get "/projects/#{other_project.identifier}/work_packages/details/#{work_package.id}/overview"

      expect(response).to have_http_status(:moved_permanently)
      expect(response)
        .to redirect_to("/projects/#{project.identifier}/work_packages/details/#{work_package.id}/overview")
    end

    it "canonicalizes a descendant project, which does not contain the ancestor's work packages" do
      get "/projects/#{child_project.identifier}/work_packages/#{work_package.id}/activity"

      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to(canonical_url)
    end
  end

  context "when the identifier is already canonical" do
    it "renders the work package without redirecting" do
      get canonical_url

      expect(response).to have_http_status(:ok)
    end
  end

  context "when the project is referenced by its numeric id" do
    it "does not redirect, preserving the previous behaviour" do
      get "/projects/#{project.id}/work_packages/#{work_package.id}/activity"

      expect(response).to have_http_status(:ok)
    end
  end

  context "when the work package is not visible to the user" do
    shared_let(:invisible_work_package) do
      create(:work_package, project: create(:project, identifier: "secret-project"))
    end

    it "renders a 404 rather than disclosing the project through a redirect" do
      get "/projects/#{stale_identifier}/work_packages/#{invisible_work_package.id}"

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include("secret-project")
    end
  end

  context "when the work package does not exist" do
    it "renders a 404" do
      get "/projects/#{stale_identifier}/work_packages/#{WorkPackage.maximum(:id).to_i + 1}"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "split view links, where the id lives in the client side routing state" do
    it "redirects permanently to the canonical route" do
      get "/projects/#{stale_identifier}/work_packages/details/#{work_package.id}/overview"

      expect(response).to have_http_status(:moved_permanently)
      expect(response)
        .to redirect_to("/projects/#{project.identifier}/work_packages/details/#{work_package.id}/overview")
    end

    it "keeps the query the link was shared with" do
      get "/projects/#{stale_identifier}/work_packages/details/#{work_package.id}/overview",
          params: { query_props: '{"c":["id"]}' }

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to include("query_props=")
    end

    it "reaches the work package in a single redirect" do
      get "/projects/#{stale_identifier}/work_packages/details/#{work_package.id}/overview"
      follow_redirect!

      expect(response).to have_http_status(:ok)
    end

    it "does not redirect when the identifier is already canonical" do
      get "/projects/#{project.identifier}/work_packages/details/#{work_package.id}/overview"

      expect(response).to have_http_status(:ok)
    end

    it "renders a 404 when the work package is not visible to the user" do
      invisible = create(:work_package, project: create(:project, identifier: "secret-project"))

      get "/projects/#{stale_identifier}/work_packages/details/#{invisible.id}/overview"

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include("secret-project")
    end

    it "renders a 404 for a stale identifier that carries no work package id" do
      get "/projects/#{stale_identifier}/work_packages"

      expect(response).to have_http_status(:not_found)
    end

    # The global list legitimately spans projects. Canonicalizing it into the project of
    # whichever work package happens to be open in the split view would destroy it.
    it "leaves the global cross-project list alone" do
      get "/work_packages/details/#{work_package.id}/overview"

      expect(response).to have_http_status(:ok)
    end
  end
end
