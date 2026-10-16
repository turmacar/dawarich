# frozen_string_literal: true

module Dawarich
  # While a restore replaces the database, jobs are pushed back a few minutes instead of
  # running against it. The restore job itself is the one exception.
  class MaintenanceDefer
    include Sidekiq::ServerMiddleware

    DELAY = 120

    def call(_worker, job, _queue)
      if Backups::Maintenance.active? && !restore?(job)
        Sidekiq::Client.push(job.except('jid', 'enqueued_at').merge('at' => Time.now.to_f + DELAY))
        return
      end

      yield
    end

    private

    def restore?(job)
      (job['wrapped'] || job['class']).to_s == 'Backups::RestoreJob'
    end
  end
end
