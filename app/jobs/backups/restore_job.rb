# frozen_string_literal: true

class Backups::RestoreJob < ApplicationJob
  queue_as :highest_priority

  sidekiq_options retry: false

  def perform(restore_run_id, source_run_id)
    restore_run = BackupRun.kind_database_restore.status_running.find_by(id: restore_run_id) || return
    source = BackupRun.find_by(id: source_run_id)
    return fail_run(restore_run, I18n.t('admin.settings.restore_backup.not_found')) unless source

    safety = Backups::Restorer.new(source).call(restore_run)
    notify_admins(:info, 'restored', file: source.file_name, safety: safety&.dig(:file_name))
  rescue Backups::Restorer::Unavailable => e
    fail_run(restore_run, I18n.t("admin.settings.restore_backup.#{e.message}"))
  rescue StandardError => e
    ExceptionReporter.call(e, 'Database restore failed')
    notify_admins(:error, 'failed', error: e.message.truncate(500))
  ensure
    Backups::Maintenance.finish!
  end

  private

  def fail_run(run, message)
    run.fail!(message)
    notify_admins(:error, 'failed', error: message)
  end

  def notify_admins(kind, key, **values)
    User.where(admin: true).find_each do |admin|
      I18n.with_locale(admin.locale) do
        Notifications::Create.new(
          user: admin,
          kind: kind,
          title: I18n.t("jobs.backups.restore.#{key}_title"),
          content: I18n.t("jobs.backups.restore.#{key}_content", **values)
        ).call
      end
    end
  rescue StandardError => e
    Rails.logger.error("[Backups] could not notify admins about the restore: #{e.class}: #{e.message}")
  end
end
