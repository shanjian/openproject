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
end
