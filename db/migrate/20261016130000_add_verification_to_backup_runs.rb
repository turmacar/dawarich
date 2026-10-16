# frozen_string_literal: true

class AddVerificationToBackupRuns < ActiveRecord::Migration[8.0]
  def change
    add_column :backup_runs, :verification, :jsonb
    add_column :backup_runs, :verified_at, :datetime
  end
end
