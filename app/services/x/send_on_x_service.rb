class X::SendOnXService < Base::SendOnChannelService
  private

  def channel_class
    Channel::X
  end

  def perform_reply
    ensure_valid_token!
    message_result = send_message
    source_id = extract_source_id(message_result)
    message.update!(source_id: source_id)
    Messages::StatusUpdateService.new(message, 'delivered').perform
  rescue X::Errors::UnauthorizedError => e
    handle_send_error(e, 'Authorization failed') { channel.authorization_error! }
  rescue X::Errors::RateLimitError => e
    handle_send_error(e, 'Rate limit exceeded')
  rescue StandardError => e
    handle_send_error(e, e.message)
  end

  def handle_send_error(error, error_message, &block)
    Rails.logger.error "X send error for channel #{channel.id}: #{error.message}"
    block&.call
    Messages::StatusUpdateService.new(message, 'failed', error_message).perform
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
    reply_to_tweet_id = find_reply_to_tweet_id

    # Prepend @screen_name like old Twitter did for tweet replies
    tweet_text = "#{screen_name_mention} #{message.outgoing_content}".strip

    x_client.create_tweet(
      text: tweet_text,
      reply_to_tweet_id: reply_to_tweet_id
    )
  end

  def screen_name_mention
    # Get the contact's screen_name to @mention in the reply
    username = contact.additional_attributes&.dig('username') || contact.additional_attributes&.dig('screen_name')
    username.present? ? "@#{username}" : ''
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
    conversation = message.conversation
    conversation.additional_attributes&.dig('type') == 'tweet'
  end

  def extract_source_id(result)
    # Tweet response: { "data" => { "id" => "123" } }
    # DM response: { "data" => { "dm_event_id" => "456" } } or { "dm_event_id" => "456" }
    result.dig('data', 'id') || result.dig('data', 'dm_event_id') || result['dm_event_id'] || result['id']
  end

  def find_reply_to_tweet_id
    # Find the latest message with a source_id in the conversation to reply in thread
    # Mirrors old Twitter pattern: reply to the latest tweet in the conversation
    latest_tweet = message.conversation.messages
                          .where.not(source_id: [nil, ''])
                          .order(created_at: :desc)
                          .first
    latest_tweet&.source_id || message.conversation.additional_attributes&.dig('tweet_id')
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
