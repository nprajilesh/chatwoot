class X::SendOnXService < Base::SendOnChannelService
  private

  def channel_class
    Channel::X
  end

  def perform_reply
    # Ensure we have a valid access token before sending
    ensure_valid_token!

    message_result = send_message

    # Update message with source_id from X
    message.update!(source_id: message_result['id'])
    Messages::StatusUpdateService.new(message, 'delivered').perform
  rescue X::Errors::UnauthorizedError => e
    Rails.logger.error "X authorization failed for channel #{channel.id}: #{e.message}"
    channel.authorization_error!
    Messages::StatusUpdateService.new(message, 'failed', 'Authorization failed').perform
  rescue X::Errors::RateLimitError => e
    Rails.logger.error "X rate limit exceeded for channel #{channel.id}: #{e.message}"
    Messages::StatusUpdateService.new(message, 'failed', 'Rate limit exceeded').perform
  rescue StandardError => e
    Rails.logger.error "Failed to send X message: #{e.message}"
    Messages::StatusUpdateService.new(message, 'failed', e.message).perform
  end

  def ensure_valid_token!
    X::TokenService.new(channel: channel).access_token
  end

  def send_message
    if tweet_reply?
      send_tweet_reply
    else
      send_direct_message
    end
  end

  def send_direct_message
    x_user_id = contact_inbox.source_id
    attachments = process_attachments

    x_client.send_direct_message(
      participant_id: x_user_id,
      text: message.outgoing_content || '',
      attachments: attachments
    )
  end

  def send_tweet_reply
    # Get the original tweet ID from conversation additional attributes
    reply_to_tweet_id = message.content_attributes['in_reply_to_external_id']

    x_client.create_tweet(
      text: message.outgoing_content,
      reply_to_tweet_id: reply_to_tweet_id
    )
  end

  def process_attachments
    return nil if message.attachments.empty?

    # X DM API supports multiple attachments
    message.attachments.map do |attachment|
      media_id = upload_media(attachment)
      { media_id: media_id }
    end
  end

  def upload_media(attachment)
    # Download the attachment
    file_data = Down.download(attachment.download_url)

    # Upload to X
    result = x_client.upload_media(
      file_data.read,
      mime_type: attachment.file.content_type
    )

    result['media_id_string']
  rescue StandardError => e
    Rails.logger.error "Failed to upload media to X: #{e.message}"
    raise
  end

  def tweet_reply?
    # Check if this is a reply to a tweet (has in_reply_to_external_id in content_attributes)
    message.content_attributes['in_reply_to_external_id'].present?
  end

  def x_client
    @x_client ||= channel.client
  end

  def inbox
    @inbox ||= message.inbox
  end

  def channel
    @channel ||= inbox.channel
  end
end
