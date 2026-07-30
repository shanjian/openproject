# frozen_string_literal: true

# Tags the journals the GitLab integration created before it began marking them,
# so the activity tab's comments-only view can leave them out (see
# Journal::CausedByGitlabEvent).
#
# The notes were rendered from the `gitlab_integration.*_comment` templates, so
# they are recognised by turning those same templates back into LIKE patterns:
# the literal parts must match, each `%{interpolation}` becomes a wildcard.
#
# This reads *every* locale file the module ships, not just English. The Crowdin
# translations render genuinely different text -- German "**Ticket erstellt:**",
# Spanish "**Enviado en MR:**" -- and matching English alone would leave those
# journals untagged and still cluttering the filter. The files are read directly
# rather than through I18n: enumerating every locale through the runtime backend
# forces an eager load that fails on unrelated gems' locale filenames, and the
# YAML holds exactly the strings I18n would have returned anyway.
#
# Two limitations this cannot resolve:
#   * A journal written before a translation was revised no longer matches the
#     current template and stays untagged.
#   * A person who typed a note identical in shape to a whole template would
#     have it tagged. Patterns span the entire template rather than just its
#     leading label, which makes that vanishingly unlikely.
# Journals that already carry a cause are never touched.
class TagExistingGitlabJournals < ActiveRecord::Migration[8.0]
  LOCALE_GLOB = "modules/gitlab_integration/config/locales/**/*.yml"

  # `%{mr_number}` and friends -- everything the handlers substitute in.
  INTERPOLATION = /%\{[^}]*\}/

  # GitLab event family -> the templates that report it. Includes templates the
  # current code no longer uses, since older journals were written with them.
  KEYS_BY_EVENT = {
    "push" => %w[
      push_single_commit_comment push_single_commit_comment_with_ref
      push_multiple_commits_comment push_commits_comment_with_ref
    ],
    "merge_request" => %w[
      merge_request_opened_comment merge_request_closed_comment
      merge_request_merged_comment merge_request_reopened_comment
    ],
    "note" => %w[
      note_commit_referenced_comment note_mr_referenced_comment note_mr_commented_comment
      note_issue_referenced_comment note_issue_commented_comment note_snippet_referenced_comment
    ],
    "issue" => %w[
      issue_opened_referenced_comment issue_closed_referenced_comment issue_reopened_referenced_comment
    ]
  }.freeze

  def up
    KEYS_BY_EVENT.each do |event, keys|
      patterns = like_patterns(keys)
      next if patterns.empty?

      say "Tagging #{event} journals against #{patterns.size} distinct note templates"
      say "#{tag(event, patterns)} journal(s) tagged", :subitem
    end
  end

  def down
    execute("UPDATE journals SET cause = '{}'::jsonb WHERE cause->>'type' = 'gitlab_event'")
  end

  private

  def tag(event, patterns)
    cause = connection.quote({ "type" => "gitlab_event", "event" => event }.to_json)
    array = patterns.map { |pattern| connection.quote(pattern) }.join(", ")

    # Not squished on purpose: the patterns carry the newlines the templates
    # render, and collapsing whitespace would corrupt them inside the literals.
    connection.update(<<~SQL) # rubocop:disable Rails/SquishedSQLHeredocs
      UPDATE journals
      SET cause = #{cause}::jsonb
      WHERE journable_type = 'WorkPackage'
        AND COALESCE(cause, '{}'::jsonb) = '{}'::jsonb
        AND notes LIKE ANY (ARRAY[#{array}])
    SQL
  end

  def like_patterns(keys)
    templates(keys).uniq.map { |template| like_pattern(template) }
  end

  # Every translation of the given keys across the module's locale files.
  # Locales that leave a key untranslated simply contribute nothing; at runtime
  # they fell back to English, which is in the set already.
  def templates(keys)
    Rails.root.glob(LOCALE_GLOB).flat_map do |path|
      by_locale = YAML.safe_load_file(path, aliases: true)
      next [] unless by_locale.is_a?(Hash)

      by_locale.each_value.flat_map do |tree|
        section = tree.is_a?(Hash) ? tree["gitlab_integration"] : nil
        section.is_a?(Hash) ? keys.filter_map { |key| section[key] } : []
      end
    end.grep(String)
  end

  # Splits a template on its interpolations, escapes the LIKE metacharacters in
  # the literal parts between them -- backslash is PostgreSQL's default LIKE
  # escape character -- and rejoins with wildcards. The trailing wildcard keeps
  # the match from hinging on trailing whitespace.
  def like_pattern(template)
    literals = template.split(INTERPOLATION, -1).map { |literal| escape_like(literal) }

    "#{literals.join('%')}%"
  end

  def escape_like(literal)
    literal.gsub(/[\\%_]/) { |char| "\\#{char}" }
  end
end
