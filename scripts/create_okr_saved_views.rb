# frozen_string_literal: true

# Creates the public saved views recommended by
# docs/customization/Department and Team OKR Process.md ("Executive Review" section)
# in the Company OKRs project.
#
# Usage (RPM/packaged install, no Docker):
#   OKR_VERSION="2026 Q3" sudo -E openproject run bundle exec rails runner scripts/create_okr_saved_views.rb
#
# Or paste the body into an interactive console (after setting ENV["OKR_VERSION"]):
#   sudo openproject run bundle exec rails console
#
# Safe to re-run for the SAME quarter: an existing public view with the same name has its
# filters/columns updated in place rather than being skipped, so column/filter edits here
# take effect on a re-run. Re-running for a NEW quarter requires only a new OKR_VERSION -
# the same view names are reused and repointed at the new Version.
#
# Runs as the System user throughout. Query.available_columns / custom-field visibility
# checks (on_visible_type_and_project) filter through Project.visible(User.current), and
# `rails runner` otherwise defaults User.current to anonymous - which cannot see the
# project, making every custom field wrongly look "not displayable". System is an admin
# account, so Project.visible takes admins' fast-path (sees everything).

PROJECT_IDENTIFIER = "company-okrs"
VERSION_NAME = ENV.fetch("OKR_VERSION") do
  raise "Set OKR_VERSION to the target Version name, e.g. OKR_VERSION=\"2026 Q3\""
end

User.current = User.system

project = Project.find_by!(identifier: PROJECT_IDENTIFIER)
version = Version.find_by!(project:, name: VERSION_NAME)

objective_type = Type.find_by!(name: "Objective")
key_result_type = Type.find_by!(name: "Key Result")

# Departments = Organizational Units at the top of the Department hierarchy
# (Group.organizational_units is the "Department" custom-field-format scope;
# top-level = no parent group, matching the flat department examples in the docs).
# Group's `parent` lives on the separate group_details table (has_details_table),
# not as a plain column on Group/users, hence where_detail instead of where.
departments = Group.organizational_units.where_detail(parent_id: nil).order(:lastname)

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
target_cf       = cf("Target Metric")
current_cf      = cf("Current Metric")
progress_cf     = cf("Progress %") || cf("Progress")
checkin_cf      = cf("Last Check-in")

# "Accountable" is the built-in `responsible` work package attribute, renamed at
# the locale level (config/locales/en.yml: `responsible: "Accountable"`) - not a
# custom field, so it needs no lookup and is always a valid column/filter.
ACCOUNTABLE_COLUMN = :responsible

named_cfs = { "Organization Unit" => org_unit_cf, "OKR Health" => okr_health_cf,
              "Confidence" => confidence_cf, "Baseline" => baseline_cf, "Target Metric" => target_cf,
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

FAILURES = [] # rubocop:disable Style/MutableConstant -- accumulator, appended to below

def query_attrs(filters:, columns:, sort_criteria:, group_by:)
  # Filter hash keys must be symbols (Queries::WorkPackages::FilterSerializer /
  # the filter registry look them up as symbols; string keys are silently ignored).
  symbolized_filters = filters.transform_keys { |k| k.to_s.to_sym }

  {
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
end

def upsert_query(project:, name:, attrs:)
  query = Query.find_by(project:, name:, public: true, user: User.system)
  if query
    query.update!(attrs)
    [query, "Updated"]
  else
    [Query.create!(attrs.merge(project:, name:, user: User.system)), "Created"]
  end
end

def create_public_view!(project:, name:, filters:, columns:, sort_criteria: nil, group_by: nil)
  attrs = query_attrs(filters:, columns:, sort_criteria:, group_by:)
  query, action = upsert_query(project:, name:, attrs:)

  View.find_or_create_by!(type: "work_packages_table", query:)
  puts "#{action}: #{name}"
rescue StandardError => e
  puts "FAILED: #{name} (#{e.class}: #{e.message})"
  FAILURES << name
end

# --- Company Objectives ---------------------------------------------------
okr_level_cf = cf("OKR Level")
if okr_level_cf
  company_option_id = okr_level_cf.custom_options.find_by(value: "Company")&.id
  if company_option_id
    create_public_view!(
      project:,
      name: "Company Objectives",
      filters: {
        type_id: { operator: "=", values: [objective_type.id.to_s] },
        okr_level_cf.column_name.to_sym => { operator: "=", values: [company_option_id.to_s] },
        version_id: { operator: "=", values: [version.id.to_s] }
      },
      columns: [safe_col.call(org_unit_cf), :subject, :id, :status, ACCOUNTABLE_COLUMN,
                safe_col.call(confidence_cf), safe_col.call(okr_health_cf)]
    )
  else
    puts "Skipped 'Company Objectives': no 'Company' option found on OKR Level custom field"
  end
else
  puts "Skipped 'Company Objectives': custom field 'OKR Level' not found"
end

# --- Department Objectives (one view per top-level department) -----------
if departments.none?
  puts "No top-level departments found (Group.organizational_units.where_detail(parent_id: nil)) - " \
       "skipping Department Objectives views"
end

departments.each do |department|
  create_public_view!(
    project:,
    name: "Department Objectives - #{department.name}",
    filters: {
      type_id: { operator: "=", values: [objective_type.id.to_s] },
      org_unit_cf.column_name.to_sym => { operator: "=", values: [department.id.to_s] },
      version_id: { operator: "=", values: [version.id.to_s] }
    },
    columns: [safe_col.call(org_unit_cf), :subject, :id, :status, ACCOUNTABLE_COLUMN,
              safe_col.call(confidence_cf), safe_col.call(okr_health_cf)]
  )
end

# --- Key Results (recommended columns per the docs) -----------------------
create_public_view!(
  project:,
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

if FAILURES.any?
  puts "FAILED (#{FAILURES.size}): #{FAILURES.join(', ')}"
  exit 1
end

puts "Done."
