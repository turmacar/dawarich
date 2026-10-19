# frozen_string_literal: true

# Cron entry point, ticking every 15 minutes. Decides whether a scheduled backup is due
# (a full interval of calendar days since the last run, at the configured time of day) and
# queues the work; the admin's "Back up now" passes force: true.
class Backups::RunJob < ApplicationJob
  queue_as :exports

  sidekiq_options retry: false

  INTERVALS = { 'daily' => 1.day, 'weekly' => 1.week, 'monthly' => 1.month }.freeze
  # A failed attempt is retried the next day at most, even for weekly and monthly schedules.
  RETRY_AFTER = 1.day
  LOCK_KEY = 'backups-run'

  def perform(force: false)
    queued = ActiveRecord::Base.with_advisory_lock(LOCK_KEY, timeout_seconds: 0) do
      start(force)
      true
    end
    log_skip('another backup is being queued') unless queued
  rescue Backups::Destination::Unavailable => e
    notify_admins(e.message)
  end

  private

  # Checking for a running backup and creating the runs share one lock, so two ticks or two
  # clicks cannot both pass the check before either has created a run.
  def start(force)
    return unless force || due?
    return log_skip('a backup is already running') if BackupRun.active.exists?

    Backups::Destination.new.root
    User.find_each { |user| queue(Backups::UserExportJob, kind: :user_export, user: user) }
    queue(Backups::DatabaseDumpJob, kind: :database_dump) if InstanceSettings::Resolver.value(:backup_database_dump)
  end

  # The run row exists before the worker starts, so a backed-up queue cannot cause the next
  # tick to queue the same backup again.
  def queue(job_class, **attributes)
    run = BackupRun.create!(started_at: Time.current, **attributes)
    job_class.perform_later(run.id)
  end

  def due?
    interval = INTERVALS[InstanceSettings::Resolver.value(:backup_export_frequency)]
    return false if interval.nil?

    slot = latest_slot
    interval_elapsed?(BackupRun.kind_user_export.status_completed.maximum(:started_at), interval, slot) &&
      interval_elapsed?(BackupRun.kind_user_export.maximum(:started_at), [interval, RETRY_AFTER].min, slot)
  end

  # The latest moment the configured time of day has come, today's or yesterday's.
  def latest_slot
    now = Time.zone.now
    hour, minute = configured_time.split(':').map(&:to_i)
    slot = now.change(hour: hour, min: minute)
    slot > now ? slot - 1.day : slot
  end

  # Counts calendar days from the date of the last run, so the run stays at the configured time
  # instead of drifting with how long a run took or how late a manual run was.
  def interval_elapsed?(last, interval, slot)
    return slot.to_date == Time.zone.today if last.nil? # the first backup also waits for today's time

    last < slot && slot.to_date >= last.in_time_zone.to_date + interval
  end

  # A pinned variable skips the form validation, so a malformed value must not stop backups.
  def configured_time
    value = InstanceSettings::Resolver.value(:backup_export_time).to_s
    return value if value.match?(InstanceSettings::BackupInput::TIME_FORMAT)

    InstanceSettings::Registry.fetch(:backup_export_time).default
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
