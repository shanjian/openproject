# frozen_string_literal: true

# Per-project mapping to a GitLab project, used when creating branches from a
# work package. See GITLAB_CREATE_BRANCH_DESIGN.md §2.2.
class CreateGitlabProjectSettings < ActiveRecord::Migration[8.0]
  def change
    create_table :gitlab_project_settings do |t|
      t.references :project, null: false, foreign_key: true, index: { unique: true }
      # GitLab project identifier: either the numeric id or the URL-encoded
      # "namespace/project" path (GitLab's API accepts both as :id).
      t.string :gitlab_project_id, null: false
      # Optional ref to branch from; when blank the GitLab project's
      # default_branch is queried at runtime.
      t.string :default_ref
      t.timestamps
    end
  end
end
