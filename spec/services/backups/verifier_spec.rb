# frozen_string_literal: true

require 'rails_helper'

# CREATE DATABASE cannot run inside a transaction, and pg_dump only sees committed rows.
RSpec.describe Backups::Verifier, :non_transactional do
  let(:dir) { Pathname.new(Dir.mktmpdir('backups-verify')) }
  let(:destination) { Backups::Destination.new(dir.to_s) }
  let(:run) do
    BackupRun.create!(kind: :database_dump, status: :completed, started_at: Time.current, file_name: 'db.pgcustom')
  end
  let(:dump_path) { dir.join('database', run.file_name) }
  let(:verifier) { described_class.new(run, destination: destination) }
  let(:connection) { ActiveRecord::Base.connection }

  def scratch_databases
    connection.select_values("SELECT datname FROM pg_database WHERE datname LIKE '#{described_class::SCRATCH_PREFIX}%'")
  end

  def compatible_pg_dump?
    client = Open3.capture2('pg_dump', '--version').first[/\d+/].to_i
    client >= connection.select_value('SHOW server_version_num').to_i / 10_000
  rescue Errno::ENOENT
    false
  end

  def dump_database
    FileUtils.mkdir_p(dump_path.dirname)
    Backups::DatabaseDumpJob.new.send(:dump_to, dump_path)
  end

  before { FileUtils.mkdir_p(dir.join('database')) }

  after do
    InstanceSetting.where(key: 'photon_api_key').delete_all
    BackupRun.delete_all
    FileUtils.rm_rf(dir)
  end

  describe 'a real dump' do
    before do
      skip 'no pg_dump at least as new as the test database' unless compatible_pg_dump?
      InstanceSetting.create!(key: 'photon_api_key', value: 'secret')
    end

    it 'restores it into a temporary database, reports what it found and cleans up' do
      dump_database
      before_digest = Digest::SHA256.file(dump_path).hexdigest

      result = verifier.call

      expect(result['state']).to eq('passed')
      expect(result['problems']).to be_empty
      expect(result['schema_version']).to eq(verifier.code_version)
      expect(result['counts']).to include('users', 'points')
      expect(result['encrypted_checked']).to be >= 1
      expect(result['sha256']).to eq(before_digest)
      expect(result['bytes']).to eq(File.size(dump_path))
      expect(scratch_databases).to be_empty
      expect(Digest::SHA256.file(dump_path).hexdigest).to eq(before_digest)
    end

    it 'fails when encrypted values do not decrypt with this instance keys' do
      # Raw SQL, since update_column would encrypt the bogus ciphertext with the right key.
      connection.execute(<<~SQL.squish)
        UPDATE instance_settings SET encrypted_value = '{"p":"bm9wZQ==","h":{"iv":"AAAAAAAAAAAAAAAA","at":"AAAAAAAAAAAAAAAAAAAAAA=="}}'
        WHERE key = 'photon_api_key'
      SQL
      dump_database

      result = verifier.call

      expect(result['state']).to eq('failed')
      expect(result['problems']).to include({ 'code' => 'undecryptable', 'count' => 1 })
    end

    it 'fails for a dump made by newer code and warns for older code' do
      dump_database
      dumped = verifier.code_version

      allow(verifier).to receive(:code_version).and_return(dumped - 1)
      expect(verifier.call['problems']).to include({ 'code' => 'newer_schema' })

      allow(verifier).to receive(:code_version).and_return(dumped + 1)
      result = verifier.call
      expect(result['state']).to eq('passed')
      expect(result['warnings']).to include({ 'code' => 'older_schema' })
    end

    it 'drops a temporary database left behind by a killed worker' do
      connection.execute("CREATE DATABASE #{described_class::SCRATCH_PREFIX}leftover TEMPLATE template0")
      dump_database

      verifier.call

      expect(scratch_databases).to be_empty
    end
  end

  it 'fails a file pg_restore cannot read and still drops the temporary database' do
    File.write(dump_path, 'not a dump')

    result = verifier.call

    expect(result['state']).to eq('failed')
    expect(result['problems'].first['code']).to eq('unreadable')
    expect(scratch_databases).to be_empty
    expect(File.read(dump_path)).to eq('not a dump')
  end

  describe '#check!' do
    it 'refuses anything but a completed database dump that is still on disk' do
      expect { verifier.check! }.to raise_error(described_class::Unavailable, 'file_missing')

      run.update!(status: :failed)
      expect { verifier.check! }.to raise_error(described_class::Unavailable, 'not_a_dump')

      run.update!(status: :completed, file_name: '../db.pgcustom')
      FileUtils.touch(dir.join('db.pgcustom'))
      expect { verifier.check! }.to raise_error(described_class::Unavailable, 'file_missing')
    end
  end
end
