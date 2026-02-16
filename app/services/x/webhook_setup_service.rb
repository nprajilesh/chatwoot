class X::WebhookSetupService
  # This service ensures a global webhook is registered for the X Account Activity API v2.
  # Unlike per-channel webhooks, X uses one webhook per installation that receives events
  # for all subscribed users. Each channel then subscribes individually to this webhook.

  def self.ensure_webhook_registered
    new.ensure_webhook_registered
  end

  def ensure_webhook_registered
    # Check if webhook is already registered
    webhook_id = GlobalConfigService.load('X_WEBHOOK_ID', nil)
    return webhook_id if webhook_id.present?

    # Register new webhook
    webhook_id = register_webhook
    if webhook_id
      update_webhook_id(webhook_id)
      webhook_id
    end
  rescue StandardError => e
    Rails.logger.error "Failed to ensure X webhook registered: #{e.message}"
    nil
  end

  private

  def register_webhook
    webhook_url = "#{ENV.fetch('FRONTEND_URL', nil)}/webhooks/x"

    Rails.logger.info "Registering X webhook: #{webhook_url}"

    # V2 endpoint: POST /2/webhooks
    response = HTTParty.post(
      'https://api.x.com/2/webhooks',
      headers: {
        'Authorization' => "Bearer #{app_bearer_token}",
        'Content-Type' => 'application/json'
      },
      body: { url: webhook_url }.to_json
    )

    if response.code == 200 || response.code == 201
      webhook_data = response.parsed_response
      webhook_id = webhook_data.is_a?(Hash) ? (webhook_data.dig('data', 'id') || webhook_data['id']) : nil
      raise 'No webhook ID returned from X API' unless webhook_id

      Rails.logger.info "Successfully registered X webhook with ID: #{webhook_id}"
      webhook_id
    else
      error_msg = extract_error_message(response)
      raise "X webhook registration failed (#{response.code}): #{error_msg}"
    end
  rescue StandardError => e
    Rails.logger.error "X webhook registration failed: #{e.message}"
    raise
  end

  def app_bearer_token
    @app_bearer_token ||= fetch_app_bearer_token
  end

  def fetch_app_bearer_token
    # App-only bearer token uses API Key (Consumer Key) / API Secret (Consumer Secret)
    # NOT the OAuth 2.0 Client ID/Secret which is for user auth PKCE flow
    api_key = GlobalConfigService.load('X_API_KEY', '')
    api_secret = GlobalConfigService.load('X_API_SECRET', '')

    raise 'X_API_KEY or X_API_SECRET not configured' if api_key.blank? || api_secret.blank?

    credentials = Base64.strict_encode64("#{CGI.escape(api_key)}:#{CGI.escape(api_secret)}")

    response = HTTParty.post(
      'https://api.x.com/oauth2/token',
      headers: {
        'Authorization' => "Basic #{credentials}",
        'Content-Type' => 'application/x-www-form-urlencoded;charset=UTF-8'
      },
      body: 'grant_type=client_credentials'
    )

    if response.code == 200
      response.parsed_response['access_token']
    else
      raise "Failed to get app bearer token: #{response.body}"
    end
  end

  def update_webhook_id(webhook_id)
    config = InstallationConfig.find_by(name: 'X_WEBHOOK_ID')
    if config
      config.update!(value: webhook_id)
    else
      InstallationConfig.create!(name: 'X_WEBHOOK_ID', value: webhook_id)
    end
    GlobalConfig.clear_cache
  end

  def extract_error_message(response)
    if response.parsed_response.is_a?(Hash)
      response.parsed_response.dig('errors', 0, 'message') ||
        response.parsed_response['error'] ||
        response.body
    else
      response.body
    end
  end
end
