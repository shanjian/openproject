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

    # The job declares `updates_own_status? => true` (see JobStatus::ApplicationJobWithStatus),
    # meaning ActiveJob will not auto-write a JobStatus::Status for it -- the job must call
    # `upsert_status` itself. `JobStatusesController#validate_job` later looks the resulting
    # record up scoped to `job_id` *and* `user_id: current_user.id`, so it must be attributed to
    # the importing user, not whatever `User.current` happens to be in the worker thread.
    #
    # Uses `perform_now` (bypassing `perform_later`/`perform_enqueued_jobs`) deliberately:
    # `.perform_later` called from inside RSpec's ambient per-example transaction defers the
    # actual enqueue via Rails' `ActiveJob::EnqueueAfterTransactionCommit` until *a* transaction
    # commits -- which ends up being this job's own `WorkPackage.transaction do` block committing,
    # so the deferred "enqueue.active_job" notification fires again right after the job finishes
    # and resets the JobStatus::Status back to "in_queue", masking the very thing under test. That
    # is a Rails/RSpec transactional-test artifact of any job that both self-enqueues and wraps
    # its own body in a top-level `Model.transaction do` -- unrelated to `upsert_status` itself and
    # not reproducible outside of this specific test setup (a real `perform_later` call from the
    # controller, with no ambient transaction open, enqueues immediately). `perform_now` exercises
    # the same job body without going through `.enqueue` at all, sidestepping the artifact.
    it "records a successful JobStatus::Status scoped to the importing user" do
      # A fresh `find` (rather than the `let`-memoized `import_run`) mirrors what `perform_later`
      # would give the job via GlobalID deserialization -- its `project` association is loaded
      # from scratch, not carrying over any association cache from this example's own setup.
      job = described_class.new(import_run: WorkPackages::ImportRun.find(import_run.id))

      # In production, `ImportsController#create` calls `.perform_later` under `User.current ==
      # <the importing user>` (it's a normal authenticated request), so the very first
      # `upsert_status` call for this job_id (the automatic "in_queue" one fired by
      # OpenProject::JobStatus::EventListener at enqueue time -- see
      # JobStatus::ApplicationJobWithStatus#upsert_status, which only assigns `resource.user` on
      # `new_record?`) already stamps the correct user; later calls, including this job's own,
      # never need to touch `user` again. `perform_now` above skips that enqueue step entirely, so
      # this wrapper reproduces the same "correct `User.current` for the first-ever write" starting
      # condition by hand.
      User.execute_as(user) { job.perform_now }

      status = JobStatus::Status.find_by(job_id: job.job_id)
      expect(status).to be_present
      expect(status).to be_success
      expect(status.user_id).to eq(user.id)
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

    # See the sibling success-path test above for why `perform_now` (wrapped in `User.execute_as`)
    # is used here instead of `perform_later`/`perform_enqueued_jobs`.
    it "records a failed JobStatus::Status scoped to the importing user" do
      job = described_class.new(import_run: WorkPackages::ImportRun.find(import_run.id))
      User.execute_as(user) { job.perform_now }

      status = JobStatus::Status.find_by(job_id: job.job_id)
      expect(status).to be_present
      expect(status).to be_failure
      expect(status.user_id).to eq(user.id)
      expect(status.message).to include("no user found with email")
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

  # `create_tree!` only ever raises `CreationFailed` deliberately -- for the four enumerated,
  # expected failure kinds (parse, resolve, per-row resolver error, CreateService failure). A
  # genuinely unexpected exception (a real bug, a DB blip, anything else) previously had no
  # rescue clause of its own: it would still roll back the transaction (any exception does that
  # regardless of class), but `import_run.status` would never be touched, leaving the run stuck
  # at "running" forever -- the feature's own `show` page would tell the user their import is
  # still in progress indefinitely, with no record of what went wrong.
  context "when an unexpected, non-CreationFailed error occurs" do
    let(:source) { "# Task: Rework the sequence\n" }

    it "marks the run failed with the error's message and still re-raises" do
      # perform_now (wrapped in User.execute_as), not perform_later/perform_enqueued_jobs -- same
      # reason as the sibling JobStatus test below: propagating a real exception back out through
      # the test adapter's own enqueue/perform machinery hits unrelated logging setup this spec
      # doesn't otherwise need, whereas perform_now exercises the job's own rescue/re-raise
      # directly.
      allow(WorkPackages::Import::OutlineParser).to receive(:call).and_raise(RuntimeError, "boom")

      job = described_class.new(import_run: WorkPackages::ImportRun.find(import_run.id))
      expect { User.execute_as(user) { job.perform_now } }.to raise_error(RuntimeError, "boom")

      import_run.reload
      expect(import_run).to be_failed
      expect(import_run.failure["message"]).to eq("boom")
    end

    it "records a failed JobStatus::Status scoped to the importing user" do
      allow(WorkPackages::Import::OutlineParser).to receive(:call).and_raise(RuntimeError, "boom")

      job = described_class.new(import_run: WorkPackages::ImportRun.find(import_run.id))
      expect { User.execute_as(user) { job.perform_now } }.to raise_error(RuntimeError, "boom")

      status = JobStatus::Status.find_by(job_id: job.job_id)
      expect(status).to be_present
      expect(status).to be_failure
      expect(status.user_id).to eq(user.id)
      expect(status.message).to eq("boom")
    end
  end
end
