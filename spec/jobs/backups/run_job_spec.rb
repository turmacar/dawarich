# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Backups::RunJob, type: :job do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:noon) { Time.zone.local(2026, 10, 16, 12, 0, 0) }

  around do |example|
    Dir.mktmpdir('backups-run-job') do |dir|
      @dir = dir
      example.run
    end
  ensure
    InstanceSettings::Resolver.reset!
  end

  before { travel_to(noon) }

  after { travel_back }

  let!(:user) { create(:user) }

  def configure(frequency: nil, time: nil, path: @dir)
    InstanceSetting.create!(key: 'backup_export_frequency', value: frequency) if frequency
    InstanceSetting.create!(key: 'backup_export_time', value: time) if time
    InstanceSetting.create!(key: 'backup_export_path', value: path) if path
    InstanceSettings::Resolver.reset!
  end

  def queued_run_ids(job_class)
    enqueued_jobs.select { _1['job_class'] == job_class.name }.map { _1['arguments'].first }
  end

  describe 'on the schedule' do
    it 'does nothing while the frequency is off' do
      configure

      expect { described_class.perform_now }.not_to change(BackupRun, :count)
    end

    it 'creates a run for every user and queues a worker for each when a backup is due' do
      other = create(:user)
      configure(frequency: 'daily')

      expect { described_class.perform_now }.to change(BackupRun, :count).by(2)

      runs = BackupRun.kind_user_export.where(user: [user, other])
      expect(runs).to all(be_status_running)
      expect(queued_run_ids(Backups::UserExportJob)).to match_array(runs.ids)
    end

    it 'does not queue the same backup again on the next tick' do
      configure(frequency: 'daily')
      described_class.perform_now

      expect { described_class.perform_now }.not_to change(BackupRun, :count)
    end

    it 'also dumps the database when that is switched on' do
      configure(frequency: 'daily')
      InstanceSetting.create!(key: 'backup_database_dump', value: true)
      InstanceSettings::Resolver.reset!

      expect { described_class.perform_now }.to change { BackupRun.kind_database_dump.count }.by(1)

      expect(queued_run_ids(Backups::DatabaseDumpJob)).to eq(BackupRun.kind_database_dump.ids)
    end

    it 'leaves the database alone by default' do
      configure(frequency: 'daily')

      expect { described_class.perform_now }.not_to(change { BackupRun.kind_database_dump.count })
    end

    it 'does not start while another backup is running' do
      configure(frequency: 'daily')
      create(:backup_run, user: user)

      expect { described_class.perform_now }.not_to change(BackupRun, :count)
    end
  end

  describe 'the time of day' do
    it 'waits for the default 04:15' do
      configure(frequency: 'daily')

      travel_to(Time.zone.local(2026, 10, 16, 4, 14, 59))

      expect { described_class.perform_now }.not_to change(BackupRun, :count)
    end

    it 'starts at 04:15 sharp' do
      configure(frequency: 'daily')

      travel_to(Time.zone.local(2026, 10, 16, 4, 15, 0))

      expect { described_class.perform_now }.to change(BackupRun, :count).by(1)
    end

    it 'follows the configured time' do
      configure(frequency: 'daily', time: '13:30')

      expect { described_class.perform_now }.not_to change(BackupRun, :count)

      travel_to(Time.zone.local(2026, 10, 16, 13, 30, 0))

      expect { described_class.perform_now }.to change(BackupRun, :count).by(1)
    end

    it 'uses the instance time zone, not UTC' do
      configure(frequency: 'daily', time: '09:00')

      Time.use_zone('Pacific/Auckland') do
        travel_to(Time.find_zone('Pacific/Auckland').local(2026, 10, 16, 8, 59, 0))
        expect { described_class.perform_now }.not_to change(BackupRun, :count)

        travel_to(Time.find_zone('Pacific/Auckland').local(2026, 10, 16, 9, 0, 0))
        expect { described_class.perform_now }.to change(BackupRun, :count).by(1)
      end
    end

    it 'falls back to 04:15 when a pinned value is malformed' do
      InstanceSetting.create!(key: 'backup_export_time', value: 'half past four')
      configure(frequency: 'daily')

      travel_to(Time.zone.local(2026, 10, 16, 3, 0, 0))
      expect { described_class.perform_now }.not_to change(BackupRun, :count)

      travel_to(noon)
      expect { described_class.perform_now }.to change(BackupRun, :count).by(1)
    end
  end

  describe 'how often' do
    it 'waits until the interval has passed since the last completed backup' do
      configure(frequency: 'weekly')
      create(:backup_run, :completed, user: user, started_at: 3.days.ago)

      expect { described_class.perform_now }.not_to change(BackupRun, :count)
    end

    it 'runs again once the interval has passed' do
      configure(frequency: 'weekly')
      create(:backup_run, :completed, user: user, started_at: 8.days.ago)

      expect { described_class.perform_now }.to change(BackupRun, :count).by(1)
    end

    it 'runs again the next day at the same time even though the last run took a few seconds' do
      configure(frequency: 'daily')
      create(:backup_run, :completed, user: user, started_at: Time.zone.local(2026, 10, 15, 4, 15, 30))

      travel_to(Time.zone.local(2026, 10, 16, 4, 15, 0))

      expect { described_class.perform_now }.to change(BackupRun, :count).by(1)
    end

    it 'does not run twice in one day' do
      configure(frequency: 'daily')
      create(:backup_run, :completed, user: user, started_at: 2.hours.ago)

      expect { described_class.perform_now }.not_to change(BackupRun, :count)
    end

    it 'goes back to the configured time after a manual run late in the day' do
      configure(frequency: 'daily')
      create(:backup_run, :completed, user: user, started_at: Time.zone.local(2026, 10, 15, 12, 53, 0))

      travel_to(Time.zone.local(2026, 10, 16, 4, 14, 59))
      expect { described_class.perform_now }.not_to change(BackupRun, :count)

      travel_to(Time.zone.local(2026, 10, 16, 4, 15, 0))
      expect { described_class.perform_now }.to change(BackupRun, :count).by(1)
    end

    it 'does not run again the same day after a manual run before the configured time' do
      configure(frequency: 'daily')
      create(:backup_run, :completed, user: user, started_at: Time.zone.local(2026, 10, 16, 3, 0, 0))

      travel_to(Time.zone.local(2026, 10, 16, 4, 15, 0))

      expect { described_class.perform_now }.not_to change(BackupRun, :count)
    end

    it 'keeps a weekly schedule on the weekday and time of the last run' do
      configure(frequency: 'weekly')
      create(:backup_run, :completed, user: user, started_at: Time.zone.local(2026, 10, 9, 12, 53, 0))

      travel_to(Time.zone.local(2026, 10, 15, 23, 0, 0))
      expect { described_class.perform_now }.not_to change(BackupRun, :count)

      travel_to(Time.zone.local(2026, 10, 16, 4, 14, 59))
      expect { described_class.perform_now }.not_to change(BackupRun, :count)

      travel_to(Time.zone.local(2026, 10, 16, 4, 15, 0))
      expect { described_class.perform_now }.to change(BackupRun, :count).by(1)
    end

    it 'keeps a monthly schedule on the day of the month of the last run' do
      configure(frequency: 'monthly')
      create(:backup_run, :completed, user: user, started_at: Time.zone.local(2026, 9, 16, 12, 53, 0))

      travel_to(Time.zone.local(2026, 10, 15, 12, 0, 0))
      expect { described_class.perform_now }.not_to change(BackupRun, :count)

      travel_to(Time.zone.local(2026, 10, 16, 4, 15, 0))
      expect { described_class.perform_now }.to change(BackupRun, :count).by(1)
    end

    it 'catches up at the next check after downtime' do
      configure(frequency: 'daily')
      create(:backup_run, :completed, user: user, started_at: Time.zone.local(2026, 10, 12, 4, 15, 30))

      expect { described_class.perform_now }.to change(BackupRun, :count).by(1)
    end
  end

  describe 'after a failure' do
    it 'does not retry within the same day' do
      configure(frequency: 'daily')
      create(:backup_run, user: user, status: :failed, started_at: 1.hour.ago, finished_at: 50.minutes.ago)

      expect { described_class.perform_now }.not_to change(BackupRun, :count)
    end

    it 'retries the next day' do
      configure(frequency: 'daily')
      create(:backup_run, user: user, status: :failed, started_at: 25.hours.ago, finished_at: 25.hours.ago)

      expect { described_class.perform_now }.to change(BackupRun, :count).by(1)
    end

    it 'retries a weekly schedule the next day instead of waiting a week' do
      configure(frequency: 'weekly')
      create(:backup_run, :completed, user: user, started_at: 8.days.ago)
      create(:backup_run, user: user, status: :failed, started_at: 25.hours.ago, finished_at: 25.hours.ago)

      expect { described_class.perform_now }.to change(BackupRun, :count).by(1)
    end
  end

  describe 'forced from the admin page' do
    it 'runs even when the schedule is off and the time has not come' do
      configure

      travel_to(Time.zone.local(2026, 10, 16, 1, 0, 0))

      expect { described_class.perform_now(force: true) }.to change(BackupRun, :count).by(1)
    end
  end

  describe 'when the backup directory is unusable' do
    it 'creates no runs and tells the admins why' do
      admin = create(:user, admin: true)
      configure(frequency: 'daily', path: File.join(@dir, 'not-mounted'))

      expect { described_class.perform_now }.to change { admin.notifications.error.count }.by(1)

      expect(BackupRun.count).to eq(0)
      expect(admin.notifications.last.content).to include('not-mounted')
    end

    it 'creates no runs when no directory is configured' do
      configure(frequency: 'daily', path: nil)

      expect { described_class.perform_now }.not_to change(BackupRun, :count)
    end
  end
end
