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

RSpec.describe Queries::WorkPackages::Filter::EpicFilter do
  let(:project) { build_stubbed(:project) }
  let(:query) { build_stubbed(:query, project:) }

  it_behaves_like "basic query filter" do
    let(:class_key) { :epic }
    let(:type) { :list }

    before do
      instance.context = query
    end

    describe "#where" do
      subject(:where) { instance.where }

      before do
        instance.operator = "="
        instance.values = %w[1 2]
      end

      it "filters by epic_id" do
        expect(where).to include("work_packages.epic_id")
      end
    end
  end

  describe "cross-project epic visibility" do
    let(:admin) { create(:admin) }
    let(:epic_type) { create(:type, name: "Epic") }
    let(:task_type) { create(:type, name: "Task") }
    let(:epic_project) { create(:project, types: [epic_type, task_type]) }
    let(:other_project) { create(:project, types: [epic_type, task_type]) }
    let(:epic) { create(:work_package, project: epic_project, type: epic_type) }
    let!(:linked_task) do
      create(:work_package, project: other_project, type: task_type, epic_id: epic.id)
    end
    let(:other_query) { build(:query, project: other_project, user: admin) }
    let(:instance) do
      described_class.create!(name: :epic, context: other_query, operator: "=", values: [epic.id.to_s])
    end

    before { login_as(admin) }

    it "is valid when filtering by an epic that lives in a different project" do
      expect(instance).to be_valid
    end
  end

  describe "available operators" do
    let(:filter) { described_class.create!(context: query) }

    it "exposes equals, not-equals, and the cross-project variant" do
      symbols = filter.available_operators.map { |op| op.symbol.to_s }
      expect(symbols).to contain_exactly("=", "!", "cross_project=")
    end

    it "defaults to the cross-project operator so new epic filters span projects" do
      expect(filter.default_operator.symbol.to_s).to eq("cross_project=")
    end
  end

  describe "#cross_project?" do
    let(:filter) { described_class.create!(context: query, values: %w[1]) }

    it "is true when the cross-project operator is set" do
      filter.operator = "cross_project="
      expect(filter).to be_cross_project
    end

    it "is false when a project-scoped operator is set" do
      filter.operator = "="
      expect(filter).not_to be_cross_project
    end
  end

  describe "restriction to epic-typed work packages" do
    shared_let(:epic_type) { create(:type, name: "Epic") }
    shared_let(:task_type) { create(:type, name: "Task") }
    shared_let(:restriction_project) { create(:project, types: [epic_type, task_type]) }
    shared_let(:restriction_user) do
      create(:user, member_with_permissions: { restriction_project => [:view_work_packages] })
    end
    shared_let(:an_epic) { create(:work_package, project: restriction_project, type: epic_type) }
    shared_let(:a_task) { create(:work_package, project: restriction_project, type: task_type) }

    let(:real_query) { build(:query, project: restriction_project, user: restriction_user) }

    before { login_as(restriction_user) }

    def filter_for(values, operator: "=")
      described_class.create!(name: :epic, context: real_query, operator:, values:)
    end

    describe "candidate values" do
      it "accepts an epic-typed work package" do
        expect(filter_for([an_epic.id.to_s])).to be_valid
      end

      it "rejects a work package that is not an epic" do
        expect(filter_for([a_task.id.to_s])).not_to be_valid
      end
    end

    describe "self-matching" do
      it "matches the epic itself" do
        expect(WorkPackage.where(filter_for([an_epic.id.to_s]).where)).to include(an_epic)
      end

      it "does not match a non-epic work package by its own id" do
        expect(WorkPackage.where(filter_for([a_task.id.to_s]).where)).not_to include(a_task)
      end

      it "does not exclude a non-epic work package when negated" do
        expect(WorkPackage.where(filter_for([a_task.id.to_s], operator: "!").where)).to include(a_task)
      end

      it "excludes the epic itself when negated" do
        expect(WorkPackage.where(filter_for([an_epic.id.to_s], operator: "!").where)).not_to include(an_epic)
      end
    end

    describe "#available?" do
      it "does not poison the availability cache shared by the other work-package filters" do
        described_class.create!(name: :epic, context: real_query, values: [an_epic.id.to_s]).available?

        parent = Queries::WorkPackages::Filter::ParentFilter.create!(name: :parent, context: real_query,
                                                                     values: [a_task.id.to_s])
        expect(parent).to be_available
      end
    end
  end

  describe "SQL output of the cross-project operator" do
    let(:filter) { described_class.create!(context: query, operator: "cross_project=", values: %w[1 2]) }

    it "still filters by epic_id (the operator only signals scope removal at the query level)" do
      expect(filter.where).to include("work_packages.epic_id")
    end
  end
end
