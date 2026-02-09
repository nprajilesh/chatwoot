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
#  webhook_id                 :string
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
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
  after_create :setup_webhook

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

  def setup_webhook
    X::WebhookSetupService.new(channel: self).perform
  rescue StandardError => e
    Rails.logger.error("Failed to setup X webhook: #{e.message}")
  end
end
