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

RSpec.describe WorkPackages::Import::CreateJob do
  let(:project) { create(:project) }
  let(:user) do
    create(:user,
           member_with_permissions: { project => %i[view_work_packages add_work_packages manage_subtasks assign_versions] })
  end
  let!(:task_type) { create(:type_task, name: "Task", projects: [project]) }
  let!(:objective_type) { create(:type, name: "Objective", projects: [project]) }
  # WorkPackages::CreateContract requires a status and a priority to be assignable by default
  # (WorkPackages::SetAttributesService#set_default_status/#set_default_priority); neither is
  # seeded automatically for a fresh example, so create the "is_default" ones explicitly.
  let!(:default_status) { create(:default_status) }
  let!(:default_priority) { create(:default_priority) }

  let(:import_run) { create(:work_packages_import_run, project:, user:, source:) }

  context "with a valid two-level document" do
    let(:source) { <<~MD }
      # Objective: Increase retention

      ## Task: Rework the sequence
    MD

    it "creates every node and links parent_id top-down" do
      perform_enqueued_jobs { described_class.perform_later(import_run:) }
      import_run.reload

      expect(import_run).to be_succeeded
      expect(import_run.created_work_package_ids.size).to eq(2)

      objective, task = WorkPackage.where(id: import_run.created_work_package_ids).order(:id)
      expect(task.parent_id).to eq(objective.id)
    end

    it "suppresses notifications" do
      allow(WorkPackages::CreateService).to receive(:new).and_wrap_original do |method, **kwargs|
        method.call(**kwargs)
      end

      expect { perform_enqueued_jobs { described_class.perform_later(import_run:) } }
        .not_to have_enqueued_mail

      expect(WorkPackages::CreateService).to have_received(:new).at_least(:once)
    end
  end

  context "when a later node fails" do
    let(:source) { <<~MD }
      # Objective: Increase retention

      ## Task: Rework the sequence
      - Accountable: nobody@example.com
    MD

    it "rolls back every work package and records the failing line" do
      expect { perform_enqueued_jobs { described_class.perform_later(import_run:) } }
        .not_to change(WorkPackage, :count)

      import_run.reload
      expect(import_run).to be_failed
      # Resolver attaches attribute errors to the node's heading line (see
      # WorkPackages::Import::Resolver#resolve_node and its own spec), not the bullet's own
      # line -- line 3 is "## Task: Rework the sequence", the heading the bullet belongs to.
      expect(import_run.failure["source_line"]).to eq(3)
      expect(import_run.failure["message"]).to include("no user found with email")
    end
  end

  # The test above never actually exercises the transaction rollback: its failure is caught by
  # Resolver's own attribute-resolution pass (an unknown email), which create_job.rb checks via
  # `rows.flat_map(&:errors).first` *before* the creation loop starts -- so no
  # WorkPackages::CreateService call, and no insert, ever happens for either node. `.not_to
  # change(WorkPackage, :count)` therefore passes vacuously.
  #
  # This context forces a REAL mid-transaction failure instead. Per the design's documented
  # "Known limitation" (parent-dependent contract validations can only be evaluated at creation
  # time, not at preview/resolve time): Resolver never sets `parent_id` while building each row's
  # attributes (see Resolver#resolve_node), so it has no way to know at resolve time whether the
  # importing user is even allowed to set a parent. Only create_job.rb's creation loop passes
  # `parent_id:` into `WorkPackages::CreateService.call`, and `WorkPackages::BaseContract` gates
  # `parent_id` on the `manage_subtasks` permission (app/contracts/work_packages/base_contract.rb).
  #
  # So: give the user every permission the other contexts grant *except* `manage_subtasks`. The
  # root "Objective" row has no parent, so it resolves and is genuinely created and inserted
  # first. Only the second row ("Task"), which the job tries to create with
  # `parent_id: <objective's real id>`, hits CreateService's contract check and genuinely fails --
  # after a real prior insert already happened in the same transaction.
  context "when a later node fails a creation-time-only contract check (no manage_subtasks)" do
    let(:user) do
      create(:user,
             member_with_permissions: { project => %i[view_work_packages add_work_packages assign_versions] })
    end
    let(:source) { <<~MD }
      # Objective: Increase retention

      ## Task: Rework the sequence
    MD

    it "rolls back the already-created parent row too" do
      allow(WorkPackages::CreateService).to receive(:new).and_wrap_original do |method, **kwargs|
        method.call(**kwargs)
      end

      expect { perform_enqueued_jobs { described_class.perform_later(import_run:) } }
        .not_to change(WorkPackage, :count)

      # Proves the failure was genuinely reached inside the creation loop (which calls
      # CreateService once per row), not vacuously short-circuited by Resolver's pre-check
      # (which never calls CreateService at all -- see the sibling context above).
      expect(WorkPackages::CreateService).to have_received(:new).twice

      import_run.reload
      expect(import_run).to be_failed
      # source_line 3 is "## Task: Rework the sequence" -- the SECOND row. If Resolver's own
      # pre-check had caught this, the source_line would still be attributable, but no
      # CreateService call would have happened at all (see "have_received(:new).twice" above) and
      # the "Objective" row would never have reached the database in the first place.
      expect(import_run.failure["source_line"]).to eq(3)
      expect(import_run.failure["message"]).to match(/parent/i)

      # The key assertion: prove the FIRST row (the "Objective" root, which genuinely inserted
      # successfully before the second row's CreateService call failed) was actually rolled back
      # too, not merely that a *second* work package was never created.
      expect(WorkPackage.where(subject: "Increase retention")).not_to exist
    end
  end
end
