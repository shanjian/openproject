# frozen_string_literal: true

# Creates/syncs three membership groups:
#   1. "all_users"      - every real (non-builtin) user in the system
#   2. "system_admins"  - users with the global admin flag (admin: true)
#   3. "project_admins" - users who can administer at least one project,
#                         defined as holding the :manage_members permission
#                         through any project membership (incl. inherited
#                         from a group). This is more robust than matching a
#                         role *named* "Project admin", which can be renamed,
#                         translated, or duplicated.
#
# Idempotent: re-running adds users who are missing and removes users who no
# longer qualify, so it can be scheduled to keep the groups in sync.
#
# Run with:
#   bundle exec rails runner script/create_admin_groups.rb
#
# NOTE: "all_users" includes only ACTIVE accounts (invited, locked, and
# registered-but-unconfirmed users are excluded). To include every status,
# change the all_users query below to `User.not_builtin`.

actor = User.system

# --- Membership definitions -------------------------------------------------

all_user_ids = User.not_builtin.where(status: User.statuses[:active]).pluck(:id)

system_admin_ids = User.not_builtin.where(admin: true).pluck(:id)

project_admin_ids =
  User
    .not_builtin
    .where(
      id: Member
            .where.not(project_id: nil)
            .joins(roles: :role_permissions)
            .where(role_permissions: { permission: "manage_members" })
            .select(:user_id)
    )
    .pluck(:id)

groups = {
  "all_users" => all_user_ids,
  "system_admins" => system_admin_ids,
  "project_admins" => project_admin_ids
}

# --- Sync logic -------------------------------------------------------------

groups.each do |name, desired_ids|
  group = Group.find_by(name: name)

  if group.nil?
    create = Groups::CreateService.new(user: actor).call(name: name)
    unless create.success?
      warn "Failed to create group #{name.inspect}: #{create.errors.full_messages.join(', ')}"
      next
    end
    group = create.result
  end

  before_ids = group.user_ids

  # replace_user_ids = full desired set. UpdateService reconciles both
  # additions (via AddUsersService) and removals (pruning inherited roles),
  # so a single call keeps the group exactly in sync.
  update = Groups::UpdateService.new(model: group, user: actor)
                                .call(replace_user_ids: desired_ids)

  unless update.success?
    warn "  sync failed for #{name}: #{update.errors.full_messages.join(', ')}"
    next
  end

  added   = (desired_ids - before_ids).size
  removed = (before_ids - desired_ids).size
  puts format("%-15s -> %d members (added %d, removed %d)",
              name, desired_ids.size, added, removed)
end

puts "Done."
