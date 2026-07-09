# frozen_string_literal: true

# Per-user GitLab Personal Access Token (needs the `write_repository` scope),
# used to create branches on the user's behalf. Stored ciphered via
# Redmine::Ciphering. See GITLAB_CREATE_BRANCH_DESIGN.md §2.3.
class CreateGitlabUserTokens < ActiveRecord::Migration[8.0]
  def change
    create_table :gitlab_user_tokens do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      # Ciphered PAT (format "aes-256-cbc:..."); never exposed to the frontend.
      t.text :token, null: false
      t.timestamps
    end
  end
end
