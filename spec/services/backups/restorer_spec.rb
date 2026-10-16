# frozen_string_literal: true

require 'rails_helper'

# Restores the test database in place from a dump of itself, the way a real restore does.
RSpec.describe Backups::Restorer, :non_transactional do
  let(:dir) { Pathname.new(Dir.mktmpdir('backups-restore')) }
  let(:destination) { Backups::Destination.new(dir.to_s) }
  let(:connection) { ActiveRecord::Base.connection }
  let(:emails) { %w[kept@example.com later@example.com] }

  def compatible_pg_dump?
    client = Open3.capture2('pg_dump', '--version').first[/\d+/].to_i
    client >= connection.select_value('SHOW server_version_num').to_i / 10_000
  rescue Errno::ENOENT
    false
  end

  def dump_source
    FileUtils.mkdir_p(dir.join('database'))
    path = dir.join('database', 'source.pgcustom')
    Backups::Postgres.dump(path)
    path
  end

  def verified_source(path)
    BackupRun.create!(kind: :database_dump, status: :completed, started_at: 1.hour.ago, file_name: path.basename.to_s,
                      bytes: File.size(path), verified_at: Time.current,
                      verification: { 'state' => 'passed', 'sha256' => Digest::SHA256.file(path).hexdigest })
  end

  def restore_run
    BackupRun.create!(kind: :database_restore, status: :running, started_at: Time.current, file_name: 'source.pgcustom')
  end

  def restorer(source)
    described_class.new(source, destination: destination).tap { allow(_1).to receive(:migrate!) }
  end

  before { allow(InstanceSettings::Notifier).to receive(:publish) }

  after do
    Backups::Maintenance.finish!
    # destroy only soft-deletes users, and a soft-deleted email still counts as taken.
    User.unscoped.where(email: emails).delete_all
    BackupRun.delete_all
    FileUtils.rm_rf(dir)
  end

  describe 'a real restore' do
    before { skip 'no pg_dump at least as new as the test database' unless compatible_pg_dump? }

    it 'brings back the dumped data, keeps the backup history and saves a safety dump' do
      kept = create(:user, email: 'kept@example.com')
      path = dump_source
      source = verified_source(path)
      later = create(:user, email: 'later@example.com')
      later_run = BackupRun.create!(kind: :user_export, status: :completed, user: later, started_at: Time.current,
                                    file_name: 'later.zip')
      run = restore_run

      safety = restorer(source).call(run)

      expect(User.where(email: emails).pluck(:email)).to eq(['kept@example.com'])
      expect(User.find(kept.id)).to be_present
      expect(BackupRun.find(later_run.id).user_id).to be_nil
      expect(BackupRun.find(source.id).verification_state).to eq('passed')
      expect(run.reload).to be_status_completed
      expect(dir.join('database', safety[:file_name])).to exist
      expect(BackupRun.kind_database_dump.find_by(file_name: safety[:file_name])).to be_status_completed
      expect(Backups::Maintenance.current).to be_nil
      expect { BackupRun.create!(kind: :database_dump, started_at: Time.current) }.not_to raise_error
    end

    it 'leaves the database as it was when the restore fails' do
      path = dump_source
      File.binwrite(path, File.binread(path).byteslice(0, File.size(path) / 2))
      source = verified_source(path)
      create(:user, email: 'later@example.com')
      run = restore_run

      expect { restorer(source).call(run) }.to raise_error(Backups::Postgres::Failed)

      expect(User.where(email: 'later@example.com')).to exist
      expect(run.reload).to be_status_failed
      expect(BackupRun.kind_database_dump.where('file_name LIKE ?', '%_pre-restore.pgcustom')).to exist
      expect(Backups::Maintenance.current).to be_nil
    end
  end

  describe '#check!' do
    let(:path) do
      FileUtils.mkdir_p(dir.join('database'))
      dir.join('database', 'source.pgcustom').tap { File.write(_1, 'dump') }
    end

    it 'refuses a dump that has not passed verification' do
      source = verified_source(path)
      source.update!(verification: { 'state' => 'failed' })

      expect { restorer(source).check! }.to raise_error(described_class::Unavailable, 'not_verified')
    end

    it 'refuses while a backup or verification is running, apart from the restore itself' do
      source = verified_source(path)
      run = restore_run

      expect { restorer(source).check!(restore_run: run) }.not_to raise_error
      expect { restorer(source).check! }.to raise_error(described_class::Unavailable, 'busy')
    end

    it 'refuses a file that changed after it was verified' do
      source = verified_source(path)
      File.write(path, 'different')

      expect { restorer(source).call(restore_run) }.to raise_error(described_class::Unavailable, 'changed')
    end
  end
end
