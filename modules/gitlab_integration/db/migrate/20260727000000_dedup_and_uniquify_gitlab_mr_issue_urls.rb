# frozen_string_literal: true

# Merge requests and issues are identified by their globally-unique
# +gitlab_html_url+, but -- unlike gitlab_branches -- the tables had no unique
# index enforcing that. When the same GitLab event is delivered twice at nearly
# the same time (e.g. via both a per-repository webhook and an instance-wide
# system hook), the two deliveries race: each runs find-or-initialize, neither
# sees the other's not-yet-committed row, and both insert -- leaving duplicate
# records for one merge request / issue.
#
# This migration removes existing duplicates (keeping the oldest row per URL and
# moving its work-package links and pipelines onto it) and then adds the unique
# index so the database rejects the racing insert from now on. The upsert
# services rescue the resulting RecordNotUnique and re-find the row.
class DedupAndUniquifyGitlabMrIssueUrls < ActiveRecord::Migration[8.0]
  def up
    dedup_merge_requests
    dedup_issues

    add_index :gitlab_merge_requests, :gitlab_html_url, unique: true,
                                                        name: "index_gitlab_merge_requests_on_gitlab_html_url"
    add_index :gitlab_issues, :gitlab_html_url, unique: true,
                                                name: "index_gitlab_issues_on_gitlab_html_url"
  end

  def down
    remove_index :gitlab_merge_requests, name: "index_gitlab_merge_requests_on_gitlab_html_url"
    remove_index :gitlab_issues, name: "index_gitlab_issues_on_gitlab_html_url"
  end

  private

  def dedup_merge_requests
    execute(<<~SQL.squish)
      CREATE TEMPORARY TABLE gitlab_mr_dups ON COMMIT DROP AS
      SELECT m.id AS dup_id, s.survivor_id
      FROM gitlab_merge_requests m
      JOIN (
        SELECT gitlab_html_url, MIN(id) AS survivor_id
        FROM gitlab_merge_requests
        GROUP BY gitlab_html_url
        HAVING COUNT(*) > 1
      ) s ON m.gitlab_html_url = s.gitlab_html_url
      WHERE m.id <> s.survivor_id
    SQL

    # Drop the duplicate's work-package links that the survivor already has,
    # then move the remaining ones onto the survivor.
    execute(<<~SQL.squish)
      DELETE FROM gitlab_merge_requests_work_packages j
      USING gitlab_mr_dups d
      WHERE j.gitlab_merge_request_id = d.dup_id
        AND EXISTS (
          SELECT 1 FROM gitlab_merge_requests_work_packages j2
          WHERE j2.gitlab_merge_request_id = d.survivor_id
            AND j2.work_package_id = j.work_package_id
        )
    SQL
    execute(<<~SQL.squish)
      UPDATE gitlab_merge_requests_work_packages j
      SET gitlab_merge_request_id = d.survivor_id
      FROM gitlab_mr_dups d
      WHERE j.gitlab_merge_request_id = d.dup_id
    SQL

    # Pipelines belong to a merge request; move them onto the survivor.
    execute(<<~SQL.squish)
      UPDATE gitlab_pipelines p
      SET gitlab_merge_request_id = d.survivor_id
      FROM gitlab_mr_dups d
      WHERE p.gitlab_merge_request_id = d.dup_id
    SQL

    execute(<<~SQL.squish)
      DELETE FROM gitlab_merge_requests m
      USING gitlab_mr_dups d
      WHERE m.id = d.dup_id
    SQL
  end

  def dedup_issues
    execute(<<~SQL.squish)
      CREATE TEMPORARY TABLE gitlab_issue_dups ON COMMIT DROP AS
      SELECT i.id AS dup_id, s.survivor_id
      FROM gitlab_issues i
      JOIN (
        SELECT gitlab_html_url, MIN(id) AS survivor_id
        FROM gitlab_issues
        GROUP BY gitlab_html_url
        HAVING COUNT(*) > 1
      ) s ON i.gitlab_html_url = s.gitlab_html_url
      WHERE i.id <> s.survivor_id
    SQL

    execute(<<~SQL.squish)
      DELETE FROM gitlab_issues_work_packages j
      USING gitlab_issue_dups d
      WHERE j.gitlab_issue_id = d.dup_id
        AND EXISTS (
          SELECT 1 FROM gitlab_issues_work_packages j2
          WHERE j2.gitlab_issue_id = d.survivor_id
            AND j2.work_package_id = j.work_package_id
        )
    SQL
    execute(<<~SQL.squish)
      UPDATE gitlab_issues_work_packages j
      SET gitlab_issue_id = d.survivor_id
      FROM gitlab_issue_dups d
      WHERE j.gitlab_issue_id = d.dup_id
    SQL

    execute(<<~SQL.squish)
      DELETE FROM gitlab_issues i
      USING gitlab_issue_dups d
      WHERE i.id = d.dup_id
    SQL
  end
end
