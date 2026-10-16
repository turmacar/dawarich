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
                admin.settings.show.backups.import admin.settings.show.backups.columns.actions
                admin.settings.import_backup.not_found admin.settings.import_backup.file_missing
                devise.registrations.edit.import_from_automated_backups
                admin.settings.show.backups.verify admin.settings.verify_backup.in_progress
                admin.settings.show.backups.verification.problems.not_dawarich
                admin.settings.show.backups.restore_submit admin.settings.show.backups.kinds.database_restore
                admin.settings.restore_backup.changed admin.settings.maintenance.title jobs.backups.restore.failed_title
                jobs.backups.run.unavailable_title jobs.backups.database_dump.failed_content]

      %i[ca de es fr pl zh].product(keys).each do |locale, key|
        expect(I18n.t(key, locale: locale, default: nil)).to be_present, "missing #{key} for #{locale}"
      end
    end

    it 'keeps every placeholder the English strings use' do
      %w[admin.settings.show.backups.destination_error admin.settings.update.backup_retention_invalid
         admin.settings.show.backups.import_confirm admin.settings.import_backup.started
         admin.settings.show.backups.verification.problems.undecryptable
         admin.settings.show.backups.verification.counts
         admin.settings.show.backups.restore_confirm_label admin.settings.restore_backup.confirmation_mismatch
         jobs.backups.restore.restored_content
         jobs.backups.user_export.failed_content].each do |key|
        placeholders = I18n.t(key, locale: :en).scan(/%\{(\w+)\}/).flatten.sort

        %i[ca de es fr pl zh].each do |locale|
          found = I18n.t(key, locale: locale).scan(/%\{(\w+)\}/).flatten.sort

          expect(found).to eq(placeholders), "#{key} placeholders differ in #{locale}"
        end
      end
    end
  end

  describe 'POST import_backup' do
    let(:owner) { create(:user, email: 'owner@example.com') }

    before do
      store('backup_export_path', @dir)
      FileUtils.mkdir_p(File.join(@dir, 'user-exports'))
      File.binwrite(File.join(@dir, 'user-exports', 'owner.zip'), 'archive-bytes')
    end

    def archive_run(**attributes)
      create(:backup_run, :completed, user: owner, file_name: 'owner.zip', **attributes)
    end

    it 'imports the archive into the account it was made from, not the admin' do
      run = archive_run
      sign_in admin

      expect { post '/admin/settings/import_backup', params: { backup_run_id: run.id } }
        .to change { owner.imports.count }.by(1).and have_enqueued_job(Import::ProcessJob)

      expect(admin.imports.count).to eq(0)
      expect(owner.imports.last).to have_attributes(source: 'user_data_archive', name: 'owner.zip')
      expect(flash[:notice]).to eq(I18n.t('admin.settings.import_backup.started', email: 'owner@example.com'))
    end

    it 'refuses a database dump or an unfinished backup' do
      dump = create(:backup_run, :database_dump, :completed, file_name: 'owner.zip')
      running = create(:backup_run, user: owner, file_name: 'owner.zip')
      sign_in admin

      [dump, running].each do |run|
        expect { post '/admin/settings/import_backup', params: { backup_run_id: run.id } }
          .not_to(change { Import.count })
        expect(flash[:alert]).to eq(I18n.t('admin.settings.import_backup.not_an_archive'))
      end
    end

    it 'says so when the backup does not exist' do
      sign_in admin

      post '/admin/settings/import_backup', params: { backup_run_id: 0 }

      expect(flash[:alert]).to eq(I18n.t('admin.settings.import_backup.not_found'))
    end

    it 'says so when the file is gone from the directory' do
      run = archive_run(file_name: 'gone.zip')
      sign_in admin

      expect { post '/admin/settings/import_backup', params: { backup_run_id: run.id } }.not_to(change { Import.count })

      expect(flash[:alert]).to eq(I18n.t('admin.settings.import_backup.file_missing'))
    end

    it 'is refused for a non-admin' do
      run = archive_run
      sign_in non_admin

      expect { post '/admin/settings/import_backup', params: { backup_run_id: run.id } }.not_to(change { Import.count })
    end

    it 'is not available on a cloud instance' do
      run = archive_run
      allow(DawarichSettings).to receive(:self_hosted?).and_return(false)
      sign_in admin

      expect { post '/admin/settings/import_backup', params: { backup_run_id: run.id } }.not_to(change { Import.count })
    end

    it 'offers the Import button only for completed user archives' do
      archive_run
      create(:backup_run, :database_dump, :completed, file_name: 'dump.pgcustom')
      sign_in admin

      get '/admin/settings', params: { section: 'backups' }

      expect(response.body.scan(%r{/admin/settings/import_backup\?backup_run_id=}).size).to eq(1)
    end
  end

  describe 'POST verify_backup' do
    before do
      store('backup_export_path', @dir)
      FileUtils.mkdir_p(File.join(@dir, 'database'))
      File.binwrite(File.join(@dir, 'database', 'db.pgcustom'), 'dump-bytes')
    end

    def dump_run(**attributes)
      create(:backup_run, :database_dump, :completed, file_name: 'db.pgcustom', **attributes)
    end

    it 'marks the dump as verifying and queues the job' do
      run = dump_run
      sign_in admin

      expect { post '/admin/settings/verify_backup', params: { backup_run_id: run.id } }
        .to have_enqueued_job(Backups::VerifyJob).with(run.id)

      expect(run.reload.verification_state).to eq('running')
      expect(flash[:notice]).to eq(I18n.t('admin.settings.verify_backup.started'))
    end

    it 'runs one verification at a time' do
      dump_run.start_verification!
      run = dump_run
      sign_in admin

      expect { post '/admin/settings/verify_backup', params: { backup_run_id: run.id } }
        .not_to have_enqueued_job(Backups::VerifyJob)

      expect(flash[:alert]).to eq(I18n.t('admin.settings.verify_backup.in_progress'))
    end

    it 'refuses user archives, missing files and unknown backups' do
      sign_in admin

      post '/admin/settings/verify_backup', params: { backup_run_id: create(:backup_run, :completed).id }
      expect(flash[:alert]).to eq(I18n.t('admin.settings.verify_backup.not_a_dump'))

      post '/admin/settings/verify_backup', params: { backup_run_id: dump_run(file_name: 'gone.pgcustom').id }
      expect(flash[:alert]).to eq(I18n.t('admin.settings.verify_backup.file_missing'))

      post '/admin/settings/verify_backup', params: { backup_run_id: 0 }
      expect(flash[:alert]).to eq(I18n.t('admin.settings.verify_backup.not_found'))
      expect(Backups::VerifyJob).not_to have_been_enqueued
    end

    it 'is refused for a non-admin and on a cloud instance' do
      run = dump_run
      sign_in non_admin
      post '/admin/settings/verify_backup', params: { backup_run_id: run.id }

      allow(DawarichSettings).to receive(:self_hosted?).and_return(false)
      sign_in admin
      post '/admin/settings/verify_backup', params: { backup_run_id: run.id }

      expect(Backups::VerifyJob).not_to have_been_enqueued
      expect(run.reload.verification).to be_nil
    end

    it 'shows the Verify button for dumps and the result of a verification' do
      passed = dump_run
      passed.finish_verification!('state' => 'passed', 'counts' => { 'users' => 3, 'points' => 12_345 },
                                  'problems' => [], 'warnings' => [{ 'code' => 'older_schema' }])
      failed = dump_run
      failed.finish_verification!('state' => 'failed', 'problems' => [{ 'code' => 'undecryptable', 'count' => 2 }],
                                  'warnings' => [])
      create(:backup_run, :completed)
      sign_in admin

      get '/admin/settings', params: { section: 'backups' }

      expect(response.body.scan(%r{/admin/settings/verify_backup\?backup_run_id=}).size).to eq(2)
      expect(response.body).to include('3 users, 12,345 points')
      %w[warnings.older_schema problems.undecryptable].each do |key|
        message = I18n.t("admin.settings.show.backups.verification.#{key}", count: 2)
        expect(response.body).to include(CGI.escapeHTML(message))
      end
    end
  end

  describe 'POST restore_backup' do
    let(:path) { File.join(@dir, 'database', 'db.pgcustom') }

    before do
      store('backup_export_path', @dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, 'dump-bytes')
    end

    after { Backups::Maintenance.finish! }

    def verified_dump(state: 'passed')
      create(:backup_run, :database_dump, :completed, file_name: 'db.pgcustom')
        .tap { _1.finish_verification!('state' => state, 'sha256' => Digest::SHA256.file(path).hexdigest) }
    end

    def restore(run, confirmation: 'RESTORE')
      post '/admin/settings/restore_backup', params: { backup_run_id: run.id, confirmation: confirmation }
    end

    it 'records the restore, starts maintenance and queues the job' do
      source = verified_dump
      sign_in admin

      expect { restore(source) }.to have_enqueued_job(Backups::RestoreJob)

      run = BackupRun.kind_database_restore.last
      expect(run).to have_attributes(status: 'running', file_name: 'db.pgcustom')
      expect(Backups::RestoreJob).to have_been_enqueued.with(run.id, source.id)
      expect(Backups::Maintenance.current).to include('run_id' => run.id, 'step' => 'queued')
      expect(response).to redirect_to(admin_settings_path(section: 'backups'))
    end

    it 'needs the confirmation word typed exactly' do
      source = verified_dump
      sign_in admin

      %w[restore RESTOR].each do |typed|
        expect { restore(source, confirmation: typed) }.not_to have_enqueued_job(Backups::RestoreJob)
        expect(flash[:alert]).to eq(I18n.t('admin.settings.restore_backup.confirmation_mismatch', word: 'RESTORE'))
      end
      expect(Backups::Maintenance.current).to be_nil
    end

    it 'refuses a dump that did not pass verification, or while something else runs' do
      sign_in admin

      restore(verified_dump(state: 'failed'))
      expect(flash[:alert]).to eq(I18n.t('admin.settings.restore_backup.not_verified'))

      create(:backup_run, :database_dump)
      restore(verified_dump)
      expect(flash[:alert]).to eq(I18n.t('admin.settings.restore_backup.busy'))

      expect(Backups::RestoreJob).not_to have_been_enqueued
      expect(BackupRun.kind_database_restore).to be_empty
    end

    it 'is refused for a non-admin and on a cloud instance' do
      source = verified_dump
      sign_in non_admin
      restore(source)

      allow(DawarichSettings).to receive(:self_hosted?).and_return(false)
      sign_in admin
      restore(source)

      expect(Backups::RestoreJob).not_to have_been_enqueued
      expect(Backups::Maintenance.current).to be_nil
    end

    it 'offers Restore only for verified dumps, in a dialog naming the file and the word to type' do
      verified_dump
      verified_dump(state: 'failed')
      sign_in admin

      get '/admin/settings', params: { section: 'backups' }

      expect(response.body.scan('data-testid="backup-restore"').size).to eq(1)
      dialog = Nokogiri::HTML(response.body).at_css('dialog[data-testid="backup-restore"]')
      expect(dialog.text).to include(I18n.t('admin.settings.show.backups.restore_title'), 'db.pgcustom')
      expect(dialog.at_css('input[name="confirmation"]')['pattern']).to eq('RESTORE')
      expect(response.body).to include("document.getElementById('#{dialog['id']}').showModal()")
    end
  end

  describe 'the link from the account page' do
    let(:label) { I18n.t('devise.registrations.edit.import_from_automated_backups') }

    it 'is shown to an admin on a self-hosted instance and points at the Backups section' do
      sign_in admin

      get edit_user_registration_path

      expect(response.body).to include(label)
      expect(response.body).to include('/admin/settings?section=backups')
    end

    it 'is not shown to a regular user' do
      sign_in non_admin

      get edit_user_registration_path

      expect(response.body).not_to include(label)
    end

    it 'is not shown on a cloud instance' do
      allow(DawarichSettings).to receive(:self_hosted?).and_return(false)
      sign_in admin

      get edit_user_registration_path

      expect(response.body).not_to include(label)
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
