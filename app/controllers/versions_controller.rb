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

class VersionsController < ApplicationController
  menu_item :roadmap, only: %i(index show)
  menu_item :settings_versions

  before_action :find_version, except: %i[index new create close_completed]
  before_action :find_project, only: %i[index new create close_completed]
  before_action :authorize

  def index
    @types = @project.types.order(Arel.sql("position"))
    retrieve_selected_type_ids(@types, @types.select(&:is_in_roadmap?))
    @with_subprojects = params[:with_subprojects].nil? ? Setting.display_subprojects_work_packages? : (params[:with_subprojects].to_i == 1)
    project_ids = @with_subprojects ? @project.self_and_descendants.includes(:wiki).map(&:id) : [@project.id]

    @versions = find_versions(@with_subprojects, params[:completed])

    @wps_by_version = {}
    unless @selected_type_ids.empty?
      @versions.each do |version|
        @wps_by_version[version] = work_packages_of_version(version, project_ids, @selected_type_ids)
      end
    end
    @versions.reject! { |version| !project_ids.include?(version.project_id) && @wps_by_version[version].blank? }
  end

  # Cap on how many release work packages the hub renders inline; a "view all"
  # link to the full filtered work package view is shown when there are more.
  RELEASE_ISSUES_DISPLAY_LIMIT = 50

  # Above this many incomplete work packages, the release is processed in a background
  # job so the web request is not blocked.
  RELEASE_ASYNC_THRESHOLD = 100

  def show
    if @version.release?
      show_release_hub
    else
      @issues = @version.work_packages.visible
        .includes(:status, :type, :priority)
        .order("#{::Type.table_name}.position, #{WorkPackage.table_name}.id")
    end
  end

  def new
    @version = @project.versions.build(kind: new_version_kind)
  end

  def edit; end

  def create
    attributes = permitted_params
      .version
      .merge(project_id: @project.id)

    call = Versions::CreateService
      .new(user: current_user)
      .call(attributes)

    render_cu(call, :notice_successful_create, "new")
  end

  def update
    attributes = permitted_params
      .version

    call = Versions::UpdateService
      .new(user: current_user,
           model: @version)
      .call(attributes)

    render_cu(call, :notice_successful_update, "edit")
  end

  def close_completed
    @project.close_completed_versions
    redirect_to project_settings_versions_path(@project), status: :see_other
  end

  # Confirmation screen for releasing a release: shows incomplete work packages and
  # lets the user choose how to handle them before the release is closed.
  def confirm_release
    return redirect_to version_path(@version) unless @version.release? && @version.open?

    @incomplete_work_packages = incomplete_release_work_packages
    @target_versions = open_release_targets
  end

  def release
    service = Versions::ReleaseService.new(user: current_user, version: @version)
    error = service.validate(strategy: params[:strategy], target_version: release_target_version)

    if error
      flash[:error] = error
    elsif large_release?
      enqueue_release_job
      flash[:notice] = t(".processing")
    else
      perform_release(service)
    end

    redirect_to version_path(@version), status: :see_other
  end

  # Writes the generated release notes to the release's linked wiki page. The wiki
  # services enforce :edit_wiki_pages, so this does not bypass wiki permissions.
  def write_release_notes
    unless @version.release? && @version.wiki_page_title.present? && @project.wiki
      return redirect_to version_path(@version)
    end

    set_release_notes_flash(persist_release_notes_to_wiki)
    redirect_to version_path(@version), status: :see_other
  end

  def destroy
    call = Versions::DeleteService
      .new(user: current_user,
           model: @version)
      .call

    set_destroy_error_flash(call) unless call.success?

    redirect_to helpers.version_settings_path(@version), status: :see_other
  end

  private

  # Builds the release hub data: readiness counts via SQL aggregates (so large
  # releases don't materialize the whole relation) and a capped list of issues.
  def show_release_hub
    base = @version.release_work_packages.visible

    @issues_total_count = base.count
    @issues_closed_count = base.joins(:status).where(statuses: { is_closed: true }).count
    @issues = base
      .includes(:status, :type, :priority)
      .order("#{::Type.table_name}.position, #{WorkPackage.table_name}.id")
      .limit(RELEASE_ISSUES_DISPLAY_LIMIT)

    @release_notes = Versions::ReleaseNotes.new(@version)
  end

  # The kind a freshly built version should get. Defaults to "sprint" so the existing
  # version/roadmap screens keep creating sprints; the Releases screen passes "release".
  def new_version_kind
    params[:kind].presence_in(Version::VERSION_KINDS) || "sprint"
  end

  def release_target_version
    Version.find_by(id: params[:target_version_id]) if params[:target_version_id].present?
  end

  def perform_release(service)
    result = service.call(strategy: params[:strategy], target_version: release_target_version)

    if result.success?
      flash[:notice] = t("versions.release.success")
    else
      flash[:error] = result.message
    end
  end

  def enqueue_release_job
    Versions::ReleaseJob.perform_later(
      version_id: @version.id,
      user_id: current_user.id,
      strategy: params[:strategy],
      target_version_id: params[:target_version_id]
    )
  end

  def large_release?
    @version.release_work_packages
      .visible(current_user)
      .merge(WorkPackage.with_status_open)
      .limit(RELEASE_ASYNC_THRESHOLD + 1)
      .count > RELEASE_ASYNC_THRESHOLD
  end

  def persist_release_notes_to_wiki
    notes = Versions::ReleaseNotes.new(@version)
    page = @project.wiki.find_page(@version.wiki_page_title)

    if page
      # Merge into the existing page so other content (and other releases' notes) is kept.
      WikiPages::UpdateService.new(user: current_user, model: page)
        .call(text: notes.merge_into(page.text))
    else
      WikiPages::CreateService.new(user: current_user)
        .call(wiki: @project.wiki, title: @version.wiki_page_title, text: notes.to_markdown)
    end
  end

  def set_release_notes_flash(call)
    if call.success?
      flash[:notice] = t("versions.release_notes.written", page: @version.wiki_page_title)
    else
      flash[:error] = call.errors.full_messages.presence || t("versions.release_notes.write_failed")
    end
  end

  def incomplete_release_work_packages
    @version.release_work_packages
      .visible(current_user)
      .merge(WorkPackage.with_status_open)
      .includes(:status, :type)
      .order("#{::Type.table_name}.position, #{WorkPackage.table_name}.id")
  end

  def open_release_targets
    @project.shared_versions.releases.with_status_open.where.not(id: @version.id).order(name: :desc)
  end

  def set_destroy_error_flash(call)
    flash[:error] = call.errors.full_messages
    flash[:error] << archived_project_mesage if archived_projects.any?
  end

  def find_version
    @version = Version.visible.find(params[:id])
    @project = @version.project
  end

  def archived_project_mesage
    if current_user.admin?
      ApplicationController.helpers.sanitize(
        t(:error_can_not_delete_in_use_archived_work_packages,
          archived_projects_urls: helpers.archived_projects_urls_for(archived_projects)),
        attributes: %w(href target)
      )
    else
      t(:error_can_not_delete_in_use_archived_undisclosed)
    end
  end

  def archived_projects
    @archived_projects ||= @version.projects.archived
  end

  def redirect_back_or_version_settings
    redirect_back_or_default(helpers.version_settings_path(@version))
  end

  def find_project
    @project = Project.visible.find(params[:project_id])
  end

  def retrieve_selected_type_ids(selectable_types, default_types = nil)
    @selected_type_ids = selected_type_ids selectable_types, default_types
  end

  def selected_type_ids(selectable_types, default_types = nil)
    if (ids = params[:type_ids])
      ids.is_a?(Array) ? ids.map(&:to_s) : ids.split("/")
    else
      (default_types || selectable_types).map { |t| t.id.to_s }
    end
  end

  def render_cu(call, success_message, failure_action)
    @version = call.result

    if call.success?
      flash[:notice] = t(success_message)
      redirect_back_or_version_settings
    else
      render action: failure_action, status: :unprocessable_entity
    end
  end

  def find_versions(subprojects, completed)
    # The roadmap lists the Sprint selection set; releases have their own screen.
    versions = @project.shared_versions.sprints.includes(:custom_values)

    if subprojects
      versions = versions.or(@project.rolled_up_versions.sprints.includes(:custom_values))
    end

    versions = versions.visible.order(name: :desc).except(:distinct).uniq
    versions.reject! { |version| version.closed? || version.completed? } unless completed
    versions
  end

  def work_packages_of_version(version, project_ids, selected_type_ids)
    version
      .work_packages
      .visible
      .includes(:project, :status, :type, :priority)
      .where(type_id: selected_type_ids, project_id: project_ids)
      .order("#{Project.table_name}.lft, #{::Type.table_name}.position, #{WorkPackage.table_name}.id")
  end
end
