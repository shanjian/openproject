# frozen_string_literal: true

class RelaxGroupLastnameUniqueness < ActiveRecord::Migration[8.1]
  # unique_lastname_for_groups_and_placeholder_users predates the Department feature and
  # enforces a *global* unique (lastname, type) for both Group and PlaceholderUser. That
  # contradicts Group#uniqueness_of_name, which deliberately scopes organizational units to
  # their siblings only (LDAP directories routinely repeat the same OU name on different
  # branches, e.g. "Support" under both IT and HR) - so two departments with the same name
  # under different parents currently fail at the DB layer before Ruby validation ever runs.
  #
  # Removes Group from the DB-level constraint entirely; PlaceholderUser keeps its existing
  # global uniqueness. Group name uniqueness (global for regular groups, sibling-scoped for
  # departments) is enforced purely at the application level from here on, matching upstream's
  # own resolution of this (relax_group_lastname_uniqueness).
  def up
    remove_index :users, name: "unique_lastname_for_groups_and_placeholder_users"
    add_index :users, %i[lastname type],
              unique: true,
              where: "type = 'PlaceholderUser'",
              name: "unique_lastname_for_groups_and_placeholder_users"
  end

  def down
    remove_index :users, name: "unique_lastname_for_groups_and_placeholder_users"
    add_index :users, %i[lastname type],
              unique: true,
              where: "type IN ('Group', 'PlaceholderUser')",
              name: "unique_lastname_for_groups_and_placeholder_users"
  end
end
