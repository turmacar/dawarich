# frozen_string_literal: true

# Daily cron entry point. Decides whether a scheduled backup is due and fans out one
# job per user; the admin's "Run now" passes force: true.
class Backups::RunJob < ApplicationJob
  queue_as :exports

  sidekiq_options retry: false

  INTERVALS = { 'daily' => 1.day, 'weekly' => 1.week, 'monthly' => 1.month }.freeze
  # The cron tick can land a little before the interval has fully elapsed.
  TOLERANCE = 1.hour

  def perform(force: false)
    return unless force || due?
    return log_skip('a backup is already running') if BackupRun.active.exists?

    Backups::Destination.new.root
    User.find_each { |user| Backups::UserExportJob.perform_later(user.id) }
    Backups::DatabaseDumpJob.perform_later if InstanceSettings::Resolver.value(:backup_database_dump)
  rescue Backups::Destination::Unavailable => e
    notify_admins(e.message)
  end

  private

  def due?
    interval = INTERVALS[InstanceSettings::Resolver.value(:backup_export_frequency)]
    return false if interval.nil?

    last = BackupRun.kind_user_export.status_completed.maximum(:started_at)
    last.nil? || last <= (interval - TOLERANCE).ago
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
