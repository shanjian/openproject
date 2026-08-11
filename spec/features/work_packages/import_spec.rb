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

RSpec.describe "Markdown work package import", :js do # rubocop:disable RSpec/MultipleDescribes
  let(:project) { create(:project) }
  let!(:strategic_initiative) { create(:type, name: "Strategic Initiative", projects: [project]) }
  let!(:objective) { create(:type, name: "Objective", projects: [project]) }
  let!(:key_result) { create(:type, name: "Key Result", projects: [project]) }
  let!(:task_type) { create(:type_task, name: "Task", projects: [project]) }
  # The bare `:custom_field` factory builds the abstract STI base class `CustomField`, which has
  # neither `types=` nor `projects=` -- only `WorkPackageCustomField` (built by `:wp_custom_field`)
  # has those HABTM associations. And per Task 6's fix, `available_custom_fields` gates on
  # project-level enablement, not just the type association, so `projects:` must be passed too.
  #
  # `types:` includes `task_type` too, not just `objective`/`key_result`: OutlineParser's
  # `apply_inheritance` (see outline_parser.rb) flows every ancestor attribute down to every
  # descendant node unconditionally, regardless of whether the descendant's type actually
  # supports that custom field -- per the design's documented inheritance rule ("any attribute
  # set on an ancestor, flow downward unless overridden"). Since "Organizational Unit" is set on
  # the Objective and this document nests a Task three levels below it, the field must be
  # resolvable for Task too, or Resolver correctly raises "no field named ... on type Task".
  let!(:organizational_unit_field) do
    create(:wp_custom_field, name: "Organizational Unit", field_format: "department",
                             types: [objective, key_result, task_type], projects: [project])
  end
  let!(:marketing) { create(:group, lastname: "Marketing", organizational_unit: true) }
  # WorkPackages::CreateContract requires an assignable status and priority
  # (WorkPackages::SetAttributesService#set_default_status/#set_default_priority); neither is
  # seeded automatically for a fresh example, so create the "is_default" ones explicitly (see
  # Task 9's create_job_spec.rb for the same requirement at the job level).
  let!(:default_status) { create(:default_status) }
  let!(:default_priority) { create(:default_priority) }

  let(:user) do
    create(:user, member_with_permissions: { project => %i[view_work_packages add_work_packages manage_subtasks
                                                           assign_versions import_work_packages] })
  end

  let(:document) { <<~MD }
    # Strategic Initiative: Subscription Growth

    ## Objective: Increase subscriber retention
    - Organizational Unit: Marketing

    ### Key Result: Increase annual renewals from 65% to 75%

    #### Task: Rework the renewal reminder sequence
  MD

  before { login_as(user) }

  it "previews then creates the full hierarchy" do
    visit new_project_work_packages_import_path(project)
    fill_in "source", with: document
    click_button "Preview"

    expect(page).to have_text("Strategic Initiative")
    expect(page).to have_text("Subscription Growth")
    expect(page).to have_text("Marketing")
    expect(page).to have_no_css(".work-package-import-preview--error")

    perform_enqueued_jobs { click_button "Create work packages" }

    # The `create` action redirects to the show page immediately after enqueueing the job (per
    # imports_controller.rb), so the page rendered by that redirect reflects the run's pre-job
    # status. Reload once the job (run synchronously above by perform_enqueued_jobs) has updated
    # the run's status in the database.
    visit page.current_path
    expect(page).to have_text("Status: succeeded")
    expect(WorkPackage.where(project:).count).to eq(4)

    initiative = WorkPackage.find_by(subject: "Subscription Growth")
    obj = WorkPackage.find_by(subject: "Increase subscriber retention")
    kr = WorkPackage.find_by(subject: "Increase annual renewals from 65% to 75%")
    task = WorkPackage.find_by(subject: "Rework the renewal reminder sequence")

    expect(obj.parent).to eq(initiative)
    expect(kr.parent).to eq(obj)
    expect(task.parent).to eq(kr)
  end

  it "fails to import the same document without manage_subtasks or assign_versions" do
    restricted_user = create(:user,
                             member_with_permissions: { project => %i[view_work_packages add_work_packages
                                                                      import_work_packages] })
    login_as(restricted_user)

    run = create(:work_packages_import_run, project:, user: restricted_user, source: document)
    perform_enqueued_jobs { WorkPackages::Import::CreateJob.perform_later(import_run: run) }
    run.reload

    expect(run).to be_failed
  end
end

RSpec.describe "Preview fidelity", type: :request do
  let(:project) { create(:project) }
  let!(:task_type) { create(:type_task, name: "Task", projects: [project]) }
  let!(:default_status) { create(:default_status) }
  let!(:default_priority) { create(:default_priority) }
  let(:user) do
    create(:user, member_with_permissions: { project => %i[view_work_packages add_work_packages
                                                           manage_subtasks assign_versions import_work_packages] })
  end
  let(:document) { "# Task: Rework the renewal reminder sequence\n" }

  before { login_as(user) }

  it "creates a work package matching the previewed attributes, except computed fields" do
    document_result = WorkPackages::Import::OutlineParser.call(document)
    previewed_row = WorkPackages::Import::Resolver.new(project:, user:).call(document_result.result).result.first

    run = create(:work_packages_import_run, project:, user:, source: document)
    perform_enqueued_jobs { WorkPackages::Import::CreateJob.perform_later(import_run: run) }
    run.reload

    created = WorkPackage.find(run.created_work_package_ids.first)

    expect(created.subject).to eq(previewed_row.work_package.subject)
    expect(created.type_id).to eq(previewed_row.work_package.type_id)
    expect(created.status_id).to eq(previewed_row.work_package.status_id)
    expect(created.priority_id).to eq(previewed_row.work_package.priority_id)
    # derived_done_ratio / derived_estimated_hours / derived_remaining_hours and any
    # type-pattern-driven subject are the only fields expected to differ -- none apply
    # to this plain Task, so every previewed attribute above matches exactly.
  end
end
