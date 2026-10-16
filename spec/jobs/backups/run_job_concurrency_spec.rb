# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Backups::RunJob, 'starting together', :non_transactional, type: :job do
  include ActiveJob::TestHelper

  around do |example|
    Dir.mktmpdir('backups-run-job-concurrency') do |dir|
      @dir = dir
      example.run
    end
  end

  before do
    @users = create_list(:user, 2)
    InstanceSetting.create!(key: 'backup_export_path', value: @dir)
    InstanceSettings::Resolver.reset!
  end

  after do
    BackupRun.delete_all
    InstanceSetting.delete_all
    InstanceSettings::Resolver.reset!
    # destroy only soft-deletes users, which would leave them behind for later specs.
    User.unscoped.where(id: @users.map(&:id)).delete_all
  end

  def runs_for(users)
    BackupRun.kind_user_export.where(user: users)
  end

  it 'does not start while another backup is being queued' do
    locked = Queue.new
    release = Queue.new
    holder = Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.with_advisory_lock(described_class::LOCK_KEY) do
          locked << :held
          release.pop(timeout: 15)
        end
      end
    rescue StandardError => e
      locked << e
    end
    state = locked.pop(timeout: 15)
    raise "could not take the lock from another connection: #{state.inspect}" unless state == :held

    expect { described_class.perform_now(force: true) }.not_to(change { runs_for(@users).count })

    release << true
    holder.join

    expect { described_class.perform_now(force: true) }.to change { runs_for(@users).count }.by(2)
  end

  it 'creates one set of runs however many jobs start at once' do
    start = Queue.new
    threads = Array.new(6) do
      Thread.new do
        start.pop
        ActiveRecord::Base.connection_pool.with_connection { described_class.perform_now(force: true) }
      end
    end
    6.times { start << true }
    threads.each(&:join)

    expect(runs_for(@users).group(:user_id).count.values).to all(eq(1))
    expect(runs_for(@users).count).to eq(2)
  end
end
