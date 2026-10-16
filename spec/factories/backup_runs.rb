# frozen_string_literal: true

FactoryBot.define do
  factory :backup_run do
    kind { :user_export }
    status { :running }
    started_at { Time.current }
    user

    trait :database_dump do
      kind { :database_dump }
      user { nil }
    end

    trait :completed do
      status { :completed }
      file_name { 'backup.zip' }
      bytes { 1024 }
      finished_at { Time.current }
    end
  end
end
