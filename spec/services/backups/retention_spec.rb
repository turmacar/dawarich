# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Backups::Retention do
  around do |example|
    Dir.mktmpdir('backups-retention') do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  let(:user) { create(:user) }

  def completed_run(name, started_at, user: self.user)
    File.write(@dir.join(name), name)
    create(:backup_run, :completed, user: user, file_name: name, started_at: started_at)
  end

  def retain(keep, scope: BackupRun.kind_user_export.where(user: user))
    described_class.new(scope: scope, directory: @dir, keep: keep).call
  end

  it 'keeps the newest runs and deletes older files and rows' do
    oldest = completed_run('1.zip', 3.days.ago)
    middle = completed_run('2.zip', 2.days.ago)
    newest = completed_run('3.zip', 1.day.ago)

    retain(2)

    expect(BackupRun.where(id: [oldest.id, middle.id, newest.id])).to contain_exactly(middle, newest)
    expect(@dir.children.map { _1.basename.to_s }).to contain_exactly('2.zip', '3.zip')
  end

  it 'does nothing while there are no more runs than the limit' do
    completed_run('1.zip', 2.days.ago)
    completed_run('2.zip', 1.day.ago)

    expect { retain(2) }.not_to change(BackupRun, :count)
    expect(@dir.children.size).to eq(2)
  end

  it 'never touches files that no run refers to' do
    File.write(@dir.join('notes.txt'), 'mine')
    completed_run('1.zip', 2.days.ago)
    completed_run('2.zip', 1.day.ago)

    retain(1)

    expect(File.read(@dir.join('notes.txt'))).to eq('mine')
  end

  it 'only prunes the scope it was given' do
    other = create(:user)
    completed_run('a.zip', 3.days.ago)
    completed_run('b.zip', 2.days.ago)
    theirs = completed_run('c.zip', 5.days.ago, user: other)

    retain(1)

    expect(BackupRun.exists?(theirs.id)).to be(true)
    expect(File.exist?(@dir.join('c.zip'))).to be(true)
  end

  it 'still removes the row when the file is already gone' do
    run = completed_run('1.zip', 2.days.ago)
    completed_run('2.zip', 1.day.ago)
    File.delete(@dir.join('1.zip'))

    retain(1)

    expect(BackupRun.exists?(run.id)).to be(false)
  end

  it 'will not delete outside the directory even if a row names a path' do
    outside = Dir.mktmpdir('backups-outside')
    File.write(File.join(outside, 'victim.txt'), 'keep me')
    create(:backup_run, :completed, user: user, file_name: "../#{File.basename(outside)}/victim.txt",
                                    started_at: 3.days.ago)
    completed_run('2.zip', 1.day.ago)

    retain(1)

    expect(File.read(File.join(outside, 'victim.txt'))).to eq('keep me')
  ensure
    FileUtils.rm_rf(outside)
  end

  it 'drops failed runs once they are old, and keeps recent ones' do
    old_failure = create(:backup_run, status: :failed, user: user, finished_at: 31.days.ago)
    recent_failure = create(:backup_run, status: :failed, user: user, finished_at: 1.day.ago)

    retain(5)

    expect(BackupRun.where(id: [old_failure.id, recent_failure.id])).to contain_exactly(recent_failure)
  end
end
