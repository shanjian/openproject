class CreateWorkPackageImportRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :work_package_import_runs do |t|
      t.references :project, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :status, null: false, default: "queued"
      t.text :source, null: false
      t.integer :created_work_package_ids, array: true, default: [], null: false
      t.jsonb :failure

      t.timestamps
    end
  end
end
