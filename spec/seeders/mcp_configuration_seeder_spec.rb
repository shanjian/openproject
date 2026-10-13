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
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

require "spec_helper"

RSpec.describe McpConfigurationSeeder do
  subject(:seeder) { described_class.new(nil) }

  let(:write_tools) { %w[create_work_package update_work_package create_work_package_comment].map { "tools/#{it}" } }
  let(:new_tools) { write_tools + ["tools/list_priorities"] }
  let(:older_tools) { McpTools.all.map(&:qualified_name) - new_tools }

  context "on an instance that was set up before the write tools existed" do
    let!(:server) { create(:mcp_configuration, identifier: "mcp_server", title: "Acme OpenProject", enabled: true) }
    let!(:customised) do
      create(:mcp_configuration, identifier: "tools/search_users", title: "Find colleagues", enabled: false)
    end

    before do
      (older_tools - ["tools/search_users"]).each { |identifier| create(:mcp_configuration, identifier:, enabled: true) }
    end

    it "adds the new tools, and they are enabled: live by default, per the decision to roll them out together" do
      seeder.seed!

      expect(McpConfiguration.where(identifier: new_tools).pluck(:identifier)).to match_array(new_tools)
      expect(McpConfiguration.where(identifier: new_tools)).to all(be_enabled)
    end

    it "gives them their default title and description" do
      seeder.seed!

      row = McpConfiguration.find_by!(identifier: "tools/create_work_package")
      expect(row).to have_attributes(title: McpTools::CreateWorkPackage.default_title,
                                     description: McpTools::CreateWorkPackage.default_description)
    end

    it "leaves every existing row exactly as the administrator left it" do
      seeder.seed!

      expect(customised.reload).to have_attributes(title: "Find colleagues", enabled: false)
      expect(server.reload).to have_attributes(title: "Acme OpenProject", enabled: true)
    end

    it "changes nothing the second time" do
      seeder.seed!

      expect { described_class.new(nil).seed! }
        .not_to(change { McpConfiguration.order(:id).pluck(:identifier, :title, :enabled) })
    end
  end

  it "knows the write tools by name, so the cause class and the registry cannot drift apart" do
    expect(McpTools.all.map(&:qualified_name)).to include(*write_tools)
  end
end
