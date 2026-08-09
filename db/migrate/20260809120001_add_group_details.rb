# frozen_string_literal: true

class AddGroupDetails < ActiveRecord::Migration[8.1]
  def change
    create_table :group_details do |t|
      t.references :principal, null: false, foreign_key: { to_table: :users }, index: { unique: true }
      t.boolean :organizational_unit, default: false, null: false
      t.references :parent, foreign_key: { to_table: :users }

      t.timestamps
    end

    reversible do |dir|
      dir.up do
        execute <<~SQL.squish
          INSERT INTO group_details (principal_id, organizational_unit, created_at, updated_at)
          SELECT id, false, NOW(), NOW()
          FROM users
          WHERE type = 'Group'
        SQL
      end
    end
  end
end
