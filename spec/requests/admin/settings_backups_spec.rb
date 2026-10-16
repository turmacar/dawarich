# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Admin::Settings backups' do
  include ActiveJob::TestHelper

  let(:admin) { create(:user, admin: true) }
  let(:non_admin) { create(:user) }
  let(:backup_env) do
    %w[BACKUP_EXPORT_FREQUENCY BACKUP_EXPORT_TIME BACKUP_EXPORT_PATH BACKUP_EXPORT_RETENTION BACKUP_DATABASE_DUMP]
  end

  around do |example|
    saved = backup_env.index_with { ENV.fetch(_1, nil) }
    backup_env.each { ENV[_1] = nil }
    InstanceSettings::Resolver.reset!
    Dir.mktmpdir('admin-backups') do |dir|
      @dir = dir
      example.run
    end
  ensure
    saved.each { |name, value| ENV[name] = value }
    InstanceSettings::Resolver.reset!
  end

  def store(key, value)
    InstanceSetting.create!(key: key, value: value)
    InstanceSettings::Resolver.reset!
  end

  def stored(key)
    InstanceSetting.find_by(key: key)&.value
  end

  describe 'the section' do
    before { sign_in admin }

    it 'is listed in the navigation and renders its fields' do
      get '/admin/settings', params: { section: 'backups' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-testid="instance-settings-section-backups"')
      %w[backup_export_frequency backup_export_time backup_export_path backup_export_retention
         backup_database_dump].each do |key|
        expect(response.body).to include("id=\"instance_settings_#{key}\"")
      end
    end

    it 'renders the time as a time input showing the default' do
      get '/admin/settings', params: { section: 'backups' }

      field = /<input type="time"[^>]*id="instance_settings_backup_export_time"[^>]*value="04:15"/m
      expect(response.body).to match(field)
    end

    it 'shows the stored time' do
      store('backup_export_time', '23:40')

      get '/admin/settings', params: { section: 'backups' }

      expect(response.body).to match(/id="instance_settings_backup_export_time"[^>]*value="23:40"/m)
    end

    it 'does not touch the backup directory when another section is open' do
      allow(Backups::Destination).to receive(:new).and_call_original

      get '/admin/settings', params: { section: 'points' }

      expect(Backups::Destination).not_to have_received(:new)
    end

    it 'says so when no directory is configured' do
      get '/admin/settings', params: { section: 'backups' }

      expect(response.body).to include(ERB::Util.html_escape(I18n.t('admin.settings.show.backups.destination_error',
                                                                    reason: 'No backup directory is configured')))
    end

    it 'shows the resolved directory when it is usable' do
      store('backup_export_path', @dir)

      get '/admin/settings', params: { section: 'backups' }

      expect(response.body).to include(Pathname.new(@dir).realpath.to_s)
    end

    it 'warns when the directory is missing and disables Back up now' do
      store('backup_export_path', File.join(@dir, 'not-mounted'))

      get '/admin/settings', params: { section: 'backups' }

      expect(response.body).to include('not-mounted')
      label = Regexp.escape(I18n.t('admin.settings.show.backups.run_now'))
      expect(response.body).to match(/<button[^>]*disabled[^>]*>\s*#{label}/m)
    end

    it 'lists recent runs with their outcome' do
      user = create(:user, email: 'alice@example.com')
      create(:backup_run, :completed, user: user, file_name: 'alice.zip', bytes: 2048)
      create(:backup_run, user: user, status: :failed, error: 'disk full', finished_at: Time.current)

      get '/admin/settings', params: { section: 'backups' }

      expect(response.body).to include('alice.zip', 'alice@example.com', 'disk full', '2 KB')
    end

    it 'renders a pinned directory as disabled and names the variable' do
      ENV['BACKUP_EXPORT_PATH'] = @dir
      InstanceSettings::Resolver.reset!

      get '/admin/settings', params: { section: 'backups' }

      expect(response.body).to include('BACKUP_EXPORT_PATH')
      expect(response.body).to match(/<input[^>]*id="instance_settings_backup_export_path"[^>]*\sdisabled[\s>]/)
    end
  end

  describe 'PATCH update' do
    before { sign_in admin }

    def save(values)
      patch '/admin/settings', params: { section: 'backups', instance_settings: values }
    end

    it 'stores a valid schedule' do
      save(backup_export_frequency: 'weekly', backup_export_time: '02:30', backup_export_path: "#{@dir}/",
           backup_export_retention: '14', backup_database_dump: 'true')

      expect(flash[:notice]).to eq(I18n.t('admin.settings.update.saved'))
      expect(stored('backup_export_frequency')).to eq('weekly')
      expect(stored('backup_export_time')).to eq('02:30')
      expect(stored('backup_export_path')).to eq(@dir)
      expect(stored('backup_export_retention')).to eq(14)
      expect(stored('backup_database_dump')).to be(true)
    end

    it 'rejects an unknown frequency and stores nothing' do
      save(backup_export_frequency: 'hourly')

      expect(flash[:alert]).to include('daily')
      expect(stored('backup_export_frequency')).to be_nil
    end

    it 'rejects a time that is not a 24-hour HH:MM and stores nothing' do
      save(backup_export_time: '25:99')

      expect(flash[:alert]).to eq(I18n.t('admin.settings.update.backup_time_invalid'))
      expect(stored('backup_export_time')).to be_nil
    end

    it 'rejects a relative or parent-escaping path' do
      save(backup_export_path: '/backups/../etc')

      expect(flash[:alert]).to eq(I18n.t('admin.settings.update.backup_path_invalid'))
      expect(stored('backup_export_path')).to be_nil
    end

    it 'rejects a retention outside the allowed range' do
      save(backup_export_retention: '0')

      expect(flash[:alert]).to be_present
      expect(stored('backup_export_retention')).to be_nil
    end

    it 'refuses to write a pinned setting even when the form posts it' do
      ENV['BACKUP_EXPORT_PATH'] = @dir
      InstanceSettings::Resolver.reset!

      save(backup_export_path: '/somewhere/else')

      expect(flash[:alert]).to include('BACKUP_EXPORT_PATH')
      expect(stored('backup_export_path')).to be_nil
    end

    it 'refuses a write from a non-admin' do
      sign_in non_admin

      save(backup_export_frequency: 'daily')

      expect(stored('backup_export_frequency')).to be_nil
    end
  end

  describe 'locale parity' do
    it 'defines the backup strings in every shipped locale' do
      keys = %w[admin.settings.show.backups.title admin.settings.show.backups.frequencies.daily
                admin.settings.show.backups.statuses.failed admin.settings.show.fields.backup_export_path_hint
                admin.settings.show.fields.backup_export_time admin.settings.show.fields.backup_export_time_hint
                admin.settings.update.backup_path_invalid admin.settings.update.backup_time_invalid
                admin.settings.run_backup.started
                jobs.backups.run.unavailable_title jobs.backups.database_dump.failed_content]

      %i[ca de es fr pl zh].product(keys).each do |locale, key|
        expect(I18n.t(key, locale: locale, default: nil)).to be_present, "missing #{key} for #{locale}"
      end
    end

    it 'keeps every placeholder the English strings use' do
      %w[admin.settings.show.backups.destination_error admin.settings.update.backup_retention_invalid
         jobs.backups.user_export.failed_content].each do |key|
        placeholders = I18n.t(key, locale: :en).scan(/%\{(\w+)\}/).flatten.sort

        %i[ca de es fr pl zh].each do |locale|
          found = I18n.t(key, locale: locale).scan(/%\{(\w+)\}/).flatten.sort

          expect(found).to eq(placeholders), "#{key} placeholders differ in #{locale}"
        end
      end
    end
  end

  describe 'POST run_backup' do
    it 'enqueues a forced backup when the directory is usable' do
      store('backup_export_path', @dir)
      sign_in admin

      expect { post '/admin/settings/run_backup' }.to have_enqueued_job(Backups::RunJob).with(force: true)

      expect(flash[:notice]).to eq(I18n.t('admin.settings.run_backup.started'))
    end

    it 'refuses and says why when the directory is unusable' do
      store('backup_export_path', File.join(@dir, 'not-mounted'))
      sign_in admin

      expect { post '/admin/settings/run_backup' }.not_to have_enqueued_job(Backups::RunJob)

      expect(flash[:alert]).to include('not-mounted')
    end

    it 'does not start a second backup while one is running' do
      store('backup_export_path', @dir)
      create(:backup_run)
      sign_in admin

      expect { post '/admin/settings/run_backup' }.not_to have_enqueued_job(Backups::RunJob)

      expect(flash[:alert]).to eq(I18n.t('admin.settings.run_backup.in_progress'))
    end

    it 'is refused for a non-admin' do
      store('backup_export_path', @dir)
      sign_in non_admin

      expect { post '/admin/settings/run_backup' }.not_to have_enqueued_job(Backups::RunJob)
    end

    it 'is not available on a cloud instance' do
      allow(DawarichSettings).to receive(:self_hosted?).and_return(false)
      store('backup_export_path', @dir)
      sign_in admin

      expect { post '/admin/settings/run_backup' }.not_to have_enqueued_job(Backups::RunJob)
    end
  end
end
