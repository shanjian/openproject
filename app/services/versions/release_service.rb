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

module Versions
  # Releases a version of kind "release": handles its incomplete (open) work packages
  # according to the chosen strategy, then marks the release as closed (= released).
  #
  # Incomplete work packages are those linked to the release through its Release custom
  # field whose status is not closed. Strategies:
  #   * "roll_forward" - move them to another open release (+target_version+)
  #   * "decouple"     - clear the release link, returning them to the backlog
  #   * "force"        - leave them linked to the now-closed release
  class ReleaseService
    STRATEGIES = %w[roll_forward decouple force].freeze

    def initialize(user:, version:)
      @user = user
      @version = version
    end

    # @param strategy [String] one of STRATEGIES
    # @param target_version [Version, nil] required for "roll_forward"
    def call(strategy:, target_version: nil)
      strategy = strategy.to_s
      if (message = validation_error(strategy, target_version))
        return ServiceResult.failure(message:)
      end

      ApplicationRecord.transaction do
        apply_strategy(strategy, target_version)
        @version.update!(status: "closed")
      end

      ServiceResult.success(result: @version)
    rescue ActiveRecord::RecordInvalid => e
      ServiceResult.failure(message: e.message)
    end

    # Validates the parameters without performing the release. Returns an error message
    # or nil. Lets callers (e.g. the controller) give immediate feedback before deciding
    # to run the release synchronously or in a background job.
    def validate(strategy:, target_version: nil)
      validation_error(strategy.to_s, target_version)
    end

    private

    def validation_error(strategy, target_version)
      return I18n.t("versions.release.errors.unauthorized") unless @user.allowed_in_project?(:manage_versions, @version.project)
      return I18n.t("versions.release.errors.not_a_release") unless @version.release?
      return I18n.t("versions.release.errors.not_open") unless @version.open?
      return I18n.t("versions.release.errors.invalid_strategy") unless STRATEGIES.include?(strategy)

      validate_target(target_version) if strategy == "roll_forward"
    end

    def validate_target(target_version)
      return I18n.t("versions.release.errors.target_required") if target_version.nil?

      unless valid_target?(target_version)
        I18n.t("versions.release.errors.invalid_target")
      end
    end

    # The target must be a different, open release that is actually available to this
    # release's project (the same set offered in the confirmation screen). This stops a
    # user from rolling work packages forward onto an unrelated project's version by id.
    def valid_target?(target_version)
      target_version.is_a?(Version) &&
        target_version.id != @version.id &&
        allowed_target_versions.exists?(id: target_version.id)
    end

    def allowed_target_versions
      @version.project.shared_versions.releases.with_status_open
    end

    def apply_strategy(strategy, target_version)
      return if strategy == "force"

      # Save through each work package so the Release custom field change is validated
      # and journaled (visible in the work package history), rather than rewriting
      # custom_values in bulk which would skip validations, callbacks and journals.
      affected_work_packages.find_each do |work_package|
        rewrite_release_links(work_package, strategy, target_version)
      end
    end

    # Only work packages the acting user can see are affected, matching the confirmation
    # screen and avoiding mutating work packages in other projects the user cannot access
    # (e.g. for a shared/system release).
    def affected_work_packages
      @version.release_work_packages.visible(@user).merge(WorkPackage.with_status_open)
    end

    def rewrite_release_links(work_package, strategy, target_version)
      changes = release_link_changes(work_package, strategy, target_version)
      return if changes.empty?

      work_package.custom_field_values = changes
      # Skip validations: we only set a valid Release custom field value, and an unrelated
      # validation failure on a work package must not make the release un-releasable. The
      # change is still journaled (journaling runs on save regardless of validation).
      work_package.save(validate: false) # rubocop:disable Rails/SaveBang
    end

    # New Release custom field values per field for a work package, dropping this
    # release and (for roll_forward) adding the target.
    def release_link_changes(work_package, strategy, target_version)
      release_custom_fields.each_with_object({}) do |custom_field, changes|
        current = current_release_values(work_package, custom_field)
        next unless current.include?(version_id_str)

        remaining = current - [version_id_str]
        changes[custom_field.id] = strategy == "roll_forward" ? (remaining + [target_version.id.to_s]).uniq : remaining
      end
    end

    def current_release_values(work_package, custom_field)
      CustomValue.where(customized: work_package, custom_field_id: custom_field.id).pluck(:value)
    end

    def release_custom_fields
      @release_custom_fields ||=
        WorkPackageCustomField.where(field_format: "version", version_kind: "release")
    end

    def version_id_str
      @version_id_str ||= @version.id.to_s
    end
  end
end
