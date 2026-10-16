# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Backups::UserExportJob, type: :job do
  around do |example|
    Dir.mktmpdir('backups-user-export') do |dir|
      @dir = dir
      InstanceSetting.create!(key: 'backup_export_path', value: dir)
      InstanceSettings::Resolver.reset!
      example.run
    end
  ensure
    InstanceSettings::Resolver.reset!
  end

  let(:user) { create(:user, email: 'alice@example.com') }
  let(:exports_dir) { Pathname.new(@dir).join('user-exports') }

  before { create(:point, user: user) }

  def written_files
    exports_dir.children.map { _1.basename.to_s }
  end

  describe 'a successful backup' do
    it 'writes a readable archive named after the user and records the run' do
      described_class.perform_now(user.id)

      run = BackupRun.kind_user_export.last
      expect(run).to be_status_completed
      expect(written_files).to eq([run.file_name])
      expect(run.file_name).to match(/\Aalice_example\.com-#{user.id}_\d{8}_\d{6}\.zip\z/)
      expect(run.bytes).to eq(File.size(exports_dir.join(run.file_name)))

      Zip::File.open(exports_dir.join(run.file_name).to_s) do |zip|
        manifest = JSON.parse(zip.find_entry('manifest.json').get_input_stream.read)
        expect(manifest['counts']['points']).to eq(1)
      end
    end

    it 'does not leave the stored export or send the usual completion notification' do
      expect { described_class.perform_now(user.id) }
        .not_to(change { [user.exports.count, user.notifications.count] })
    end

    it 'prunes older backups beyond the retention count' do
      InstanceSetting.create!(key: 'backup_export_retention', value: 1)
      InstanceSettings::Resolver.reset!
      FileUtils.mkdir_p(exports_dir)
      File.write(exports_dir.join('old.zip'), 'old')
      old = create(:backup_run, :completed, user: user, file_name: 'old.zip', started_at: 2.days.ago)

      described_class.perform_now(user.id)

      expect(BackupRun.exists?(old.id)).to be(false)
      expect(written_files).not_to include('old.zip')
      expect(BackupRun.kind_user_export.status_completed.count).to eq(1)
    end

    it 'keeps other users backups when pruning' do
      InstanceSetting.create!(key: 'backup_export_retention', value: 1)
      InstanceSettings::Resolver.reset!
      other = create(:user)
      FileUtils.mkdir_p(exports_dir)
      File.write(exports_dir.join('theirs.zip'), 'theirs')
      create(:backup_run, :completed, user: other, file_name: 'theirs.zip', started_at: 5.days.ago)

      described_class.perform_now(user.id)

      expect(written_files).to include('theirs.zip')
    end
  end

  describe 'a failed backup' do
    let!(:admin) { create(:user, admin: true) }

    before { allow_any_instance_of(Backups::Writer).to receive(:write).and_raise(Errno::ENOSPC) }

    it 'records the failure, tells the admins and leaves no stored export behind' do
      expect { described_class.perform_now(user.id) }.to change { admin.notifications.error.count }.by(1)

      expect(user.exports.count).to eq(0)
      run = BackupRun.kind_user_export.last
      expect(run).to be_status_failed
      expect(run.error).to include('No space left')
    end
  end

  it 'skips a user that no longer exists' do
    expect { described_class.perform_now(0) }.not_to change(BackupRun, :count)
  end

  it 'refuses to run without a usable directory instead of writing elsewhere' do
    InstanceSetting.where(key: 'backup_export_path').update_all(value: File.join(@dir, 'gone').to_json)
    InstanceSettings::Resolver.reset!

    expect { described_class.perform_now(user.id) }.to raise_error(Backups::Destination::Unavailable)
    expect(BackupRun.count).to eq(0)
  end
end
