# frozen_string_literal: true

# Dumps the whole database with pg_dump in custom format, for exact restores with pg_restore.
class Backups::DatabaseDumpJob < ApplicationJob
  queue_as :exports

  sidekiq_options retry: false

  def perform(run_id)
    run = BackupRun.kind_database_dump.status_running.find_by(id: run_id) || return
    filename = "dawarich_db_#{Time.current.strftime('%Y%m%d_%H%M%S')}.pgcustom"

    begin
      directory = Backups::Destination.new.subdirectory('database')
      result = Backups::Writer.new(directory).write(filename) { |_file, partial| Backups::Postgres.dump(partial) }
      run.complete!(file_name: filename, bytes: result.bytes)
      prune(directory)
    rescue StandardError => e
      run.fail!(e.message)
      ExceptionReporter.call(e, 'Scheduled database dump failed')
      notify_admins(e.message)
    end
  end

  private

  def prune(directory)
    Backups::Retention.new(
      scope: BackupRun.kind_database_dump,
      directory: directory,
      keep: InstanceSettings::Resolver.value(:backup_export_retention)
    ).call
  end

  def notify_admins(error)
    User.where(admin: true).find_each do |admin|
      I18n.with_locale(admin.locale) do
        Notifications::Create.new(
          user: admin,
          kind: :error,
          title: I18n.t('jobs.backups.database_dump.failed_title'),
          content: I18n.t('jobs.backups.database_dump.failed_content', error: error)
        ).call
      end
    end
  end
end
