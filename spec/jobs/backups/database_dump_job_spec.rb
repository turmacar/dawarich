# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Backups::DatabaseDumpJob, type: :job do
  around do |example|
    Dir.mktmpdir('backups-database-dump') do |dir|
      @dir = dir
      InstanceSetting.create!(key: 'backup_export_path', value: dir)
      InstanceSettings::Resolver.reset!
      example.run
    end
  ensure
    InstanceSettings::Resolver.reset!
  end

  let(:database_dir) { Pathname.new(@dir).join('database') }

  def written_files
    database_dir.children.map { _1.basename.to_s }
  end

  # pg_dump refuses a server newer than itself, so a real dump needs a client at least as new.
  def compatible_pg_dump?
    client = Open3.capture2('pg_dump', '--version').first[/\d+/].to_i
    server = ActiveRecord::Base.connection.select_value('SHOW server_version_num').to_i / 10_000
    client >= server
  rescue Errno::ENOENT
    false
  end

  describe 'with a real pg_dump' do
    before { skip 'no pg_dump at least as new as the test database' unless compatible_pg_dump? }

    it 'writes a dump that pg_restore can read and records the run' do
      described_class.perform_now

      run = BackupRun.kind_database_dump.last
      expect(run).to be_status_completed
      expect(written_files).to eq([run.file_name])
      expect(run.file_name).to match(/\Adawarich_db_\d{8}_\d{6}\.pgcustom\z/)
      expect(run.bytes).to be_positive

      listing, status = Open3.capture2('pg_restore', '--list', database_dir.join(run.file_name).to_s)
      expect(status).to be_success
      expect(listing).to include('backup_runs')
    end
  end

  describe 'the pg_dump call' do
    let(:success) { instance_double(Process::Status, success?: true) }

    it 'passes the password through the environment and never on the command line' do
      captured = nil
      allow(Open3).to receive(:capture3) do |*args|
        captured = args
        ['', '', success]
      end
      config = ActiveRecord::Base.connection_db_config.configuration_hash.merge(password: 's3cret-pw')
      allow(ActiveRecord::Base.connection_db_config).to receive(:configuration_hash).and_return(config)

      described_class.perform_now

      env, *argv = captured
      expect(env).to eq('PGPASSWORD' => 's3cret-pw')
      expect(argv.join(' ')).not_to include('s3cret-pw')
      expect(argv).to include('pg_dump', '--format=custom', config[:database])
    end

    it 'does not go through a shell' do
      allow(Open3).to receive(:capture3).and_return(['', '', success])

      described_class.perform_now

      expect(Open3).to have_received(:capture3).with(Hash, 'pg_dump', any_args)
    end
  end

  describe 'retention' do
    it 'keeps only the newest dumps' do
      InstanceSetting.create!(key: 'backup_export_retention', value: 1)
      InstanceSettings::Resolver.reset!
      allow(Open3).to receive(:capture3).and_return(['', '', instance_double(Process::Status, success?: true)])
      FileUtils.mkdir_p(database_dir)
      File.write(database_dir.join('old.pgcustom'), 'old')
      old = create(:backup_run, :database_dump, :completed, file_name: 'old.pgcustom', started_at: 2.days.ago)

      described_class.perform_now

      expect(BackupRun.exists?(old.id)).to be(false)
      expect(written_files).not_to include('old.pgcustom')
      expect(BackupRun.kind_database_dump.status_completed.count).to eq(1)
    end
  end

  describe 'a failed dump' do
    let!(:admin) { create(:user, admin: true) }
    let(:failure) { instance_double(Process::Status, success?: false) }

    before { allow(Open3).to receive(:capture3).and_return(['', 'connection refused', failure]) }

    it 'records the error, tells the admins and leaves no partial file' do
      expect { described_class.perform_now }.to change { admin.notifications.error.count }.by(1)

      run = BackupRun.kind_database_dump.last
      expect(run).to be_status_failed
      expect(run.error).to include('connection refused')
      expect(database_dir.children).to be_empty
    end
  end

  it 'refuses to run without a usable directory instead of writing elsewhere' do
    InstanceSetting.where(key: 'backup_export_path').update_all(value: File.join(@dir, 'gone').to_json)
    InstanceSettings::Resolver.reset!

    expect { described_class.perform_now }.to raise_error(Backups::Destination::Unavailable)
    expect(BackupRun.count).to eq(0)
  end
end
