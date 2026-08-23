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

# The work package table decides whether to display a work package under the
# epic it links by reading hasParent, because the parent link is empty both for
# a root work package and for one whose parent is invisible. The table consumes
# the collection endpoint, so the property has to survive that path -- not only
# the single work package one.
RSpec.describe "API v3 hasParent property", content_type: :json do
  include Rack::Test::Methods
  include API::V3::Utilities::PathHelper

  shared_let(:epic_type) { create(:type, name: "Epic") }
  shared_let(:task_type) { create(:type, name: "Task") }
  shared_let(:project) { create(:project, types: [epic_type, task_type]) }
  shared_let(:other_project) { create(:project, types: [task_type]) }
  shared_let(:user) do
    create(:user, member_with_permissions: { project => %i[view_work_packages] })
  end

  shared_let(:epic) { create(:work_package, project:, type: epic_type) }
  shared_let(:root_task) { create(:work_package, project:, type: task_type, epic:) }
  shared_let(:visible_parent) { create(:work_package, project:, type: task_type) }
  shared_let(:parented_task) { create(:work_package, project:, type: task_type, parent: visible_parent) }
  shared_let(:invisible_parent) { create(:work_package, project: other_project, type: task_type) }
  shared_let(:hidden_parent_task) do
    create(:work_package, project:, type: task_type, parent: invisible_parent, epic:)
  end

  let(:elements) { JSON.parse(last_response.body).dig("_embedded", "elements") }

  def element_for(work_package)
    elements.find { |element| element["id"] == work_package.id }
  end

  before do
    login_as user
    get api_v3_paths.work_packages_by_workspace(project.id)
  end

  it "is rendered for every element of the collection the table consumes" do
    expect(elements).to all(have_key("hasParent"))
  end

  it "is false for a work package with no parent" do
    expect(element_for(root_task)["hasParent"]).to be(false)
    expect(element_for(epic)["hasParent"]).to be(false)
  end

  it "is true for a work package with a visible parent" do
    expect(element_for(parented_task)["hasParent"]).to be(true)
  end

  # This is the case the parent link cannot express: the link is empty, so
  # without hasParent the table would treat it as a root and nest it under the
  # epic it links, asserting a hierarchy that does not exist.
  it "is true for a work package whose parent is invisible, while the parent link stays empty" do
    element = element_for(hidden_parent_task)

    expect(element["hasParent"]).to be(true)
    expect(element.dig("_links", "parent", "href")).to be_nil
  end

  it "renders the epic link the table pairs it with" do
    expect(element_for(root_task).dig("_links", "epic", "href"))
      .to eq(api_v3_paths.work_package(epic.id))
  end
end
