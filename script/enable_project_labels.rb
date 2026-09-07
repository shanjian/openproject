# frozen_string_literal: true

# Turns on two-tier label governance for an existing installation.
#
# Three things have to be true before a project admin can create a label:
#
#   1. the label field accepts project-owned values (custom_fields.allow_project_values)
#      and carries an option_pattern, which is required whenever that flag is on;
#   2. the project has a label_prefix - the namespace its own labels must sit in;
#   3. the role has manage_project_labels, which the GrantManageProjectLabels migration
#      hands to every role already holding edit_project.
#
# This script does 1 and 2, and reports on 3.
#
#   bundle exec rails runner script/enable_project_labels.rb          # dry run, writes nothing
#   APPLY=1 bundle exec rails runner script/enable_project_labels.rb  # write
#
# From a console: load "script/enable_project_labels.rb"
#
# It is re-runnable. Everything it writes is checked first, so a second run reports and
# changes nothing.
#
# Prefixes are derived exactly as the admin screen derives them - the identifier with "-"
# and "_" removed, upcased - and only when the result is a legal prefix nothing else holds.
# A project whose identifier does not yield one is reported rather than guessed at: picking
# a namespace is a decision, not a normalisation.
#
# Overrides, all optional:
#   LABEL_FIELD                the custom field's name        (default "Labels")
#   LABEL_PATTERN              the option_pattern to set
#   LABEL_PATTERN_DESCRIPTION  what users see when a value is rejected

