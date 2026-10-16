# frozen_string_literal: true

module Backups
  # Keeps the newest completed runs in a scope and deletes the rest, along with their
  # files. It only ever touches files named by a BackupRun row, never other contents.
  class Retention
    FAILED_RUN_TTL = 30.days

    def initialize(scope:, directory:, keep:)
      @scope = scope
      @directory = Pathname.new(directory)
      @keep = keep
    end

    def call
      @scope.status_completed.recent.offset(@keep).each { |run| prune(run) }
      @scope.status_failed.where(finished_at: ..FAILED_RUN_TTL.ago).destroy_all
    end

    private

    def prune(run)
      remove_file(run.file_name)
      run.destroy!
    rescue SystemCallError => e
      Rails.logger.warn("[Backups] could not remove #{run.file_name}: #{e.message}")
    end

    def remove_file(name)
      return if name.blank? || name != File.basename(name)

      path = @directory.join(name)
      File.delete(path) if File.file?(path)
    end
  end
end
