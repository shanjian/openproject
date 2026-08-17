# Creates the public saved views recommended by
# docs/customization/Department and Team OKR Process.md ("Executive Review" section)
# in the Company OKRs project.
#
# Usage (RPM/packaged install, no Docker):
#   sudo OKR_VERSION="2026 Q3" openproject run bundle exec rails runner scripts/create_okr_saved_views.rb
#
# (env vars set on the sudo command line this way reach the sudo'd process even though
# sudo does not forward the calling shell's environment by default)
#
# Or paste the body into an interactive console (set ENV["OKR_VERSION"] first):
#   sudo openproject run bundle exec rails console
#
# Safe to re-run: an existing public view with the same name has its filters/columns
# updated in place rather than being skipped, so column/filter edits here take effect
# on a re-run. Re-run it:
#   - every quarter, with the new quarter's OKR_VERSION - views are pinned to whichever
#     Version name they were last generated with and do not follow a rollover on their own
#   - whenever a department or team is added, removed, or reparented - the Department/Team
#     Objectives views below match specific Group ids captured at generation time, so a
#     hierarchy change is invisible to them until the script runs again
#
# Runs as the System user throughout. Query.available_columns / custom-field visibility
# checks (on_visible_type_and_project) filter through Project.visible(User.current), and
# `rails runner` otherwise defaults User.current to anonymous - which cannot see the
# project, making every custom field wrongly look "not displayable". System is an admin
# account, so Project.visible takes admins' fast-path (sees everything).

PROJECT_IDENTIFIER = "company-okrs"

# No hardcoded default: a stale fallback here would let a re-run after quarter rollover
# silently keep targeting the closed quarter instead of failing loudly.
VERSION_NAME = ENV.fetch("OKR_VERSION") do
  raise "Set OKR_VERSION to the quarter these views should target, e.g.:\n  " \
        'OKR_VERSION="2026 Q4" sudo openproject run bundle exec rails runner scripts/create_okr_saved_views.rb'
end

User.current = User.system

project = Project.find_by!(identifier: PROJECT_IDENTIFIER)
version = Version.find_by!(project:, name: VERSION_NAME)

objective_type = Type.find_by!(name: "Objective")
key_result_type = Type.find_by!(name: "Key Result")

# "Company" is the actual root of the Department hierarchy (Group.organizational_units
# is the "Department" custom-field-format scope), with departments like Marketing/
# Editorial/Technology as its direct children and teams as their direct children in turn.
# Looked up by name, same as the cf() custom-field lookups below, since these Groups are
# all created by hand in the Admin UI - there's no seeder/migration guaranteeing an id.
company = Group.organizational_units.find_by(name: "Company") or
  raise "Department 'Company' not found - it must be the root of the Department hierarchy"
departments = company.children.order(:lastname)

# Custom fields are looked up by name, scoped to WorkPackageCustomField so a
# same-named field on another customized class (Group/Project/User/Version/...)
# is never picked up by mistake. Looked up so this script works regardless of IDs.
# Fields that may not exist yet (per the earlier form-config review) are looked up
# with find_by (not find_by!) and simply omitted from columns/filters if missing.
def cf(name)
  WorkPackageCustomField.find_by(name:)
end

org_unit_cf     = cf("Organization Unit")   or raise "Custom field 'Organization Unit' not found"
okr_health_cf   = cf("OKR Health")          or raise "Custom field 'OKR Health' not found"
confidence_cf   = cf("Confidence")
baseline_cf     = cf("Baseline")
# "Target Metric" is a fallback for older setups; the docs (Required Fields, Executive
# Review recommended columns) consistently name this field "Target".
target_cf       = cf("Target") || cf("Target Metric")
current_cf      = cf("Current Metric")
progress_cf     = cf("Progress %") || cf("Progress")
checkin_cf      = cf("Last Check-in")

# "Accountable" is the built-in `responsible` work package attribute, renamed at
# the locale level (config/locales/en.yml: `responsible: "Accountable"`) - not a
# custom field, so it needs no lookup and is always a valid column/filter.
ACCOUNTABLE_COLUMN = :responsible

named_cfs = { "Organization Unit" => org_unit_cf, "OKR Health" => okr_health_cf,
              "Confidence" => confidence_cf, "Baseline" => baseline_cf, "Target" => target_cf,
              "Current Metric" => current_cf, "Progress %" => progress_cf, "Last Check-in" => checkin_cf }

missing = named_cfs.select { |_, v| v.nil? }.keys
puts "Note: these custom fields were not found and will be skipped in columns: #{missing.join(', ')}" if missing.any?

# Pre-flight: a WorkPackageCustomField found by name can still be an invalid query
# column if it isn't mapped to any type/project the way the form config implies.
# Surface that now, with a clear name, instead of failing deep inside Query.create!.
available_column_names = Query.available_columns(project).map { |c| c.name.to_sym }

# Returns the column name only if it is actually usable, else nil (so `.compact`
# on a columns array drops it) - keeps a bad/unavailable field from failing the
# whole view instead of just quietly not showing that one column.
safe_col = lambda do |field|
  return nil if field.nil?

  col = field.column_name.to_sym
  unless available_column_names.include?(col)
    puts "WARNING: '#{field.name}' (#{col}) is not a displayable column for project " \
         "'#{project.identifier}' - it will be dropped from any view that references it. " \
         "Check it's added to the project and to the relevant work package type(s)."
    return nil
  end
  field.column_name
end

