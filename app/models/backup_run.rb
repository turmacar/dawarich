# frozen_string_literal: true

# One scheduled or manual backup attempt: a user-data export or a database dump.
class BackupRun < ApplicationRecord
  # A crashed worker never reports back, so a run older than this no longer blocks new ones.
  STALE_AFTER = 6.hours

  belongs_to :user, optional: true
  belongs_to :export, optional: true

  enum :kind, { user_export: 0, database_dump: 1 }, prefix: :kind
  enum :status, { running: 0, completed: 1, failed: 2 }, prefix: :status

  validates :kind, :started_at, presence: true
  validates :user, presence: true, if: :kind_user_export?

  scope :recent, -> { order(started_at: :desc, id: :desc) }
  scope :active, -> { status_running.where(started_at: STALE_AFTER.ago..) }

  def complete!(file_name:, bytes:)
    update!(status: :completed, file_name: file_name, bytes: bytes, finished_at: Time.current, error: nil)
  end

  def fail!(message)
    update!(status: :failed, error: message.to_s.truncate(2000), finished_at: Time.current)
  end
end
