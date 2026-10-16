# frozen_string_literal: true

require 'open3'

# Dumps the whole database with pg_dump in custom format, for exact restores with pg_restore.
class Backups::DatabaseDumpJob < ApplicationJob
  queue_as :exports

  sidekiq_options retry: false

  def perform(run_id)
    run = BackupRun.kind_database_dump.status_running.find_by(id: run_id) || return
    filename = "dawarich_db_#{Time.current.strftime('%Y%m%d_%H%M%S')}.pgcustom"

    begin
      directory = Backups::Destination.new.subdirectory('database')
      result = Backups::Writer.new(directory).write(filename) { |_file, partial| dump_to(partial) }
      run.complete!(file_name: filename, bytes: result.bytes)
      prune(directory)
    rescue StandardError => e
      run.fail!(e.message)
      ExceptionReporter.call(e, 'Scheduled database dump failed')
      notify_admins(e.message)
    end
  end

  private

  def dump_to(path)
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    # The password travels in the environment, never on the command line.
    env = config[:password].present? ? { 'PGPASSWORD' => config[:password].to_s } : {}

    _out, err, status = Open3.capture3(env, *command(config, path))
    raise "pg_dump failed: #{err.to_s.strip.truncate(500)}" unless status.success?
  end

  def command(config, path)
    args = ['pg_dump', '--format=custom', '--file', path.to_s]
    args += ['--host', config[:host].to_s] if config[:host].present?
    args += ['--port', config[:port].to_s] if config[:port].present?
    args += ['--username', config[:username].to_s] if config[:username].present?
    args << config[:database].to_s
  end

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
