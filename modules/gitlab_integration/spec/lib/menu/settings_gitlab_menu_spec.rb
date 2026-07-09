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
require_module_spec_helper

# Visibility of the "GitLab" item under Project settings, exercised through the
# same predicate the sidebar uses (MenuHelper#allowed_node?), so we test what a
# user actually sees rather than just controller authorization.
RSpec.describe Redmine::MenuManager::MenuHelper, type: :helper do
  shared_let(:project) { create(:project, enabled_module_names: %w[work_package_tracking gitlab]) }

  let(:node) do
    Redmine::MenuManager.items(:project_menu).find { |n| n.name == :settings_gitlab }
  end

  def visible_for?(user, in_project: project)
    User.current = user
    helper.send(:allowed_node?, node, user, in_project)
  end

  it "registers the settings_gitlab menu node" do
    expect(node).to be_present
  end

  it "is shown to a project admin (edit_project) when the module is enabled" do
    admin = create(:user, member_with_permissions: { project => %i[edit_project] })

    expect(visible_for?(admin)).to be(true)
  end

  it "is hidden from a member without edit_project" do
    viewer = create(:user, member_with_permissions: { project => %i[view_project] })

    expect(visible_for?(viewer)).to be(false)
  end

  it "is hidden when the GitLab module is disabled" do
    plain = create(:project, enabled_module_names: %w[work_package_tracking])
    admin = create(:user, member_with_permissions: { plain => %i[edit_project] })

    expect(visible_for?(admin, in_project: plain)).to be(false)
  end
end
