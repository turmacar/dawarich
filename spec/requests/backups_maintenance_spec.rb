# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Maintenance during a database restore' do
  after { Backups::Maintenance.finish! }

  describe 'the web gate' do
    before { Backups::Maintenance.start!(run_id: 1, step: 'restoring') }

    it 'answers pages with a 503 maintenance page' do
      get '/'

      expect(response).to have_http_status(:service_unavailable)
      expect(response.body).to include(I18n.t('admin.settings.maintenance.title'))
      expect(response.headers['retry-after']).to eq('15')
    end

    it 'answers the API with JSON' do
      get '/api/v1/points'

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to eq({ 'error' => 'maintenance' })
    end

    it 'keeps the liveness check up' do
      get '/api/v1/health'

      expect(response).to have_http_status(:ok)
    end

    it 'opens again when the restore ends' do
      Backups::Maintenance.finish!

      get '/api/v1/health'
      get '/'

      expect(response).not_to have_http_status(:service_unavailable)
    end
  end

  describe 'the job deferral' do
    let(:middleware) { Dawarich::MaintenanceDefer.new }
    let(:job) do
      { 'class' => 'ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper', 'wrapped' => 'Stats::CalculatingJob',
        'jid' => 'abc', 'queue' => 'stats', 'args' => [1] }
    end

    before { allow(Sidekiq::Client).to receive(:push) }

    it 'pushes jobs back instead of running them while a restore runs' do
      Backups::Maintenance.start!(run_id: 1, step: 'restoring')
      ran = false

      middleware.call(nil, job, 'stats') { ran = true }

      expect(ran).to be(false)
      expect(Sidekiq::Client).to have_received(:push)
        .with(hash_including('wrapped' => 'Stats::CalculatingJob', 'at' => Float))
      expect(Sidekiq::Client).not_to have_received(:push).with(hash_including('jid'))
    end

    it 'runs the restore job itself, and everything once maintenance is over' do
      Backups::Maintenance.start!(run_id: 1, step: 'restoring')
      ran = []

      middleware.call(nil, job.merge('wrapped' => 'Backups::RestoreJob'), 'highest_priority') { ran << :restore }
      Backups::Maintenance.finish!
      middleware.call(nil, job, 'stats') { ran << :stats }

      expect(ran).to eq(%i[restore stats])
      expect(Sidekiq::Client).not_to have_received(:push)
    end
  end
end