def create_public_view!(project:, name:, filters:, columns:, failures:, sort_criteria: nil, group_by: nil)
  # Filter hash keys must be symbols (Queries::WorkPackages::FilterSerializer /
  # the filter registry look them up as symbols; string keys are silently ignored).
  symbolized_filters = filters.transform_keys { |k| k.to_s.to_sym }

  attrs = {
    public: true,
    include_subprojects: false,
    filters: [symbolized_filters],
    column_names: columns.compact.map(&:to_s),
    sort_criteria: sort_criteria || [["id", "asc"]],
    group_by:,
    # Matches the default "All open" view (Query.new_default sets this explicitly);
    # mutually exclusive with group_by (Query#validate_show_hierarchies), so only
    # turn it on when this view isn't grouped.
    show_hierarchies: group_by.nil?
  }

  query = Query.find_by(project:, name:, public: true)
  if query
    query.update!(attrs)
    action = "Updated"
  else
    query = Query.create!(attrs.merge(project:, name:, user: User.system))
    action = "Created"
  end

  View.find_or_create_by!(type: "work_packages_table", query:)
  puts "#{action}: #{name}"
rescue StandardError => e
  failures << name
  puts "FAILED: #{name} (#{e.class}: #{e.message})"
end

# Shared across every create_public_view! call below so a failure partway through still
# lets the remaining views attempt to create/update, while the exit status at the end
# still reflects that the setup is incomplete instead of reading as a clean run.
view_failures = []

# --- Company Objectives ----------------------------------------------------
# Items owned directly by Company rather than delegated to a department - an exact
# match on the Organization Unit field, same mechanism as the Department/Team views
# below. No separate "OKR Level" field needed: the tree position already says this.
create_public_view!(
  project:,
  failures: view_failures,
  name: "Company Objectives",
  filters: {
    type_id: { operator: "=", values: [objective_type.id.to_s] },
    org_unit_cf.column_name.to_sym => { operator: "=", values: [company.id.to_s] },
    version_id: { operator: "=", values: [version.id.to_s] }
  },
  columns: [safe_col.call(org_unit_cf), :subject, :id, :status, ACCOUNTABLE_COLUMN,
            safe_col.call(confidence_cf), safe_col.call(okr_health_cf)]
)

# --- Department Objectives & Team Objectives (one pair of views per department) ----
# Department Objectives: exact match on that department - items owned directly by
# e.g. Marketing rather than by one of its teams.
# Team Objectives: "is (any of)" match across the department's direct children - every
# team under it, without hardcoding team ids or falling back to unreliable manual tagging.
if departments.none?
  puts "No departments found under Company - skipping Department/Team Objectives views"
end

departments.each do |department|
  create_public_view!(
    project:,
    failures: view_failures,
    name: "Department Objectives - #{department.name}",
    filters: {
      type_id: { operator: "=", values: [objective_type.id.to_s] },
      org_unit_cf.column_name.to_sym => { operator: "=", values: [department.id.to_s] },
      version_id: { operator: "=", values: [version.id.to_s] }
    },
    columns: [safe_col.call(org_unit_cf), :subject, :id, :status, ACCOUNTABLE_COLUMN,
              safe_col.call(confidence_cf), safe_col.call(okr_health_cf)]
  )

  team_ids = department.children.order(:lastname).pluck(:id)
  if team_ids.empty?
    puts "Skipped 'Team Objectives - #{department.name}': no teams found under this department"
    next
  end

  create_public_view!(
    project:,
    failures: view_failures,
    name: "Team Objectives - #{department.name}",
    filters: {
      type_id: { operator: "=", values: [objective_type.id.to_s] },
      org_unit_cf.column_name.to_sym => { operator: "=", values: team_ids.map(&:to_s) },
      version_id: { operator: "=", values: [version.id.to_s] }
    },
    columns: [safe_col.call(org_unit_cf), :subject, :id, :status, ACCOUNTABLE_COLUMN,
              safe_col.call(confidence_cf), safe_col.call(okr_health_cf)]
  )
end

# --- Key Results (recommended columns per the docs) -----------------------
create_public_view!(
  project:,
  failures: view_failures,
  name: "Key Results",
  filters: {
    type_id: { operator: "=", values: [key_result_type.id.to_s] },
    version_id: { operator: "=", values: [version.id.to_s] }
  },
  columns: [safe_col.call(org_unit_cf), :subject, :id, ACCOUNTABLE_COLUMN,
            safe_col.call(baseline_cf), safe_col.call(target_cf), safe_col.call(current_cf),
            safe_col.call(progress_cf), safe_col.call(confidence_cf), safe_col.call(okr_health_cf),
            safe_col.call(checkin_cf)]
)

# --- At-Risk OKRs -----------------------------------------------------------
at_risk_option_ids = okr_health_cf.custom_options.where(value: ["At Risk", "Off Track"]).pluck(:id)
if at_risk_option_ids.size == 2
  create_public_view!(
    project:,
    failures: view_failures,
    name: "At-Risk OKRs",
    filters: {
      version_id: { operator: "=", values: [version.id.to_s] },
      okr_health_cf.column_name.to_sym => { operator: "=", values: at_risk_option_ids.map(&:to_s) }
    },
    columns: [safe_col.call(org_unit_cf), :subject, :id, :type, ACCOUNTABLE_COLUMN,
              safe_col.call(okr_health_cf)]
  )
else
  found = okr_health_cf.custom_options.where(value: ["At Risk", "Off Track"]).pluck(:value)
  puts "Skipped 'At-Risk OKRs': expected OKR Health options 'At Risk' and 'Off Track', found #{found.inspect}"
end

if view_failures.any?
  # abort (not just a nonzero `exit`) also prints to stderr, so this surfaces in cron/CI
  # logs even if stdout is swallowed - a partial setup must not look like a clean run.
  abort "Done with failures: #{view_failures.join(', ')} - see the FAILED lines above"
else
  puts "Done."
end
