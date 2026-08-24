# frozen_string_literal: true

class AddTrigramIndexesForTypeaheadSearch < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :work_packages, :subject,
              using: :gin,
              opclass: :gin_trgm_ops,
              algorithm: :concurrently,
              name: "index_work_packages_on_subject_trigram"

    add_index :projects, :name,
              using: :gin,
              opclass: :gin_trgm_ops,
              algorithm: :concurrently,
              name: "index_projects_on_name_trigram"
  end
end
