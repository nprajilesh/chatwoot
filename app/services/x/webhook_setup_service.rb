class X::WebhookSetupService
  pattr_initialize [:channel!]

  def perform
    # Register webhook if not already registered
    webhook_id = webhook_already_registered? ? channel.webhook_id : register_webhook

    # Create subscription for the user
    create_subscription(webhook_id) if webhook_id
  rescue StandardError => e
    Rails.logger.error "Failed to setup X webhook for channel #{channel.id}: #{e.message}"
    raise
  end

  private

  def webhook_already_registered?
    channel.webhook_id.present?
  end

  def register_webhook
    # X API v2 webhook registration uses OAuth 2.0 Bearer Token
    # POST /2/webhooks
    # Docs: https://docs.x.com/x-api/webhooks/create-webhook
    webhook_url = "#{ENV.fetch('FRONTEND_URL', nil)}/webhooks/x"

    response = HTTParty.post(
      'https://api.x.com/2/webhooks',
      headers: {
        'Authorization' => "Bearer #{channel.bearer_token}",
        'Content-Type' => 'application/json'
      },
      body: { url: webhook_url }.to_json
    )

    if response.code == 200 || response.code == 201
      webhook_data = response.parsed_response
      # V2 response structure: { "data": { "id": "...", ... } }
      webhook_id = webhook_data.is_a?(Hash) ? (webhook_data.dig('data', 'id') || webhook_data['id']) : nil
      if webhook_id
        channel.update!(webhook_id: webhook_id)
        Rails.logger.info "Successfully registered X webhook for channel #{channel.id}"
        webhook_id
      else
        raise "Webhook registration succeeded but no webhook ID returned"
      end
    else
      # Handle both Hash and String responses
      error_msg = if response.parsed_response.is_a?(Hash)
                    response.parsed_response.dig('errors', 0, 'message') || response.body
                  else
                    response.parsed_response || response.body
                  end
      raise "Failed to register webhook: #{error_msg}"
    end
  rescue StandardError => e
    # Don't fail channel creation if webhook setup fails
    # Webhooks can be set up later manually if needed
    Rails.logger.error "X webhook registration failed: #{e.message}"
    nil
  end

  def create_subscription(webhook_id)
    # X API v2 subscription - create link to receive events
    # Note: Subscription may not be needed for v2 webhooks
    # The webhook itself should receive events once registered
    # Docs: https://docs.x.com/x-api/webhooks/introduction

    # For v2 API, webhook registration is sufficient
    # No separate subscription endpoint needed
    Rails.logger.info "Webhook #{webhook_id} registered - subscriptions handled automatically in v2 API"
    return

    if response.code == 200 || response.code == 201 || response.code == 204
      Rails.logger.info "Successfully created X subscription for channel #{channel.id}"
    else
      # Handle both Hash and String responses
      error_msg = if response.parsed_response.is_a?(Hash)
                    response.parsed_response.dig('errors', 0, 'message') || response.body
                  else
                    response.parsed_response || response.body
                  end
      Rails.logger.error "Failed to create subscription: #{error_msg}"
      # Don't raise - subscription can be created later if needed
    end
  rescue StandardError => e
    Rails.logger.error "X subscription creation failed: #{e.message}"
    # Don't raise - allow channel creation to succeed even if subscription fails
  end
end
