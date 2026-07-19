# frozen_string_literal: true

# Persists Git branches that reference a work package (by OpenProject's
# `{type}/{id}-{slug}` naming convention or an explicit OP#<id> mention),
# captured from GitLab push webhooks. Mirrors the gitlab_merge_requests /
# gitlab_issues tables so branches can be listed on a work package.
class CreateGitlabBranches < ActiveRecord::Migration[8.0]
  def change
    create_table :gitlab_branches do |t|
      t.string :name, null: false
      t.string :gitlab_html_url, null: false
      t.string :repository, null: false
      t.string :last_commit_sha
      t.text :last_commit_message
      t.string :last_commit_html_url
      t.string :last_commit_author
      t.datetime :gitlab_updated_at, precision: nil

      t.timestamps precision: nil

      t.index :gitlab_html_url, unique: true
    end

    create_join_table :gitlab_branches, :work_packages do |t|
      t.index :gitlab_branch_id, name: "gitlab_branches_wp_branch_id"
      t.index %i[gitlab_branch_id work_package_id],
              unique: true,
              name: "unique_index_gl_branches_wps_on_gl_branch_id_and_wp_id"
    end
  end
end
