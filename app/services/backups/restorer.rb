# frozen_string_literal: true

require 'open3'

module Backups
  # Replaces the live database with a verified dump. A safety dump of the current database
  # is written first, and the restore runs in one transaction, so a failure at any point
  # before it commits leaves the database exactly as it was.
  class Restorer
    class Unavailable < StandardError; end

    CONFIRMATION = 'RESTORE'
    JOBS_TIMEOUT = 10.minutes

    def initialize(source, destination: Backups::Destination.new)
      @source = source
      @destination = destination
    end

    def check!(restore_run: nil)
      raise Unavailable, :not_verified unless source.verifiable? && source.verification_state == 'passed'
      raise Unavailable, :file_missing unless source.file_name == File.basename(source.file_name) && File.file?(path)

      others = BackupRun.active.or(BackupRun.verifying)
      others = others.where.not(id: restore_run.id) if restore_run
      raise Unavailable, :busy if others.exists?
    end

    def call(restore_run)
      check!(restore_run: restore_run)
      raise Unavailable, :changed unless Digest::SHA256.file(path).hexdigest == source.verification['sha256']

      history = BackupRun.order(:id).map(&:attributes)
      Backups::Maintenance.hold(run_id: restore_run.id) do
        run_steps
        @finishing = true
        finish(restore_run, history)
      rescue StandardError => e
        @finishing ? mark_failed(restore_run, e) : finish(restore_run, history, error: e)
        raise
      end
      @safety
    end

    private

    attr_reader :source, :destination

    def run_steps
      wait_for_running_jobs
      Backups::Maintenance.step!('safety_dump')
      @safety = safety_dump
      Backups::Maintenance.step!('restoring')
      Backups::Postgres.restore(path, database: Backups::Postgres.config[:database].to_s)
      @restored = true
      Backups::Maintenance.step!('migrating')
      migrate!
    end

    def path
      @path ||= destination.root.join('database', source.file_name)
    end

    def wait_for_running_jobs
      deadline = JOBS_TIMEOUT.from_now
      sleep 2 while other_jobs_running? && Time.current < deadline
    end

    def other_jobs_running?
      Sidekiq::WorkSet.new.any? { |_process, _thread, work| work.job.display_class != 'Backups::RestoreJob' }
    end

    def safety_dump
      name = "dawarich_db_#{Time.current.strftime('%Y%m%d_%H%M%S')}_pre-restore.pgcustom"
      started_at = Time.current
      result = Backups::Writer.new(destination.subdirectory('database')).write(name) do |_file, partial|
        Backups::Postgres.dump(partial)
      end
      { file_name: name, bytes: result.bytes, started_at: started_at, finished_at: Time.current }
    end

    # Brings a dump from an older version up to this code, the same way container start does.
    def migrate!
      out, status = Open3.capture2e('bundle', 'exec', 'rails', 'db:migrate', 'data:migrate', chdir: Rails.root.to_s)
      raise Backups::Postgres::Failed, "Migrations failed: #{out.strip.last(500)}" unless status.success?
    end

    # The restore replaced backup_runs with the dump's copy; put back the history as it was,
    # so the backups on disk stay listed and retention keeps tracking them.
    def finish(restore_run, history, error: nil)
      reconnect!
      rebuild_history(history) if @restored
      BackupRun.create!(kind: :database_dump, status: :completed, **@safety) if @safety
      run = BackupRun.find_by(id: restore_run.id)
      error ? run&.fail!(error.message) : run&.complete!(file_name: source.file_name, bytes: source.bytes)
      InstanceSettings::Resolver.reset!
      InstanceSettings::Notifier.publish('backup_restore')
    end

    def mark_failed(restore_run, error)
      reconnect!
      BackupRun.find_by(id: restore_run.id)&.fail!(error.message)
    rescue StandardError => e
      Rails.logger.error("[Backups] could not record the failed restore: #{e.class}: #{e.message}")
    end

    def reconnect!
      ActiveRecord::Base.connection_pool.disconnect!
      ApplicationRecord.descendants.each(&:reset_column_information)
    end

    def rebuild_history(history)
      users = User.where(id: history.pluck('user_id').compact).pluck(:id).to_set
      exports = Export.where(id: history.pluck('export_id').compact).pluck(:id).to_set
      rows = history.map do |row|
        row.slice(*BackupRun.column_names)
           .merge('user_id' => users.include?(row['user_id']) ? row['user_id'] : nil,
                  'export_id' => exports.include?(row['export_id']) ? row['export_id'] : nil)
      end

      BackupRun.transaction do
        BackupRun.delete_all
        BackupRun.insert_all!(rows) if rows.any?
      end
      BackupRun.connection.reset_pk_sequence!(BackupRun.table_name)
    end
  end
end
