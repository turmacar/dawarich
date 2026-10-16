# frozen_string_literal: true

require 'open3'

module Backups
  # Runs pg_dump, pg_restore and psql against the app database's server, with the password
  # in the environment and never on a command line.
  module Postgres
    class Failed < StandardError; end

    module_function

    def config
      ActiveRecord::Base.connection_db_config.configuration_hash
    end

    def env
      config[:password].present? ? { 'PGPASSWORD' => config[:password].to_s } : {}
    end

    def server_args
      args = []
      args += ['--host', config[:host].to_s] if config[:host].present?
      args += ['--port', config[:port].to_s] if config[:port].present?
      args += ['--username', config[:username].to_s] if config[:username].present?
      args
    end

    def dump(path)
      _out, err, status = Open3.capture3(env, 'pg_dump', '--format=custom', '--file', path.to_s,
                                         *server_args, config[:database].to_s)
      raise Failed, "pg_dump failed: #{err.to_s.strip.truncate(500)}" unless status.success?
    end

    # Schemas and extensions the dump creates, read from its table of contents.
    def contents(path)
      out, err, status = Open3.capture3('pg_restore', '--list', path.to_s)
      raise Failed, err.to_s.strip.truncate(500) unless status.success?

      entries = out.lines.grep_v(/\A;/).map(&:split)
      {
        schemas: entries.select { _1[3] == 'SCHEMA' && _1[4] == '-' }.map { _1[5] },
        extensions: entries.select { _1[3] == 'EXTENSION' && _1[4] == '-' }.map { _1[5] }
      }
    end

    # Replaces everything the dump defines in `database` with the dump's contents, in one
    # transaction that only commits once pg_restore has produced the whole dump. Any error,
    # or a dump that ends early, leaves the database exactly as it was.
    def restore(path, database:)
      wipe = wipe_sql(contents(path))
      psql_in, psql_out, psql_err, psql = Open3.popen3(
        env, 'psql', '--no-psqlrc', '--quiet', '--set', 'ON_ERROR_STOP=1', *server_args, '--dbname', database
      )
      restore_in, restore_out, restore_err, pg_restore = Open3.popen3(
        env, 'pg_restore', '--no-owner', '--no-privileges', '--file', '-', path.to_s
      )
      restore_in.close
      drains = [psql_out, psql_err, restore_err].map { |io| Thread.new { io.read } }

      committed = stream(psql_in, restore_out, wipe, pg_restore)
      psql_in.close unless psql_in.closed?
      psql_status = psql.value
      _, psql_errors, restore_errors = drains.map(&:value)

      return if committed && psql_status.success?

      raise Failed, (psql_errors.presence || restore_errors.presence || 'restore did not complete').strip.truncate(500)
    ensure
      [psql_in, restore_out].each { _1&.close unless _1&.closed? }
    end

    def stream(psql_in, restore_out, wipe, pg_restore)
      psql_in.write("SET client_min_messages = warning;\nBEGIN;\n#{wipe}\n")
      IO.copy_stream(restore_out, psql_in)
      return false unless pg_restore.value.success?

      psql_in.write("COMMIT;\n")
      true
    rescue Errno::EPIPE, IOError
      # psql stopped at an error and rolled back; stop feeding it.
      Process.kill('TERM', pg_restore.pid) if pg_restore.alive?
      pg_restore.value
      false
    end

    def wipe_sql(contents)
      quote = ->(name) { PG::Connection.quote_ident(name) }
      [
        'SELECT pg_terminate_backend(pid) FROM pg_stat_activity ' \
        'WHERE datname = current_database() AND pid <> pg_backend_pid();',
        *contents[:extensions].map { "DROP EXTENSION IF EXISTS #{quote.call(_1)} CASCADE;" },
        *(contents[:schemas] | ['public']).map { "DROP SCHEMA IF EXISTS #{quote.call(_1)} CASCADE;" },
        'CREATE SCHEMA public;'
      ].join("\n")
    end
  end
end
