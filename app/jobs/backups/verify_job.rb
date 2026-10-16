# frozen_string_literal: true

class Backups::VerifyJob < ApplicationJob
  queue_as :exports

  sidekiq_options retry: false

  def perform(run_id)
    run = BackupRun.find_by(id: run_id)
    return unless run&.verification_state == 'running'

    BackupRun.with_advisory_lock('backups-verify', timeout_seconds: 0) do
      run.finish_verification!(Backups::Verifier.new(run).call)
    end || run.finish_verification!(failure('busy'))
  rescue Backups::Verifier::Unavailable => e
    run.finish_verification!(failure(e.message))
  rescue Backups::Destination::Unavailable => e
    run.finish_verification!(failure('unavailable', e.message))
  rescue StandardError => e
    ExceptionReporter.call(e, 'Backup verification failed')
    run&.finish_verification!(failure('error', e.message.truncate(500)))
  end

  private

  def failure(code, detail = nil)
    { 'state' => 'failed', 'problems' => [{ 'code' => code, 'detail' => detail }.compact], 'warnings' => [] }
  end
end
