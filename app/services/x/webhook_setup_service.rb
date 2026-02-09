class X::WebhookSetupService
  pattr_initialize [:channel!]

  def perform
    return if webhook_already_registered?

    register_webhook
  rescue StandardError => e
    Rails.logger.error "Failed to setup X webhook for channel #{channel.id}: #{e.message}"
    raise
  end

  private

  def webhook_already_registered?
    channel.webhook_id.present?
  end

  def register_webhook
    # X Account Activity API endpoint for webhook registration
    # POST /1.1/account_activity/all/:env_name/webhooks.json
    env_name = GlobalConfigService.load('X_WEBHOOK_ENV', 'production')
    webhook_url = "#{ENV.fetch('FRONTEND_URL', nil)}/webhooks/x"

    response = HTTParty.post(
      "https://api.x.com/1.1/account_activity/all/#{env_name}/webhooks.json",
      headers: {
        'Authorization' => "Bearer #{channel.bearer_token}",
        'Content-Type' => 'application/json'
      },
      body: { url: webhook_url }.to_json
    )

    if response.code == 200 || response.code == 201
      webhook_data = response.parsed_response
      channel.update!(webhook_id: webhook_data['id'])
      Rails.logger.info "Successfully registered X webhook for channel #{channel.id}"
    else
      error_msg = response.parsed_response&.dig('errors', 0, 'message') || response.body
      raise "Failed to register webhook: #{error_msg}"
    end
  rescue StandardError => e
    # Don't fail channel creation if webhook setup fails
    # Webhooks can be set up later manually if needed
    Rails.logger.error "X webhook registration failed: #{e.message}"
    nil
  end
end
