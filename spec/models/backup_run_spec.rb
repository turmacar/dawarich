# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BackupRun, type: :model do
  describe 'validations' do
    it 'requires a user for a user export' do
      run = build(:backup_run, user: nil)

      expect(run).not_to be_valid
      expect(run.errors[:user]).to be_present
    end

    it 'does not require a user for a database dump' do
      expect(build(:backup_run, :database_dump)).to be_valid
    end

    it 'requires a start time' do
      expect(build(:backup_run, started_at: nil)).not_to be_valid
    end
  end

  describe '.active' do
    it 'includes a recent running run and excludes finished and stale ones' do
      running = create(:backup_run)
      create(:backup_run, :completed)
      create(:backup_run, started_at: (described_class::STALE_AFTER + 1.minute).ago)

      expect(described_class.active).to contain_exactly(running)
    end
  end

  describe '.recent' do
    it 'lists the newest run first' do
      older = create(:backup_run, started_at: 2.days.ago)
      newer = create(:backup_run, started_at: 1.hour.ago)

      expect(described_class.recent).to eq([newer, older])
    end
  end

  describe '#complete!' do
    it 'records the file and finishes the run' do
      run = create(:backup_run)

      run.complete!(file_name: 'a.zip', bytes: 42)

      expect(run.reload).to be_status_completed
      expect(run).to have_attributes(file_name: 'a.zip', bytes: 42, error: nil)
      expect(run.finished_at).to be_present
    end
  end

  describe '#fail!' do
    it 'records the error and finishes the run' do
      run = create(:backup_run)

      run.fail!('disk full')

      expect(run.reload).to be_status_failed
      expect(run.error).to eq('disk full')
      expect(run.finished_at).to be_present
    end
  end

  describe 'deleting related records' do
    it 'keeps the run when its user is deleted' do
      run = create(:backup_run, :completed)

      run.user.destroy!

      expect(run.reload.user).to be_nil
    end

    it 'keeps the run when its export is deleted' do
      export = create(:export)
      run = create(:backup_run, :completed, export: export)

      export.destroy!

      expect(run.reload.export).to be_nil
    end
  end
end
