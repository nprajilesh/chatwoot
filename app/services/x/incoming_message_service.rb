class X::IncomingMessageService
  pattr_initialize [:channel!, :message_data, :tweet_data]

  def perform
    # Skip if this is an outgoing message (echo)
    return if outgoing_message?

    # Skip if message already exists
    return if message_exists?

    create_message
  end

  private

  def outgoing_message?
    # For DMs: sender is the channel's profile
    # For tweets: already filtered in job
    return sender_id == channel.profile_id if direct_message?

    false
  end

  def message_exists?
    Message.exists?(source_id: message_source_id)
  end

  def contact_inbox
    @contact_inbox ||= ::ContactInboxWithContactBuilder.new(
      source_id: sender_id,
      inbox: channel.inbox,
      contact_attributes: contact_attributes
    ).perform
  end

  def contact
    contact_inbox.contact
  end

  def conversation
    @conversation ||= contact_inbox.conversations.first || create_conversation
  end

  def create_conversation
    ::Conversation.create!(
      account_id: channel.inbox.account_id,
      inbox_id: channel.inbox.id,
      contact_id: contact.id,
      contact_inbox_id: contact_inbox.id,
      additional_attributes: {
        x_user_id: sender_id
      }
    )
  end

  def create_message
    message = conversation.messages.build(
      content: message_content,
      account_id: channel.inbox.account_id,
      inbox_id: channel.inbox.id,
      message_type: :incoming,
      source_id: message_source_id,
      created_at: message_timestamp,
      updated_at: message_timestamp
    )

    message.sender = contact

    create_attachments(message)
    message.save!
  end

  def contact_attributes
    # Fetch user profile from X if we don't have cached data
    user_data = fetch_user_profile

    {
      name: user_data['name'] || user_data['username'],
      avatar_url: user_data['profile_image_url'],
      additional_attributes: {
        username: user_data['username'],
        social_profiles: { x: user_data['username'] },
        social_x_user_id: sender_id
      }
    }
  end

  def fetch_user_profile
    # Use cached data from webhook if available
    return @message_data[:sender] if @message_data&.[](:sender).present?
    return @tweet_data[:user] if @tweet_data&.[](:user).present?

    # Otherwise fetch from API
    channel.client.user(sender_id)['data']
  rescue StandardError => e
    Rails.logger.error("Failed to fetch X user profile for #{sender_id}: #{e.message}")
    # Return minimal data
    { 'username' => sender_id, 'name' => sender_id }
  end

  def create_attachments(message)
    # Handle DM attachments
    create_dm_attachment(message, @message_data[:attachment]) if direct_message? && @message_data&.[](:attachment).present?

    # Tweet attachments (images, videos) from extended_entities
    return unless tweet_message? && @tweet_data&.[](:extended_entities).present?

    create_tweet_attachments(message, @tweet_data[:extended_entities][:media])
  end

  def create_dm_attachment(message, attachment)
    case attachment[:type]
    when 'media'
      message.attachments.new(
        account_id: message.account_id,
        file_type: determine_file_type(attachment[:media]),
        external_url: attachment[:media][:url]
      )
    end
  end

  def create_tweet_attachments(message, media_items)
    media_items&.each do |media|
      message.attachments.new(
        account_id: message.account_id,
        file_type: media[:type] == 'photo' ? :image : :video,
        external_url: media[:media_url_https]
      )
    end
  end

  def determine_file_type(media)
    content_type = media[:content_type] || ''
    return :image if content_type.start_with?('image/')
    return :video if content_type.start_with?('video/')

    :file
  end

  def message_content
    return @message_data.dig(:message_data, :text) if direct_message?
    return @tweet_data[:text] if tweet_message?

    ''
  end

  def sender_id
    return @message_data.dig(:message_data, :sender_id) if direct_message?
    return @tweet_data.dig(:user, :id_str) if tweet_message?

    nil
  end

  def message_source_id
    return @message_data.dig(:message_data, :id) if direct_message?
    return @tweet_data[:id_str] if tweet_message?

    nil
  end

  def message_timestamp
    if direct_message?
      timestamp_ms = @message_data.dig(:message_data, :created_timestamp).to_i
      Time.zone.at(timestamp_ms / 1000).utc
    elsif tweet_message?
      Time.zone.parse(@tweet_data[:created_at]).utc
    else
      Time.current.utc
    end
  end

  def direct_message?
    @message_data.present?
  end

  def tweet_message?
    @tweet_data.present?
  end
end
