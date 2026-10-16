# frozen_string_literal: true

module Backups
  # Writes one backup file so a reader never sees a half-written one: the block fills
  # a hidden temporary file, which is renamed into place only after it succeeds.
  class Writer
    Result = Struct.new(:path, :bytes)

    def initialize(directory)
      @directory = Pathname.new(directory)
    end

    def write(filename)
      validate!(filename)
      final = @directory.join(filename)
      partial = @directory.join(".#{filename}.partial")

      File.open(partial, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.binmode
        yield file, partial
      end
      File.rename(partial, final)

      Result.new(final, File.size(final))
    ensure
      FileUtils.rm_f(partial) if partial
    end

    private

    def validate!(filename)
      return if filename.present? && filename == File.basename(filename) && !filename.start_with?('.')

      raise ArgumentError, "invalid backup file name: #{filename.inspect}"
    end
  end
end
