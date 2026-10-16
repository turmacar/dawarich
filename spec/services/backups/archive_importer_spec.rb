# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Backups::ArchiveImporter do
  include ActiveJob::TestHelper

  around do |example|
    Dir.mktmpdir('backups-archive-importer') do |dir|
      @dir = dir
      FileUtils.mkdir_p(File.join(dir, 'user-exports'))
      example.run
    end
  end

  let(:user) { create(:user, email: 'alice@example.com') }
  let(:destination) { Backups::Destination.new(@dir) }

  def write_archive(name, content = 'zip-bytes')
    File.binwrite(File.join(@dir, 'user-exports', name), content)
  end

  def completed_run(name:, **attributes)
    create(:backup_run, :completed, user: user, file_name: name, **attributes)
  end

  def import_for(run)
    described_class.new(run, destination: destination).call
  end

  it 'creates an archive import for the account the backup was made from' do
    write_archive('alice.zip', 'archive-content')
    run = completed_run(name: 'alice.zip')

    import = import_for(run)

    expect(import).to be_persisted
    expect(import).to have_attributes(user: user, source: 'user_data_archive', name: 'alice.zip')
    expect(import.file.download).to eq('archive-content')
  end

  it 'processes it like an uploaded archive' do
    write_archive('alice.zip')
    run = completed_run(name: 'alice.zip')

    expect { import_for(run) }.to have_enqueued_job(Import::ProcessJob)
  end

  it 'leaves the backup file in place' do
    write_archive('alice.zip', 'keep me')
    run = completed_run(name: 'alice.zip')

    import_for(run)

    expect(File.read(File.join(@dir, 'user-exports', 'alice.zip'))).to eq('keep me')
    expect(BackupRun.exists?(run.id)).to be(true)
  end

  it 'picks a new name when the account already has an import with that name' do
    write_archive('alice.zip')
    create(:import, user: user, name: 'alice.zip')
    run = completed_run(name: 'alice.zip')

    expect(import_for(run).name).to match(/\Aalice_\d{8}_\d{6}\.zip\z/)
  end

  it 'refuses a backup that is not a completed user export' do
    write_archive('alice.zip')
    [create(:backup_run, user: user, file_name: 'alice.zip'),
     create(:backup_run, user: user, status: :failed, file_name: 'alice.zip'),
     create(:backup_run, :database_dump, :completed, file_name: 'alice.zip')].each do |run|
      expect { import_for(run) }.to raise_error(described_class::Unavailable), "#{run.kind}/#{run.status} not refused"
    end
  end

  it 'refuses when the account no longer exists' do
    write_archive('alice.zip')
    run = completed_run(name: 'alice.zip')
    user.destroy!

    expect { import_for(run.reload) }.to raise_error(described_class::Unavailable)
  end

  it 'refuses when the file is gone' do
    run = completed_run(name: 'missing.zip')

    expect { import_for(run) }.to raise_error(described_class::Unavailable)
  end

  it 'never reads outside the backup directory' do
    File.write(File.join(@dir, 'secret.txt'), 'private')
    run = completed_run(name: '../secret.txt')

    expect { expect { import_for(run) }.to raise_error(described_class::Unavailable) }.not_to change(Import, :count)
  end
end
