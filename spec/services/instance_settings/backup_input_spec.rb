# frozen_string_literal: true

require 'rails_helper'

RSpec.describe InstanceSettings::BackupInput do
  def input(values)
    described_class.new(values)
  end

  describe 'frequency' do
    %w[off daily weekly monthly].each do |frequency|
      it "accepts #{frequency}" do
        expect(input(backup_export_frequency: frequency)).to be_valid
      end
    end

    it 'normalizes case' do
      result = input(backup_export_frequency: 'Weekly')

      expect(result).to be_valid
      expect(result.values[:backup_export_frequency]).to eq('weekly')
    end

    it 'rejects anything else and names the allowed values' do
      result = input(backup_export_frequency: 'hourly')

      expect(result).not_to be_valid
      expect(result.errors.join).to include('daily', 'weekly', 'monthly')
    end
  end

  describe 'path' do
    it 'accepts an absolute path and drops trailing slashes' do
      result = input(backup_export_path: '/backups/dawarich//')

      expect(result).to be_valid
      expect(result.values[:backup_export_path]).to eq('/backups/dawarich')
    end

    it 'allows clearing the path' do
      expect(input(backup_export_path: nil)).to be_valid
      expect(input(backup_export_path: '')).to be_valid
    end

    it 'rejects relative paths, parent segments, the filesystem root and NUL bytes' do
      ['backups', './backups', '/backups/../etc', '/', "/backups/\0x"].each do |path|
        expect(input(backup_export_path: path)).not_to be_valid, "expected #{path.inspect} to be rejected"
      end
    end

    it 'keeps dots inside a segment' do
      expect(input(backup_export_path: '/backups/dawarich..old')).to be_valid
    end
  end

  describe 'retention' do
    it 'accepts the bounds' do
      expect(input(backup_export_retention: 1)).to be_valid
      expect(input(backup_export_retention: 365)).to be_valid
    end

    it 'rejects values outside the bounds' do
      expect(input(backup_export_retention: 0)).not_to be_valid
      expect(input(backup_export_retention: 366)).not_to be_valid
    end
  end

  it 'ignores keys that were not submitted' do
    expect(input({})).to be_valid
  end
end
