# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Backups::VerifyJob, type: :job do
  let(:run) { create(:backup_run, :database_dump, :completed, file_name: 'db.pgcustom') }
  let(:verifier) { instance_double(Backups::Verifier) }

  before { allow(Backups::Verifier).to receive(:new).and_return(verifier) }

  it 'stores the result of a started verification' do
    run.start_verification!
    allow(verifier).to receive(:call).and_return({ 'state' => 'passed', 'problems' => [], 'warnings' => [] })

    described_class.perform_now(run.id)

    expect(run.reload.verification_state).to eq('passed')
    expect(run.verified_at).to be_present
  end

  it 'does nothing unless a verification was started' do
    allow(verifier).to receive(:call)

    described_class.perform_now(run.id)
    described_class.perform_now(0)

    expect(verifier).not_to have_received(:call)
    expect(run.reload.verification).to be_nil
  end

  it 'records why it could not verify' do
    run.start_verification!
    allow(verifier).to receive(:call).and_raise(Backups::Verifier::Unavailable, 'file_missing')

    described_class.perform_now(run.id)

    expect(run.reload.verification_state).to eq('failed')
    expect(run.verification['problems']).to eq([{ 'code' => 'file_missing' }])
  end

  it 'records unexpected errors instead of leaving the run verifying' do
    run.start_verification!
    allow(verifier).to receive(:call).and_raise(PG::ConnectionBad, 'permission denied to create database')
    allow(ExceptionReporter).to receive(:call)

    described_class.perform_now(run.id)

    expect(run.reload.verification['problems'].first)
      .to eq({ 'code' => 'error', 'detail' => 'permission denied to create database' })
    expect(ExceptionReporter).to have_received(:call)
  end

  it 'stops treating a crashed verification as running' do
    run.start_verification!
    run.update_column(:updated_at, (BackupRun::STALE_AFTER + 1.minute).ago)

    expect(run.reload.verification_state).to be_nil
    expect(BackupRun.verifying).to be_empty
  end
end
