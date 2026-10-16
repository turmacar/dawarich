# frozen_string_literal: true

module Backups
  # The configured backup directory. It must already exist: creating it would let a
  # missing bind mount silently turn into a backup on the container filesystem.
  class Destination
    class Unavailable < StandardError; end

    def initialize(path = InstanceSettings::Resolver.value(:backup_export_path))
      @path = path.to_s.strip
    end

    def configured?
      @path.present?
    end

    def root
      @root ||= resolve_root
    end

    def subdirectory(name)
      directory = root.join(name)
      FileUtils.mkdir_p(directory)
      directory
    end

    private

    def resolve_root
      raise Unavailable, 'No backup directory is configured' unless configured?
      raise Unavailable, "#{@path} is not an absolute path" unless Pathname.new(@path).absolute?
      raise Unavailable, "#{@path} does not exist; mount it before enabling backups" unless File.directory?(@path)

      real = Pathname.new(@path).realpath
      raise Unavailable, "#{@path} is not writable" unless File.writable?(real)
      raise Unavailable, "#{@path} is inside the public web directory" if inside_public?(real)

      real
    end

    def inside_public?(real)
      public_dir = Rails.public_path.realpath.to_s
      real.to_s == public_dir || real.to_s.start_with?("#{public_dir}/")
    end
  end
end
