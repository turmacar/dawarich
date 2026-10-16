# frozen_string_literal: true

require 'rails_helper'

# CREATE DATABASE cannot run inside a transaction, and pg_dump only sees committed rows.
RSpec.describe Backups::Postgres, :non_transactional do
  let(:dir) { Pathname.new(Dir.mktmpdir('backups-postgres')) }
  let(:dump_path) { dir.join('db.pgcustom') }
  let(:connection) { ActiveRecord::Base.connection }
  let(:scratch) { "dawarich_pg_spec_#{SecureRandom.hex(4)}" }

  def compatible_pg_dump?
    client = Open3.capture2('pg_dump', '--version').first[/\d+/].to_i
    client >= connection.select_value('SHOW server_version_num').to_i / 10_000
  rescue Errno::ENOENT
    false
  end

  def scratch_value(sql)
    pg = PG.connect(host: described_class.config[:host], port: described_class.config[:port],
                    user: described_class.config[:username], password: described_class.config[:password],
                    dbname: scratch)
    pg.exec(sql).getvalue(0, 0)
  ensure
    pg&.close
  end

  before do
    skip 'no pg_dump at least as new as the test database' unless compatible_pg_dump?
    described_class.dump(dump_path)
    connection.execute("CREATE DATABASE #{scratch} TEMPLATE template0")
    scratch_value('CREATE TABLE public.marker (id int); SELECT 1')
  end

  after do
    connection.execute("DROP DATABASE IF EXISTS #{scratch} WITH (FORCE)")
    FileUtils.rm_rf(dir)
  end

  it 'replaces what was in the database with the dump' do
    described_class.restore(dump_path, database: scratch)

    expect(scratch_value("SELECT to_regclass('public.marker')")).to be_nil
    expect(scratch_value('SELECT max(version) FROM schema_migrations')).to be_present
    expect(scratch_value("SELECT extname FROM pg_extension WHERE extname = 'postgis'")).to eq('postgis')
  end

  it 'leaves the database untouched when the dump ends early' do
    File.binwrite(dump_path, File.binread(dump_path).byteslice(0, File.size(dump_path) / 2))

    expect { described_class.restore(dump_path, database: scratch) }.to raise_error(described_class::Failed)

    expect(scratch_value("SELECT to_regclass('public.marker')")).to eq('marker')
    expect(scratch_value("SELECT to_regclass('public.schema_migrations')")).to be_nil
  end

  it 'lists the schemas and extensions a dump creates' do
    contents = described_class.contents(dump_path)

    expect(contents[:extensions]).to include('postgis')
    expect(described_class.wipe_sql(contents)).to include('DROP EXTENSION IF EXISTS "postgis" CASCADE;',
                                                          'DROP SCHEMA IF EXISTS "public" CASCADE;')
  end
end
