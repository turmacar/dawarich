# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Backups::RunJob, type: :job do
  include ActiveJob::TestHelper

  around do |example|
    Dir.mktmpdir('backups-run-job') do |dir|
      @dir = dir
      example.run
    end
  ensure
    InstanceSettings::Resolver.reset!
  end

  let!(:user) { create(:user) }

  def configure(frequency: nil, path: @dir)
    InstanceSetting.create!(key: 'backup_export_frequency', value: frequency) if frequency
    InstanceSetting.create!(key: 'backup_export_path', value: path) if path
    InstanceSettings::Resolver.reset!
  end

  describe 'on the schedule' do
    it 'does nothing while the frequency is off' do
      configure

      expect { described_class.perform_now }.not_to have_enqueued_job(Backups::UserExportJob)
    end

    it 'exports every user when a backup is due' do
      other = create(:user)
      configure(frequency: 'daily')

      described_class.perform_now

      expect(Backups::UserExportJob).to have_been_enqueued.with(user.id)
      expect(Backups::UserExportJob).to have_been_enqueued.with(other.id)
    end

    it 'waits until the interval has passed since the last completed backup' do
      configure(frequency: 'weekly')
      create(:backup_run, :completed, user: user, started_at: 3.days.ago)

      expect { described_class.perform_now }.not_to have_enqueued_job(Backups::UserExportJob)
    end

    it 'runs again once the interval has passed' do
      configure(frequency: 'weekly')
      create(:backup_run, :completed, user: user, started_at: 8.days.ago)

      expect { described_class.perform_now }.to have_enqueued_job(Backups::UserExportJob).with(user.id)
    end

    it 'also dumps the database when that is switched on' do
      configure(frequency: 'daily')
      InstanceSetting.create!(key: 'backup_database_dump', value: true)
      InstanceSettings::Resolver.reset!

      expect { described_class.perform_now }.to have_enqueued_job(Backups::DatabaseDumpJob)
    end

    it 'leaves the database alone by default' do
      configure(frequency: 'daily')

      expect { described_class.perform_now }.not_to have_enqueued_job(Backups::DatabaseDumpJob)
    end

    it 'is not held back by a failed attempt' do
      configure(frequency: 'daily')
      create(:backup_run, user: user, status: :failed, started_at: 1.hour.ago)

      expect { described_class.perform_now }.to have_enqueued_job(Backups::UserExportJob)
    end

    it 'does not start while another backup is running' do
      configure(frequency: 'daily')
      create(:backup_run, user: user)

      expect { described_class.perform_now }.not_to have_enqueued_job(Backups::UserExportJob)
    end
  end

  describe 'forced from the admin page' do
    it 'runs even when the schedule is off' do
      configure

      expect { described_class.perform_now(force: true) }.to have_enqueued_job(Backups::UserExportJob).with(user.id)
    end
  end

  describe 'when the backup directory is unusable' do
    it 'enqueues nothing and tells the admins why' do
      admin = create(:user, admin: true)
      configure(frequency: 'daily', path: File.join(@dir, 'not-mounted'))

      expect { described_class.perform_now }.to change { admin.notifications.error.count }.by(1)

      expect(Backups::UserExportJob).not_to have_been_enqueued
      expect(admin.notifications.last.content).to include('not-mounted')
    end

    it 'enqueues nothing when no directory is configured' do
      configure(frequency: 'daily', path: nil)

      expect { described_class.perform_now }.not_to have_enqueued_job(Backups::UserExportJob)
    end
  end
end
