# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Backups::Destination do
  around do |example|
    Dir.mktmpdir('backups-destination') do |dir|
      @dir = dir
      example.run
    end
  end

  it 'is not configured without a path' do
    expect(described_class.new('')).not_to be_configured
    expect(described_class.new(nil)).not_to be_configured
  end

  it 'resolves an existing writable directory' do
    expect(described_class.new(@dir).root).to eq(Pathname.new(@dir).realpath)
  end

  it 'refuses a missing directory and does not create it' do
    missing = File.join(@dir, 'not-mounted')

    expect { described_class.new(missing).root }.to raise_error(described_class::Unavailable, /does not exist/)
    expect(File.exist?(missing)).to be(false)
  end

  it 'refuses a relative path' do
    expect { described_class.new('backups').root }.to raise_error(described_class::Unavailable, /absolute/)
  end

  it 'refuses a directory that cannot be written to' do
    FileUtils.chmod(0o500, @dir)
    skip 'running as root, permissions are not enforced' if File.writable?(@dir)

    expect { described_class.new(@dir).root }.to raise_error(described_class::Unavailable, /not writable/)
  ensure
    FileUtils.chmod(0o700, @dir)
  end

  it 'refuses the public web directory' do
    expect { described_class.new(Rails.public_path.to_s).root }
      .to raise_error(described_class::Unavailable, /public web directory/)
  end

  it 'creates subdirectories under the root' do
    sub = described_class.new(@dir).subdirectory('user-exports')

    expect(sub).to be_directory
    expect(sub.parent).to eq(Pathname.new(@dir).realpath)
  end

  it 'reads the path from the instance setting by default' do
    InstanceSetting.create!(key: 'backup_export_path', value: @dir)
    InstanceSettings::Resolver.reset!

    expect(described_class.new.root).to eq(Pathname.new(@dir).realpath)
  ensure
    InstanceSettings::Resolver.reset!
  end
end
