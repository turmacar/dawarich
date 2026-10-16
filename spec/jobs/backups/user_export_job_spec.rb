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
  let!(:run) { create(:backup_run, user: user) }
  let(:exports_dir) { Pathname.new(@dir).join('user-exports') }

  before { create(:point, user: user) }

  def written_files
    exports_dir.children.map { _1.basename.to_s }
  end

  describe 'a successful backup' do
    it 'writes a readable archive named after the user and completes the run' do
      described_class.perform_now(run.id)

      run.reload
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
      expect { described_class.perform_now(run.id) }
        .not_to(change { [user.exports.count, user.notifications.count] })
    end

    it 'prunes older backups beyond the retention count' do
      InstanceSetting.create!(key: 'backup_export_retention', value: 1)
      InstanceSettings::Resolver.reset!
      FileUtils.mkdir_p(exports_dir)
      File.write(exports_dir.join('old.zip'), 'old')
      old = create(:backup_run, :completed, user: user, file_name: 'old.zip', started_at: 2.days.ago)

      described_class.perform_now(run.id)

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

      described_class.perform_now(run.id)

      expect(written_files).to include('theirs.zip')
    end
  end

  describe 'a failed backup' do
    let!(:admin) { create(:user, admin: true) }

    it 'records the failure, tells the admins and leaves no stored export behind' do
      allow_any_instance_of(Backups::Writer).to receive(:write).and_raise(Errno::ENOSPC)

      expect { described_class.perform_now(run.id) }.to change { admin.notifications.error.count }.by(1)

      expect(user.exports.count).to eq(0)
      expect(run.reload).to be_status_failed
      expect(run.error).to include('No space left')
    end

    it 'fails the run instead of writing elsewhere when the directory is gone' do
      InstanceSetting.find_by!(key: 'backup_export_path').update!(value: File.join(@dir, 'gone'))
      InstanceSettings::Resolver.reset!

      expect { described_class.perform_now(run.id) }.to change { admin.notifications.error.count }.by(1)

      expect(run.reload).to be_status_failed
      expect(run.error).to include('does not exist')
      expect(File.exist?(File.join(@dir, 'gone'))).to be(false)
    end
  end

  describe 'a run that should not be worked' do
    it 'ignores a run that is no longer running' do
      run.complete!(file_name: 'done.zip', bytes: 1)

      expect { described_class.perform_now(run.id) }.not_to(change { exports_dir.exist? })
    end

    it 'ignores a run that does not exist' do
      expect { described_class.perform_now(0) }.not_to change(BackupRun, :count)
    end

    it 'drops the run when its user has been deleted' do
      user.destroy!

      expect { described_class.perform_now(run.id) }.to change(BackupRun, :count).by(-1)
    end
  end
end
