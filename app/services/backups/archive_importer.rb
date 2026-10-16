# frozen_string_literal: true

module Backups
  # Starts an import of an automated user-data backup, for the account it was made from,
  # through the same Import record an upload creates.
  class ArchiveImporter
    class Unavailable < StandardError; end

    def initialize(run, destination: Backups::Destination.new)
      @run = run
      @destination = destination
    end

    def call
      validate!
      import = user.imports.build(name: unique_name, source: :user_data_archive)
      File.open(path, 'rb') do |file|
        import.file.attach(io: file, filename: run.file_name, content_type: 'application/zip')
        import.save!
      end
      import
    end

    private

    attr_reader :run, :destination

    delegate :user, to: :run

    def validate!
      raise Unavailable, :not_an_archive unless run.kind_user_export? && run.status_completed? && run.file_name.present?
      raise Unavailable, :user_gone if user.nil?
      raise Unavailable, :file_missing unless File.file?(path)
    end

    # The name comes from our own run record, and is still checked against the directory.
    def path
      @path ||= begin
        raise Unavailable, :file_missing unless run.file_name == File.basename(run.file_name)

        destination.root.join('user-exports', run.file_name)
      end
    end

    def unique_name
      return run.file_name unless user.imports.exists?(name: run.file_name)

      "#{File.basename(run.file_name, '.zip')}_#{Time.current.strftime('%Y%m%d_%H%M%S')}.zip"
    end
  end
end
