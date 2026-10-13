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

RSpec.describe McpTools::WorkPackageData do
  include API::V3::Utilities::PathHelper

  def unsupported(data, creating: false)
    described_class.new(data, creating:).unsupported_keys
  end

  describe "#unsupported_keys, the check on what the assistant sent" do
    it "accepts every key the tools support" do
      data = {
        "subject" => "s", "description" => { "raw" => "d" }, "lockVersion" => 1, "startDate" => "2026-11-02",
        "dueDate" => "2026-11-05", "duration" => "P3D", "estimatedTime" => "PT4H", "remainingTime" => "PT2H",
        "percentageDone" => 10, "scheduleManually" => true, "ignoreNonWorkingDays" => false, "storyPoints" => 3,
        "customField12" => "x",
        "_links" => {
          "type" => {}, "status" => {}, "priority" => {}, "assignee" => {}, "responsible" => {}, "parent" => {},
          "version" => {}, "category" => {}, "epic" => {}, "customField13" => {}
        }
      }

      expect(unsupported(data)).to be_empty
    end

    it "accepts symbol keys, as the MCP gem may deliver them" do
      expect(unsupported({ subject: "s", _links: { type: { href: "/api/v3/types/1" } } })).to be_empty
    end

    it "accepts an empty payload; the contract decides whether that is enough" do
      expect(unsupported({})).to be_empty
    end

    {
      "a typo" => [{ "subjcet" => "s" }, ["subjcet"]],
      "meta" => [{ "meta" => { "validateCustomFields" => false } }, ["meta"]],
      "_type" => [{ "_type" => "WorkPackage" }, ["_type"]],
      "id" => [{ "id" => 5 }, ["id"]],
      "createdAt" => [{ "createdAt" => "2020-01-01T00:00:00Z" }, ["createdAt"]],
      "updatedAt" => [{ "updatedAt" => "2020-01-01T00:00:00Z" }, ["updatedAt"]],
      "attachments at the top level" => [{ "attachments" => [] }, ["attachments"]],
      "an attachments link, even an empty one" => [{ "_links" => { "attachments" => [] } }, ["_links.attachments"]],
      "a file links link" => [{ "_links" => { "fileLinks" => [] } }, ["_links.fileLinks"]],
      "a watchers link" => [{ "_links" => { "watchers" => [{ "href" => "/api/v3/users/1" }] } }, ["_links.watchers"]],
      "an author link" => [{ "_links" => { "author" => { "href" => "/api/v3/users/1" } } }, ["_links.author"]],
      "a self link" => [{ "_links" => { "self" => { "href" => "/api/v3/work_packages/1" } } }, ["_links.self"]],
      "a custom field name that is not numeric" => [{ "customFieldX" => "x" }, ["customFieldX"]],
      "properties that need a decision first" => [{ "position" => 1, "sprint" => nil, "budget" => nil }, %w[position sprint budget]]
    }.each do |label, (data, expected)|
      it "refuses #{label}, and names it" do
        expect(unsupported(data)).to eq(expected)
      end
    end

    it "names every offending key, links and attributes together, in the order sent" do
      data = { "subject" => "s", "meta" => {}, "_links" => { "watchers" => [], "type" => {}, "attachments" => [] } }

      expect(unsupported(data)).to eq(%w[meta _links.watchers _links.attachments])
    end

    it "refuses a project link on update, and accepts it on create" do
      data = { "_links" => { "project" => { "href" => "/api/v3/projects/1" } } }

      expect(unsupported(data, creating: false)).to eq(["_links.project"])
      expect(unsupported(data, creating: true)).to be_empty
    end

    it "refuses a payload that is not an object, rather than raising" do
      expect(unsupported("subject")).to eq(["data"])
      expect(unsupported(nil)).to eq(["data"])
    end

    it "refuses _links that is not an object" do
      expect(unsupported({ "_links" => [] })).to eq(["_links"])
    end
  end

  describe "#unsupported_parsed_keys, the backstop on what the parser produced" do
    def unsupported_parsed(keys, creating: false)
      described_class.new({}, creating:).unsupported_parsed_keys(keys.index_with(nil))
    end

    it "accepts the keys the supported properties parse to" do
      keys = %i[lock_version subject description type_id status_id priority_id assigned_to_id responsible_id parent
                version_id category_id epic start_date due_date duration estimated_hours remaining_hours done_ratio
                schedule_manually ignore_non_working_days story_points custom_field_12]

      expect(unsupported_parsed(keys)).to be_empty
    end

    it "refuses what would replace or re-attribute" do
      keys = %i[subject attachment_ids file_links_ids author_id created_at updated_at budget_id position sprint_id]

      expect(unsupported_parsed(keys)).to eq(%i[attachment_ids file_links_ids author_id created_at updated_at
                                                budget_id position sprint_id])
    end

    it "accepts the project only when creating" do
      expect(unsupported_parsed(%i[project_id], creating: true)).to be_empty
      expect(unsupported_parsed(%i[project_id], creating: false)).to eq(%i[project_id])
    end
  end

  describe "the two checks agree: every supported raw key parses into the supported parsed set" do
    let(:user) { create(:admin) }
    let(:type) { create(:type) }
    let(:project) { create(:project, types: [type]) }
    let(:other_work_package) { create(:work_package, project:, type:) }
    let(:version) { create(:version, project:) }
    let(:category) { create(:category, project:) }
    let(:text_cf) { create(:text_wp_custom_field) }
    let(:list_cf) { create(:list_wp_custom_field) }

    let(:data) do
      create(:default_status)
      create(:default_priority)
      {
        "lockVersion" => 0, "subject" => "s", "description" => { "raw" => "d" },
        "startDate" => "2026-11-02", "dueDate" => "2026-11-05", "duration" => "P3D", "estimatedTime" => "PT4H",
        "remainingTime" => "PT2H", "percentageDone" => 10, "scheduleManually" => true,
        "ignoreNonWorkingDays" => false, "storyPoints" => 3, "customField#{text_cf.id}" => { "raw" => "x" },
        "_links" => {
          "type" => { "href" => api_v3_paths.type(type.id) },
          "status" => { "href" => api_v3_paths.status(Status.default.id) },
          "priority" => { "href" => api_v3_paths.priority(IssuePriority.default.id) },
          "assignee" => { "href" => api_v3_paths.user(user.id) },
          "responsible" => { "href" => api_v3_paths.user(user.id) },
          "parent" => { "href" => api_v3_paths.work_package(other_work_package.id) },
          "version" => { "href" => api_v3_paths.version(version.id) },
          "category" => { "href" => api_v3_paths.category(category.id) },
          "epic" => { "href" => api_v3_paths.work_package(other_work_package.id) },
          "project" => { "href" => api_v3_paths.project(project.id) },
          "customField#{list_cf.id}" => { "href" => api_v3_paths.custom_option(list_cf.custom_options.first.id) }
        }
      }
    end

    it "passes the raw check and the parsed check" do
      parsed = User.execute_as(user) do
        API::V3::WorkPackages::ParseParamsService.new(user, model: WorkPackage).call(data)
      end
      checker = described_class.new(data, creating: true)

      expect(parsed).to be_success
      expect(checker.unsupported_keys).to be_empty
      expect(checker.unsupported_parsed_keys(parsed.result)).to be_empty
    end
  end

  describe "#message" do
    it "names what was refused and lists what is supported, so the model can correct itself" do
      message = described_class.new({ "meta" => {}, "_links" => { "watchers" => [] } }, creating: false).message

      expect(message).to include("meta", "_links.watchers")
      expect(message).to include("subject", "lockVersion", "type", "assignee")
      expect(message).not_to include("_links.project") # a project link is not offered on update
    end

    it "offers the project link when creating" do
      expect(described_class.new({ "meta" => {} }, creating: true).message).to include("project")
    end
  end
end
