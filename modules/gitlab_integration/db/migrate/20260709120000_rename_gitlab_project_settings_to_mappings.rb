# frozen_string_literal: true

# Evolve the one-GitLab-project-per-project mapping into many-per-project:
# rename the table, add an optional friendly `name`, and replace the unique
# index on project_id with a composite unique index so a project can map to
# several GitLab projects (but not the same one twice).
# See GITLAB_CREATE_BRANCH_DESIGN.md §10.
class RenameGitlabProjectSettingsToMappings < ActiveRecord::Migration[8.0]
  def up
    rename_table :gitlab_project_settings, :gitlab_project_mappings
    add_column :gitlab_project_mappings, :name, :string

    remove_index :gitlab_project_mappings, column: :project_id, if_exists: true
    add_index :gitlab_project_mappings, %i[project_id gitlab_project_id], unique: true
  end

  def down
    remove_index :gitlab_project_mappings, column: %i[project_id gitlab_project_id], if_exists: true
    add_index :gitlab_project_mappings, :project_id, unique: true

    remove_column :gitlab_project_mappings, :name
    rename_table :gitlab_project_mappings, :gitlab_project_settings
  end
end
