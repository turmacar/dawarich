# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Backups::Writer do
  around do |example|
    Dir.mktmpdir('backups-writer') do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  it 'writes the file and reports its size' do
    result = described_class.new(@dir).write('a.zip') { |file, _path| file.write('hello') }

    expect(result.path).to eq(@dir.join('a.zip'))
    expect(result.bytes).to eq(5)
    expect(File.read(result.path)).to eq('hello')
  end

  it 'writes binary data unchanged' do
    bytes = (0..255).map(&:chr).join.b

    result = described_class.new(@dir).write('a.zip') { |file, _path| file.write(bytes) }

    expect(File.binread(result.path)).to eq(bytes)
  end

  it 'keeps the file private to the owner' do
    result = described_class.new(@dir).write('a.zip') { |file, _path| file.write('x') }

    expect(File.stat(result.path).mode & 0o777).to eq(0o600)
  end

  it 'leaves nothing behind and keeps the previous file when the block fails' do
    File.write(@dir.join('a.zip'), 'old')

    expect { described_class.new(@dir).write('a.zip') { |_file, _path| raise 'disk full' } }
      .to raise_error('disk full')

    expect(@dir.children.map { _1.basename.to_s }).to eq(['a.zip'])
    expect(File.read(@dir.join('a.zip'))).to eq('old')
  end

  it 'lets the block hand the temporary path to another process' do
    result = described_class.new(@dir).write('dump.bin') { |_file, path| File.write(path, 'from a child process') }

    expect(File.read(result.path)).to eq('from a child process')
  end

  it 'rejects names that could escape the directory or hide the file' do
    ['', '../a.zip', 'sub/a.zip', '.hidden'].each do |name|
      expect { described_class.new(@dir).write(name) { |_file, _path| nil } }
        .to raise_error(ArgumentError), "expected #{name.inspect} to be rejected"
    end
  end
end
