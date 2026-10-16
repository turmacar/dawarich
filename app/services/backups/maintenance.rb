# frozen_string_literal: true

module Backups
  # The "a restore is replacing the database" flag, kept in the job Redis so the web and
  # worker containers both see it. It expires on its own unless the restore keeps it
  # alive, so a crashed worker cannot leave the instance stuck in maintenance.
  module Maintenance
    KEY = 'dawarich:maintenance'
    TTL = 90
    QUEUED_TTL = 10.minutes.to_i
    HEARTBEAT = 20
    CACHE_FOR = 2.0

    module_function

    def current
      raw = Sidekiq.redis { |redis| redis.call('GET', KEY) }
      raw && JSON.parse(raw)
    rescue StandardError
      nil
    end

    # Request and job checks read this once per CACHE_FOR seconds per process.
    def active?
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if @checked_at.nil? || now - @checked_at > CACHE_FOR
        @active = !current.nil?
        @checked_at = now
      end
      @active
    end

    def start!(run_id:, step:, ttl: TTL)
      write({ 'run_id' => run_id, 'step' => step, 'started_at' => Time.current.iso8601 }, ttl)
    end

    def step!(step)
      write((current || {}).merge('step' => step), TTL)
    end

    def finish!
      Sidekiq.redis { |redis| redis.call('DEL', KEY) }
      @checked_at = nil
    end

    # Keeps the flag alive while the block runs, however long one step takes.
    def hold(run_id:)
      start!(run_id: run_id, step: 'waiting_for_jobs')
      beat = Thread.new do
        loop do
          sleep HEARTBEAT
          Sidekiq.redis { |redis| redis.call('EXPIRE', KEY, TTL) }
        end
      end
      yield
    ensure
      beat&.kill
      finish!
    end

    def write(payload, ttl)
      Sidekiq.redis { |redis| redis.call('SET', KEY, payload.to_json, 'EX', ttl.to_i) }
      @checked_at = nil
    end
  end
end
