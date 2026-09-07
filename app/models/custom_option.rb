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

##
# A custom option is a possible value for a given custom field
# which is restricted to a set of specific values.
class CustomOption < ApplicationRecord
  belongs_to :custom_field, touch: true
  # NULL project_id means a system-level option, which is what every option is today.
  belongs_to :project, optional: true

  validates :value, presence: true, length: { maximum: 255 }

  validate :validate_value_unique_within_tier
  validate :validate_does_not_shadow_system_option
  validate :validate_value_matches_option_pattern
  validate :validate_field_allows_project_values
  validate :validate_project_prefix
  validate :validate_default_is_system_level

  before_validation :acquire_write_locks, on: %i[create update]
  before_destroy :assure_at_least_one_option

  # Serialises writes per field so the cross-tier shadowing check cannot race.
  #
  # That rule has no database backstop: the two partial unique indexes cover system-vs-system
  # and project-vs-project, and the cross-tier case spans both - a single index would also
  # forbid two projects owning same-named labels, which is legitimate. Model validations are
  # not atomic, so two concurrent writes can both pass.
  #
  # It lives here rather than in a service because there is more than one writer: the
  # project-admin services, the system-admin path saving custom_options_attributes as nested
  # attributes on the field, promotion during project deletion, and seeds. Guarding one of
  # them leaves the race open for the rest.
  #
  # before_validation, not around_save: ActiveRecord wraps validation and the write in one
  # transaction, so acquiring the lock here holds it across the check AND the insert. From
  # around_save it would be taken after validation, which is the wrong side of the race.
  CROSS_TIER_LOCK_NAMESPACE = 8_314_201

  scope :system_level, -> { where(project_id: nil) }

  # The set a project may APPLY. Ownership decides it: a project's own labels plus the
  # system ones everybody shares. This is the single definition - the picker, the contract
  # validation and the copy filter all read it, so they cannot drift apart.
  scope :applicable_in, ->(project) { where(project_id: [nil, project&.id]) }

  def to_s
    value
  end

  alias :name :to_s

  def system_level? = project_id.nil?

  # ONE global lock order: project row, then field advisory lock. Never the reverse.
  #
  # The prefix-change path necessarily takes the project row first - it saves the project,
  # then saves each renamed label, which reaches this method. Taking the field lock first
  # here produced a field -> project versus project -> field cycle. Ordering both paths the
  # same way removes the cycle rather than retrying around it.
  def acquire_write_locks
    return unless value_check_needed?

    lock_owning_project
    return unless acquire_cross_tier_lock?

    # Read committed field state, but only when a lock was actually taken. Reloading the
    # association unconditionally replaces the in-memory field and costs it its `touch: true`
    # on save, so every ordinary option edit would stop invalidating the field's caches.
    association(:custom_field).reload
  end

  # Not gated on the flag: the prefix rule applies to every project-owned option, so the
  # committed prefix must be read whatever the field's configuration.
  #
  # The field lock serialises label writes against each other, but not against a PREFIX
  # change, which writes a different table. Locking the project row makes the two serialise:
  # this blocks while a prefix change is in flight and then re-reads the committed value,
  # and a prefix change blocks on the same row while a label is being written.
  def lock_owning_project
    return if project_id.nil?

    association(:project).reload
    project&.lock!
  end

  # Taken for any project-owned option, and for any option on a field that currently allows
  # them. The first case matters even when the in-memory field says the flag is off: that
  # read may be stale, and CustomField's disable check takes this same lock, so both sides
  # serialise. Returns whether it was taken.
  def acquire_cross_tier_lock?
    return false unless project_id.present? || custom_field&.allow_project_values?

    self.class.connection.execute(
      "SELECT pg_advisory_xact_lock(#{CROSS_TIER_LOCK_NAMESPACE}, #{custom_field_id.to_i})"
    )
    true
  end

  protected

  # Validated only on create and when the value changes, so pre-existing duplicates - which
  # are possible, since nothing enforced uniqueness before - never block an unrelated save.
  def value_check_needed?
    value.present? && (new_record? || value_changed?)
  end

  def validate_value_unique_within_tier
    return unless value_check_needed?

    duplicate = CustomOption
                  .where(custom_field_id:, project_id:)
                  .where.not(id:)
                  .where("LOWER(value) = ?", value.downcase)

    errors.add(:value, :taken) if duplicate.exists?
  end

  # A project label may not take the name of a system label: two same-named labels resolving
  # differently by project would defeat the point of a shared taxonomy. Postgres cannot
  # express this as a unique index, because it spans both tiers.
  # Cross-tier collisions are blocked in BOTH directions. Checking only one leaves the
  # symmetric case open: an admin creating or renaming a system label onto an existing
  # project label produces exactly the ambiguity the rule exists to prevent, and no unique
  # index can catch it - the case spans both tiers.
  def validate_does_not_shadow_system_option
    return unless value_check_needed?

    if system_level?
      errors.add(:value, :shadowed_by_project_label) if colliding_options(:project_level).exists?
    elsif colliding_options(:system_level).exists?
      errors.add(:value, :shadows_system_label)
    end
  end

  def colliding_options(tier)
    scope = CustomOption.where(custom_field_id:).where.not(id:)
    scope = tier == :system_level ? scope.system_level : scope.where.not(project_id: nil)

    scope.where("LOWER(value) = ?", value.downcase)
  end

  def validate_value_matches_option_pattern
    return unless value_check_needed?

    pattern = custom_field&.option_pattern
    return if pattern.blank?

    return if Regexp.new(pattern, timeout: 1).match?(value)

    add_pattern_mismatch_error
  rescue RegexpError
    # The pattern is validated where it is entered; an invalid one must not make every
    # label unsaveable with an error pointing at the label.
    Rails.logger.error("CustomField ##{custom_field_id} has an invalid option_pattern")
  end

  # option_pattern_description exists precisely so a user is not shown a regular expression.
  # Fall back to the generic message only when an admin left it blank.
  def add_pattern_mismatch_error
    description = custom_field.option_pattern_description

    if description.present?
      errors.add(:value, :does_not_match_pattern, description:)
    else
      errors.add(:value, :invalid)
    end
  end

  # Reads the field state reloaded under the lock, so a writer that loaded the field while
  # project values were enabled cannot insert an owned option after an admin has committed
  # disabling them.
  def validate_field_allows_project_values
    return if system_level?
    return unless value_check_needed?
    return if custom_field&.allow_project_values?

    errors.add(:base, :field_does_not_allow_project_values)
  end

  # A project label must carry its own project's prefix. A project with no prefix cannot own
  # labels at all - that is what makes the prefix a prerequisite rather than a suggestion.
  def validate_project_prefix
    return if system_level?
    return unless value_check_needed?

    prefix = project&.label_prefix
    return errors.add(:base, :project_has_no_label_prefix) if prefix.blank?
    return errors.add(:value, :must_carry_project_prefix, prefix:) unless LabelNaming.prefixed_with?(value, prefix)

    # The structural rule, independent of the admin-supplied option_pattern. Without it a
    # permissive pattern - or none at all - would accept "AT-" or "AT-lower".
    errors.add(:value, :invalid_label_format) unless LabelNaming::LABEL_FORMAT.match?(value)
  end

  # A default is applied in every project, so a project-owned option must never be one:
  # it would assign an inapplicable label everywhere, or fail work package creation.
  def validate_default_is_system_level
    return if system_level? || !default_value?

    errors.add(:default_value, :only_system_labels)
  end

  def assure_at_least_one_option
    return if CustomOption.where(custom_field_id:).where.not(id:).count > 0

    errors.add(:base, I18n.t(:"activerecord.errors.models.custom_field.at_least_one_custom_option"))

    throw :abort
  end
end
