# frozen_string_literal: true

module Backups
  # Proves a database dump can be restored by restoring it into a temporary database next
  # to the live one, then checking what came back. The temporary database is always
  # dropped, and the dump file itself is only read.
  class Verifier
    class Unavailable < StandardError; end

    SCRATCH_PREFIX = 'dawarich_backup_verify_'
    COUNTED_TABLES = %w[users points tracks visits places areas trips imports exports stats].freeze
    ENCRYPTED_SAMPLE = 50

    def initialize(run, destination: Backups::Destination.new)
      @run = run
      @destination = destination
    end

    def check!
      raise Unavailable, :not_a_dump unless run.verifiable?
      raise Unavailable, :file_missing unless run.file_name == File.basename(run.file_name)
      raise Unavailable, :file_missing unless File.file?(path)
    end

    def call
      check!
      result = { 'problems' => [], 'warnings' => [], 'bytes' => File.size(path),
                 'sha256' => Digest::SHA256.file(path).hexdigest }

      drop_leftover_scratch_databases
      with_scratch_database do |name|
        restore_into(name)
        inspect_database(name, result)
      rescue RestoreFailed => e
        result['problems'] << { 'code' => 'unreadable', 'detail' => e.message }
      end

      result.merge('state' => result['problems'].empty? ? 'passed' : 'failed')
    end

    def code_version
      code_versions.max
    end

    def code_versions
      ActiveRecord::Base.connection_pool.migration_context.migrations.map(&:version)
    end

    private

    class RestoreFailed < StandardError; end

    attr_reader :run, :destination

    def path
      @path ||= destination.root.join('database', run.file_name)
    end

    def config
      Backups::Postgres.config
    end

    def connection
      ActiveRecord::Base.connection
    end

    # A worker killed mid-verification never drops its database; only one verification
    # runs at a time, so anything with our prefix is left over.
    def drop_leftover_scratch_databases
      connection.select_values(
        "SELECT datname FROM pg_database WHERE datname LIKE '#{SCRATCH_PREFIX}%'"
      ).each { |name| drop_database(name) }
    end

    def with_scratch_database
      name = "#{SCRATCH_PREFIX}#{run.id}_#{SecureRandom.hex(4)}"
      connection.execute("CREATE DATABASE #{connection.quote_table_name(name)} TEMPLATE template0")
      yield name
    ensure
      drop_database(name) if name
    end

    def drop_database(name)
      connection.execute("DROP DATABASE IF EXISTS #{connection.quote_table_name(name)} WITH (FORCE)")
    end

    def restore_into(name)
      Backups::Postgres.restore(path, database: name)
    rescue Backups::Postgres::Failed => e
      raise RestoreFailed, e.message
    end

    def inspect_database(name, result)
      scratch = PG.connect(host: config[:host], port: config[:port], user: config[:username],
                           password: config[:password], dbname: name)
      unless table?(scratch, 'schema_migrations')
        result['problems'] << { 'code' => 'not_dawarich' }
        return
      end

      check_schema(scratch, result)
      result['counts'] = COUNTED_TABLES.select { table?(scratch, _1) }.index_with do |table|
        scratch.exec("SELECT count(*) FROM #{scratch.quote_ident(table)}").getvalue(0, 0).to_i
      end
      check_encrypted_values(scratch, result)
    ensure
      scratch&.close
    end

    def check_schema(scratch, result)
      dumped = scratch.exec('SELECT version::bigint FROM schema_migrations').column_values(0).map(&:to_i)
      result['schema_version'] = dumped.max
      result['code_version'] = code_version

      if dumped.max > code_version
        result['problems'] << { 'code' => 'newer_schema' }
      elsif (code_versions - dumped).any?
        result['warnings'] << { 'code' => 'older_schema' }
      end
    end

    # Encrypted columns only decrypt with this instance's keys, so a dump from another
    # instance (or after a key change) restores fine but leaves unreadable settings.
    def check_encrypted_values(scratch, result)
      checked = 0
      failed = 0

      encrypted_columns.each do |model, attribute|
        next unless table?(scratch, model.table_name)

        type = model.type_for_attribute(attribute)
        sql = "SELECT #{scratch.quote_ident(attribute.to_s)} FROM #{scratch.quote_ident(model.table_name)} " \
              "WHERE #{scratch.quote_ident(attribute.to_s)} IS NOT NULL LIMIT #{ENCRYPTED_SAMPLE}"
        scratch.exec(sql).column_values(0).each do |raw|
          checked += 1
          type.deserialize(raw)
        rescue ActiveRecord::Encryption::Errors::Base
          failed += 1
        end
      end

      result['encrypted_checked'] = checked
      result['problems'] << { 'code' => 'undecryptable', 'count' => failed } if failed.positive?
    end

    def encrypted_columns
      Rails.autoloaders.main.eager_load_dir(Rails.root.join('app/models').to_s) unless Rails.configuration.eager_load

      ApplicationRecord.descendants.reject(&:abstract_class?)
                       .flat_map { |model| Array(model.encrypted_attributes).map { [model, _1] } }
                       .uniq { |model, attribute| [model.table_name, attribute] }
    end

    def table?(scratch, table)
      !scratch.exec_params('SELECT to_regclass($1)', ["public.#{table}"]).getvalue(0, 0).nil?
    end
  end
end
