# frozen_string_literal: true

# Exports one user's data to the backup directory, then prunes older copies.
class Backups::UserExportJob < ApplicationJob
  queue_as :exports

  sidekiq_options retry: false

  def perform(user_id)
    user = find_user_or_skip(user_id) || return
    directory = Backups::Destination.new.subdirectory('user-exports')
    run = BackupRun.create!(kind: :user_export, user: user, started_at: Time.current)

    export = nil
    begin
      export = Users::ExportData.new(user, notify: false).export
      filename = filename_for(user)
      result = Backups::Writer.new(directory).write(filename) do |file, _partial|
        export.file.download { |chunk| file.write(chunk) }
      end

      run.complete!(file_name: filename, bytes: result.bytes)
      prune(user, directory)
    rescue StandardError => e
      run.fail!(e.message)
      ExceptionReporter.call(e, 'Scheduled backup failed')
      notify_admins(user, e.message)
    ensure
      # The external copy is the backup; keeping the stored export would fill storage twice.
      export&.destroy
    end
  end

  private

  def filename_for(user)
    email = user.email.gsub(/[^0-9A-Za-z._-]/, '_').sub(/\A\.+/, '')
    "#{email}-#{user.id}_#{Time.current.strftime('%Y%m%d_%H%M%S')}.zip"
  end

  def prune(user, directory)
    Backups::Retention.new(
      scope: BackupRun.kind_user_export.where(user: user),
      directory: directory,
      keep: InstanceSettings::Resolver.value(:backup_export_retention)
    ).call
  end

  def notify_admins(user, error)
    User.where(admin: true).find_each do |admin|
      I18n.with_locale(admin.locale) do
        Notifications::Create.new(
          user: admin,
          kind: :error,
          title: I18n.t('jobs.backups.user_export.failed_title'),
          content: I18n.t('jobs.backups.user_export.failed_content', email: user.email, error: error)
        ).call
      end
    end
  end
end
