# frozen_string_literal: true

FactoryBot.define do
  factory :channel_x, class: 'Channel::X' do
    account
    profile_id { SecureRandom.hex(8) }
    username { "user_#{SecureRandom.hex(4)}" }
    name { Faker::Name.name }
    profile_image_url { Faker::Internet.url }
    bearer_token { SecureRandom.hex(32) }
    refresh_token { SecureRandom.hex(32) }
    token_expires_at { 2.hours.from_now }
    refresh_token_expires_at { 6.months.from_now }

    after(:create) do |channel|
      create(:inbox, channel: channel, account: channel.account)
    end
  end
end
