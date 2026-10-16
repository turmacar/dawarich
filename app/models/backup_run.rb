# frozen_string_literal: true

# One scheduled or manual backup attempt: a user-data export or a database dump.
class BackupRun < ApplicationRecord
  # A crashed worker never reports back, so a run older than this no longer blocks new ones.
  STALE_AFTER = 6.hours

  belongs_to :user, optional: true
  belongs_to :export, optional: true

  enum :kind, { user_export: 0, database_dump: 1, database_restore: 2 }, prefix: :kind
  enum :status, { running: 0, completed: 1, failed: 2 }, prefix: :status

  validates :kind, :started_at, presence: true
  validates :user, presence: true, if: :kind_user_export?

  scope :recent, -> { order(started_at: :desc, id: :desc) }
  scope :active, -> { status_running.where(started_at: STALE_AFTER.ago..) }
  scope :verifying, -> { where("verification->>'state' = 'running'").where(updated_at: STALE_AFTER.ago..) }

  def verification_state
    state = verification&.dig('state')
    state == 'running' && updated_at < STALE_AFTER.ago ? nil : state
  end

  def verifiable?
    kind_database_dump? && status_completed? && file_name.present?
  end

  def start_verification!
    update!(verification: { 'state' => 'running' }, verified_at: nil)
  end

  def finish_verification!(result)
    update!(verification: result, verified_at: Time.current)
  end

  def complete!(file_name:, bytes:)
    update!(status: :completed, file_name: file_name, bytes: bytes, finished_at: Time.current, error: nil)
  end

  def fail!(message)
    update!(status: :failed, error: message.to_s.truncate(2000), finished_at: Time.current)
  end
end
