# frozen_string_literal: true

class CreateBackupRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :backup_runs do |t|
      t.integer :kind, null: false
      t.integer :status, null: false, default: 0
      t.references :user, foreign_key: { on_delete: :nullify }
      t.references :export, foreign_key: { on_delete: :nullify }
      t.string :file_name
      t.bigint :bytes
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.text :error

      t.timestamps
    end

    add_index :backup_runs, %i[kind started_at]
  end
end
