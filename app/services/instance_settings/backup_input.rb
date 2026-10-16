# frozen_string_literal: true

module InstanceSettings
  class BackupInput
    FREQUENCIES = %w[off daily weekly monthly].freeze
    RETENTION_RANGE = (1..365)

    attr_reader :values, :errors

    def initialize(values)
      @values = values.dup
      @errors = []

      normalize
      validate_frequency
      validate_path
      validate_retention
    end

    def valid?
      errors.empty?
    end

    private

    def normalize
      values[:backup_export_frequency] = values[:backup_export_frequency].downcase if string?(:backup_export_frequency)
      return unless string?(:backup_export_path)

      values[:backup_export_path] = values[:backup_export_path].strip.sub(%r{(?<=.)/+\z}, '')
    end

    def validate_frequency
      return unless values.key?(:backup_export_frequency)
      return if FREQUENCIES.include?(values[:backup_export_frequency])

      errors << I18n.t('admin.settings.update.backup_frequency_invalid', allowed: FREQUENCIES.join(', '))
    end

    # The directory must already exist; it is never created, so a missing bind
    # mount cannot silently turn into a backup on the container filesystem.
    def validate_path
      path = values[:backup_export_path]
      return if path.blank?

      errors << I18n.t('admin.settings.update.backup_path_invalid') unless valid_path?(path)
    end

    def valid_path?(path)
      path.start_with?('/') && path.length > 1 && !path.include?("\0") && path.split('/').exclude?('..')
    end

    def validate_retention
      return unless values.key?(:backup_export_retention)
      return if RETENTION_RANGE.cover?(values[:backup_export_retention])

      errors << I18n.t('admin.settings.update.backup_retention_invalid',
                       min: RETENTION_RANGE.min, max: RETENTION_RANGE.max)
    end

    def string?(key)
      values[key].is_a?(String)
    end
  end
end
