# == Schema Information
#
# Table name: channel_x
#
#  id                         :bigint           not null, primary key
#  account_id                 :bigint           not null
#  profile_id                 :string           not null
#  username                   :string           not null
#  name                       :string
#  profile_image_url          :string
#  bearer_token               :string
#  refresh_token              :string
#  token_expires_at           :datetime
#  refresh_token_expires_at   :datetime
#  authorization_error_count  :integer          default(0)
#  webhook_id                 :string           (deprecated - using global webhook now)
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#
# X uses a global webhook pattern (like Instagram/TikTok):
# - One webhook URL configured for the entire installation
# - Each user subscribes to this webhook individually
# - Events include for_user_id to route to correct channel
#

class Channel::X < ApplicationRecord
  include Channelable
  include Reauthorizable

  self.table_name = 'channel_x'

  # Encrypt sensitive tokens
  encrypts :bearer_token if Chatwoot.encryption_configured?
  encrypts :refresh_token if Chatwoot.encryption_configured?

  # Validations
  validates :profile_id, presence: true, uniqueness: true
  validates :username, presence: true
  validates :account_id, presence: true

  # Associations
  belongs_to :account

  # Callbacks
  after_create_commit :subscribe_to_webhook
  before_destroy :unsubscribe_from_webhook

  # Check if access token is expired
  def token_expired?
    return true if token_expires_at.blank?

    Time.current >= token_expires_at
  end

  # Check if refresh token is still valid
  def refresh_token_valid?
    return false if refresh_token_expires_at.blank?

    Time.current < refresh_token_expires_at
  end

  # Get X API client
  def client
    @client ||= X::Client.new(bearer_token: bearer_token)
  end

  # Required by Reauthorizable concern
  def name
    'X'
  end

  private

  def subscribe_to_webhook
    # Subscribe this user to the global webhook (Instagram pattern)
    # Similar to Instagram's subscribe() method using page token
    X::SubscriptionService.new(channel: self).subscribe
  rescue StandardError => e
    Rails.logger.error("Failed to subscribe X user to webhook: #{e.message}")
  end

  def unsubscribe_from_webhook
    X::SubscriptionService.new(channel: self).unsubscribe
  rescue StandardError => e
    Rails.logger.error("Failed to unsubscribe X user from webhook: #{e.message}")
    true # Don't fail destroy
  end
end
