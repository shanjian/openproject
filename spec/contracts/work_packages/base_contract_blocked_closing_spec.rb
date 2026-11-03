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

RSpec.describe WorkPackages::BaseContract, "closing a blocked work package" do
  shared_let(:type) { create(:type) }
  shared_let(:project) { create(:project, types: [type]) }
  shared_let(:open_status) { create(:default_status) }
  shared_let(:closed_status) { create(:closed_status, name: "Done") }
  shared_let(:other_closed_status) { create(:closed_status, name: "Closed") }
  shared_let(:priority) { create(:default_priority) }
  shared_let(:role) { create(:project_role, permissions: %i[view_work_packages edit_work_packages]) }
  shared_let(:user) { create(:user, member_with_roles: { project => role }) }

  let(:work_package) do
    create(:work_package, project:, type:, status: open_status, priority:, author: user)
  end
  let(:contract) { WorkPackages::UpdateContract.new(work_package, user) }

  before_all do
    [closed_status, other_closed_status].each do |status|
      create(:workflow, type:, role:, old_status: open_status, new_status: status)
      create(:workflow, type:, role:, old_status: closed_status, new_status: status)
    end
  end

  def block(blocked, by:)
    create(:relation, relation_type: Relation::TYPE_BLOCKS, from: by, to: blocked)
  end

  def create_blocker(subject: "The blocker", in_project: project, status: open_status)
    create(:work_package, project: in_project, type:, subject:, status:, priority:, author: user)
  end

  def status_id_errors(new_status)
    work_package.status = new_status
    contract.validate
    contract.errors.symbols_for(:status_id)
  end

  context "without blockers" do
    it "can be closed" do
      expect(status_id_errors(closed_status)).to be_empty
    end
  end

  context "when an open work package blocks it" do
    let!(:blocker) { create_blocker(subject: "Discussion on the attributes") }

    before { block(work_package, by: blocker) }

    it "still offers the closed statuses" do
      expect(contract.assignable_statuses).to include(closed_status, other_closed_status)
    end

    it "refuses to close it" do
      expect(status_id_errors(closed_status)).to contain_exactly(:blocked_by_open_work_packages)
    end

    it "names the blocker and says what to do" do
      work_package.status = closed_status
      contract.validate

      expect(contract.errors.full_messages.to_sentence)
        .to eq("Status cannot be changed to closed while this work package is blocked by " \
               "##{blocker.id} \"Discussion on the attributes\". " \
               "Close that work package or remove the relation first.")
    end

    it "does not stop a change to another open status" do
      other_open = create(:status)
      create(:workflow, type:, role:, old_status: open_status, new_status: other_open)

      expect(status_id_errors(other_open)).to be_empty
    end

    it "does not stop edits that leave the status alone" do
      work_package.subject = "Renamed"
      contract.validate

      expect(contract.errors.symbols_for(:status_id)).to be_empty
    end

    context "when the blocker has been closed" do
      before { blocker.update_column(:status_id, closed_status.id) }

      it "can be closed" do
        expect(status_id_errors(closed_status)).to be_empty
      end
    end

    context "when it is closed already and only moves to another closed status" do
      before { work_package.update_column(:status_id, closed_status.id) }

      it "is not refused" do
        expect(status_id_errors(other_closed_status)).to be_empty
      end
    end

    context "when a blocker is in a project the user cannot see" do
      let!(:hidden_blocker) do
        create_blocker(subject: "Secret title", in_project: create(:project, types: [type], public: false)).tap do |wp|
          block(work_package, by: wp)
        end
      end

      it "counts it without revealing its title" do
        work_package.status = closed_status
        contract.validate
        message = contract.errors.full_messages.to_sentence

        expect(message).to include(%(##{blocker.id} "Discussion on the attributes", 1 work package you cannot access))
        expect(message).not_to include("Secret title")
        expect(message).not_to include("##{hidden_blocker.id}")
      end
    end
  end

  context "when two open work packages block it" do
    before do
      block(work_package, by: create_blocker(subject: "First"))
      block(work_package, by: create_blocker(subject: "Second"))
    end

    it "uses the plural wording" do
      work_package.status = closed_status
      contract.validate

      expect(contract.errors.full_messages.to_sentence)
        .to end_with("Close those work packages or remove the relations first.")
    end
  end

  context "when more work packages block it than are listed" do
    before do
      (WorkPackages::BaseContract::MAX_LISTED_BLOCKERS + 2).times do |i|
        block(work_package, by: create_blocker(subject: "Blocker #{i}"))
      end
    end

    it "summarizes the rest" do
      work_package.status = closed_status
      contract.validate

      expect(contract.errors.full_messages.to_sentence).to include(", and 2 more.")
    end
  end

  describe "through the update service" do
    let!(:blocker) { create_blocker }

    before { block(work_package, by: blocker) }

    it "leaves the work package open and reports why" do
      result = WorkPackages::UpdateService
        .new(user:, model: work_package.reload)
        .call(status_id: closed_status.id)

      expect(result).to be_failure
      expect(result.errors.full_messages.to_sentence).to include("blocked by ##{blocker.id}")
      expect(work_package.reload.status).to eq(open_status)
    end
  end
end