module EnableProjectLabels
  module_function

  def run(apply:, field_name:, pattern:, description:)
    puts apply ? "APPLYING CHANGES" : "DRY RUN - nothing will be written (set APPLY=1 to write)"

    fields = label_fields(field_name)
    return if fields.empty?

    fields.each { |field| configure_field(field, pattern, description, apply) }
    assign_prefixes(apply)
    report_permission
    report_next_steps(apply)
  end

  def label_fields(field_name)
    fields = CustomField.where(field_format: "list", name: field_name).to_a
    return fields if fields.any?

    puts "\nNo list custom field named #{field_name.inspect}. List fields present:"
    CustomField.where(field_format: "list").order(:name).each do |field|
      puts format("  [%<id>d] %<name>s (%<type>s)", id: field.id, name: field.name, type: field.type)
    end
    puts %(Re-run with LABEL_FIELD="<name>".)
    fields
  end

  def configure_field(field, pattern, description, apply)
    puts format("\nField [%<id>d] %<name>s (%<type>s)", id: field.id, name: field.name, type: field.type)
    puts "  allow_project_values  #{field.allow_project_values?} -> true"
    puts "  option_pattern        #{field.option_pattern.inspect} -> #{pattern.inspect}"

    report_non_conforming(field, pattern)

    return puts "  (dry run - not written)" unless apply

    write_field(field, pattern, description)
  end

  def write_field(field, pattern, description)
    field.allow_project_values = true
    field.option_pattern = pattern
    field.option_pattern_description = description

    if field.save
      puts "  written"
    else
      puts "  REFUSED: #{field.errors.full_messages.join(', ')}"
    end
  end

  # The pattern governs BOTH tiers, so existing system labels are worth looking at before
  # committing to it. They are not invalidated - the pattern is checked when a value is
  # created or renamed, never on unrelated saves - but they can no longer be renamed as they
  # stand, which is a surprise worth having in advance rather than in a support request.
  def report_non_conforming(field, pattern)
    values = field.custom_options.order(:value).pluck(:value)
    offenders = values.grep_v(Regexp.new(pattern))
    return puts "  every existing value already matches the pattern" if offenders.empty?

    puts "  #{offenders.size} of #{values.size} existing values do not match it."
    puts "  They keep working and stay applicable; they just cannot be renamed until they conform:"
    list(offenders)
  end

  def list(values, limit: 20)
    values.first(limit).each { |value| puts "    #{value}" }
    puts "    ... and #{values.size - limit} more" if values.size > limit
  end

  def assign_prefixes(apply)
    puts "\nProject prefixes"
    taken = Project.where.not(label_prefix: nil).pluck(:label_prefix).to_set
    undecided = []

    Project.order(:name).each do |project|
      reason = assign_prefix(project, taken, apply)
      undecided << [project, reason] if reason
    end

    report_undecided(undecided)
  end

  # Returns nil when there is nothing left to decide, or the reason an admin has to.
  def assign_prefix(project, taken, apply)
    return say(project, project.label_prefix, "already set") if project.label_prefix.present?

    candidate = project.identifier.to_s.delete("-_").upcase
    problem = prefix_problem(candidate, taken)
    return problem if problem

    unless apply
      taken << candidate
      return say(project, candidate, "would be set")
    end

    write_prefix(project, candidate, taken)
  end

  def prefix_problem(candidate, taken)
    unless LabelNaming::PREFIX_FORMAT.match?(candidate)
      return "#{candidate.inspect} is not a legal prefix - it must be 2 to 6 characters, " \
             "upper case, starting with a letter"
    end

    "#{candidate} is already held by another project" if taken.include?(candidate)
  end

  def write_prefix(project, candidate, taken)
    project.label_prefix = candidate
    return project.errors.full_messages.join(", ") unless project.save

    taken << candidate
    say(project, candidate, "set")
  end

  # nil, so a caller collecting reasons collects nothing for a project that needed no decision.
  def say(project, prefix, note)
    puts format("  %<id>-28s %<prefix>-8s %<note>s", id: project.identifier, prefix:, note:)
    nil
  end

  def report_undecided(undecided)
    return if undecided.empty?

    puts "\n#{undecided.size} project(s) need a prefix chosen by hand. Until they have one they"
    puts "cannot own labels - the project settings screen says so rather than failing later."
    undecided.each do |project, reason|
      puts format("  %<id>-28s %<reason>s", id: project.identifier, reason:)
    end
    puts "\nSet one with, for example:"
    puts %(  Project.find_by(identifier: "#{undecided.first.first.identifier}").update!(label_prefix: "XYZ"))
    puts "or from Administration -> Projects -> Label prefixes."
  end

  # Reported, not granted. The migration is the right place to grant it, and re-granting here
  # would paper over a migration that did not run - which is worth seeing.
  def report_permission
    granted = RolePermission.where(permission: "manage_project_labels").pluck(:role_id).to_set
    holders = RolePermission.where(permission: "edit_project").pluck(:role_id).to_set

    puts "\nPermission"
    puts "  manage_project_labels is held by #{granted.size} role(s)"

    report_missing_permission(Role.where(id: (holders - granted).to_a).order(:name), granted)
  end

  def report_missing_permission(missing, granted)
    if missing.any?
      puts "  These roles hold edit_project but NOT manage_project_labels:"
      missing.each { |role| puts "    #{role.name}" }
      puts "  Run db:migrate - GrantManageProjectLabels grants it - or tick it in the role's"
      puts "  permission list under Administration -> Roles and permissions."
    elsif granted.empty?
      puts "  No role holds it. Run bundle exec rails db:migrate."
    end
  end

  def report_next_steps(apply)
    puts "\nNext"
    unless apply
      puts "  Re-run with APPLY=1 to write the changes above."
      return
    end

    puts "  A project admin now sees Project settings -> Labels, and can create labels under"
    puts "  their project's own prefix. System labels stay under Administration -> Custom fields."
  end
end

EnableProjectLabels.run(
  apply: ENV["APPLY"].present?,
  field_name: ENV.fetch("LABEL_FIELD", "Labels"),
  pattern: ENV.fetch("LABEL_PATTERN", '\A[A-Z][A-Z0-9]{1,5}-[A-Za-z0-9]+([-_][A-Za-z0-9]+)*\z'),
  description: ENV.fetch("LABEL_PATTERN_DESCRIPTION",
                         "Start with your project's prefix and a hyphen, then a name: " \
                         "AT-bounce, AT-bounce-handling, AT-2fa.")
)
