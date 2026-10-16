# frozen_string_literal: true

# Cron entry point, ticking every 15 minutes. Decides whether a scheduled backup is due
# (frequency elapsed and the configured time of day reached) and queues the work; the
# admin's "Back up now" passes force: true.
class Backups::RunJob < ApplicationJob
  queue_as :exports

  sidekiq_options retry: false

  INTERVALS = { 'daily' => 1.day, 'weekly' => 1.week, 'monthly' => 1.month }.freeze
  # The configured time anchors each run, so a run may start a little before the full interval.
  TOLERANCE = 1.hour
  # A failed attempt is retried the next day at most, even for weekly and monthly schedules.
  RETRY_AFTER = 1.day

  def perform(force: false)
    return unless force || due?
    return log_skip('a backup is already running') if BackupRun.active.exists?

    Backups::Destination.new.root
    User.find_each { |user| queue(Backups::UserExportJob, kind: :user_export, user: user) }
    queue(Backups::DatabaseDumpJob, kind: :database_dump) if InstanceSettings::Resolver.value(:backup_database_dump)
  rescue Backups::Destination::Unavailable => e
    notify_admins(e.message)
  end

  private

  # The run row exists before the worker starts, so a backed-up queue cannot cause the next
  # tick to queue the same backup again.
  def queue(job_class, **attributes)
    run = BackupRun.create!(started_at: Time.current, **attributes)
    job_class.perform_later(run.id)
  end

  def due?
    interval = INTERVALS[InstanceSettings::Resolver.value(:backup_export_frequency)]
    return false if interval.nil? || !time_reached?

    completed_long_ago?(interval) && attempted_long_ago?(interval)
  end

  def time_reached?
    now = Time.zone.now
    hour, minute = configured_time.split(':').map(&:to_i)
    now >= now.change(hour: hour, min: minute)
  end

  # A pinned variable skips the form validation, so a malformed value must not stop backups.
  def configured_time
    value = InstanceSettings::Resolver.value(:backup_export_time).to_s
    return value if value.match?(InstanceSettings::BackupInput::TIME_FORMAT)

    InstanceSettings::Registry.fetch(:backup_export_time).default
  end

  def completed_long_ago?(interval)
    last = BackupRun.kind_user_export.status_completed.maximum(:started_at)
    last.nil? || last <= (interval - TOLERANCE).ago
  end

  def attempted_long_ago?(interval)
    last = BackupRun.kind_user_export.maximum(:started_at)
    last.nil? || last <= ([interval, RETRY_AFTER].min - TOLERANCE).ago
  end

  def log_skip(reason)
    Rails.logger.info("[Backups] skipping scheduled run: #{reason}")
  end

  def notify_admins(reason)
    User.where(admin: true).find_each do |admin|
      I18n.with_locale(admin.locale) do
        Notifications::Create.new(
          user: admin,
          kind: :error,
          title: I18n.t('jobs.backups.run.unavailable_title'),
          content: I18n.t('jobs.backups.run.unavailable_content', reason: reason)
        ).call
      end
    end
  end
end
