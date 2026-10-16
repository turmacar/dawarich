# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Backups::RestoreJob, type: :job do
  let!(:admin) { create(:user, admin: true) }
  let(:source) { create(:backup_run, :database_dump, :completed, file_name: 'db.pgcustom') }
  let(:run) { create(:backup_run, kind: :database_restore, user: nil, file_name: 'db.pgcustom') }
  let(:restorer) { instance_double(Backups::Restorer) }

  before do
    allow(Backups::Restorer).to receive(:new).with(source).and_return(restorer)
    Backups::Maintenance.start!(run_id: run.id, step: 'queued')
  end

  after { Backups::Maintenance.finish! }

  it 'restores and tells the admins where the safety dump is' do
    allow(restorer).to receive(:call).with(run).and_return({ file_name: 'safety.pgcustom' })

    expect { described_class.perform_now(run.id, source.id) }.to change { admin.notifications.info.count }.by(1)

    expect(admin.notifications.last.content).to include('db.pgcustom', 'safety.pgcustom')
    expect(Backups::Maintenance.current).to be_nil
  end

  it 'fails the run with the reason when the restore is refused' do
    allow(restorer).to receive(:call).and_raise(Backups::Restorer::Unavailable, 'changed')

    expect { described_class.perform_now(run.id, source.id) }.to change { admin.notifications.error.count }.by(1)

    expect(run.reload.error).to eq(I18n.t('admin.settings.restore_backup.changed'))
    expect(Backups::Maintenance.current).to be_nil
  end

  it 'reports a failed restore and ends maintenance' do
    allow(restorer).to receive(:call).and_raise(Backups::Postgres::Failed, 'ERROR: out of disk space')
    allow(ExceptionReporter).to receive(:call)

    expect { described_class.perform_now(run.id, source.id) }.to change { admin.notifications.error.count }.by(1)

    expect(admin.notifications.last.content).to include('out of disk space')
    expect(Backups::Maintenance.current).to be_nil
  end

  it 'ignores a restore run that is no longer running' do
    run.update!(status: :failed)
    allow(restorer).to receive(:call)

    described_class.perform_now(run.id, source.id)

    expect(restorer).not_to have_received(:call)
  end
end
