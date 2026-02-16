class X::IncomingMessageService
  pattr_initialize [:channel!, :dm_event, :tweet_data, :users]

  def perform
    return if outgoing_dm?
    return if message_exists?

    create_message
  end

  private

  # Only skip outgoing DMs — outgoing tweets are handled as echoes
  # (like old Twitter's TweetParserService which created outgoing messages)
  def outgoing_dm?
    direct_message? && sender_id == channel.profile_id
  end

  def outgoing_tweet?
    tweet_message? && sender_id == channel.profile_id
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
    @conversation ||= find_existing_conversation || create_conversation
  end

  # Find an existing conversation of the same type (tweet or dm) for this contact
  # Mirrors old Twitter patterns:
  # - DMs: find by additional_attributes.type = 'direct_message' (DirectMessageParserService#set_conversation)
  # - Tweets: find by additional_attributes.tweet_id matching parent_tweet_id (TweetParserService#set_conversation)
  def find_existing_conversation
    if tweet_message?
      find_tweet_conversation
    else
      find_dm_conversation
    end
  end

  # Old Twitter pattern: TweetParserService looked up conversations by parent tweet_id,
  # then fell back to finding a message by source_id to find its conversation
  def find_tweet_conversation
    parent_id = parent_tweet_id

    # First: find conversation by tweet_id in additional_attributes (like old Twitter)
    inbox_conversations = Conversation.where(inbox_id: channel.inbox.id)
    tweet_conv = inbox_conversations.find do |conv|
      conv.additional_attributes&.dig('tweet_id') == parent_id
    end
    return tweet_conv if tweet_conv

    # Fallback: find a message with parent tweet's source_id and use its conversation
    # (like old Twitter's TweetParserService#set_conversation)
    parent_message = channel.inbox.messages.find_by(source_id: parent_id)
    return parent_message.conversation if parent_message

    nil
  end

  def find_dm_conversation
    # For DMs: find any DM conversation for this contact (like old Twitter)
    contact_inbox.conversations.where("additional_attributes ->> 'type' = 'direct_message'").first
  end

  def create_conversation
    ::Conversation.create!(
      account_id: channel.inbox.account_id,
      inbox_id: channel.inbox.id,
      contact_id: contact.id,
      contact_inbox_id: contact_inbox.id,
      additional_attributes: conversation_additional_attributes
    )
  end

  def conversation_additional_attributes
    if tweet_message?
      {
        type: 'tweet',
        tweet_id: parent_tweet_id
      }
    else
      {
        type: 'direct_message'
      }
    end
  end

  # Like old Twitter's TweetParserService#parent_tweet_id:
  # If tweet is a reply, use in_reply_to_status_id_str as the parent.
  # Otherwise, use the tweet's own id as the parent (it starts a new thread).
  def parent_tweet_id
    @tweet_data[:in_reply_to_status_id_str].presence || @tweet_data[:id_str]
  end

  def create_message
    msg = conversation.messages.build(
      content: message_content,
      account_id: channel.inbox.account_id,
      inbox_id: channel.inbox.id,
      message_type: message_type,
      source_id: message_source_id,
      content_attributes: message_content_attributes,
      created_at: message_timestamp,
      updated_at: message_timestamp
    )

    msg.sender = contact unless outgoing_tweet?

    create_attachments(msg)
    msg.save!

    # Update conversation's tweet_id to latest for thread replies
    update_conversation_tweet_id if tweet_message?
  end

  # Like old Twitter's TweetParserService: outgoing tweets become :outgoing messages
  def message_type
    outgoing_tweet? ? :outgoing : :incoming
  end

  def update_conversation_tweet_id
    attrs = conversation.additional_attributes || {}
    attrs['tweet_id'] = parent_tweet_id
    conversation.update!(additional_attributes: attrs)
  end

  def contact_attributes
    user_data = fetch_user_profile
    username = user_data['screen_name'] || user_data['username']

    {
      name: user_data['name'] || username,
      avatar_url: user_data['profile_image_url'] || user_data['profile_image_url_https'],
      additional_attributes: {
        screen_name: username,
        username: username,
        social_profiles: { x: username },
        social_x_user_id: sender_id,
        # Store additional profile data like old Twitter's WebhooksBaseService
        description: user_data['description'],
        location: user_data['location']
      }
    }
  end

  def fetch_user_profile
    return @users[sender_id].with_indifferent_access if @users.present? && @users[sender_id].present?
    return @tweet_data[:user].with_indifferent_access if @tweet_data&.[](:user).present?

    channel.client.user(sender_id)['data']
  rescue StandardError => e
    Rails.logger.error("Failed to fetch X user profile for #{sender_id}: #{e.message}")
    { 'username' => sender_id, 'name' => sender_id }
  end

  def create_attachments(msg)
    dm_attachment = @dm_event&.dig(:message_create, :message_data, :attachment)
    create_dm_attachment(msg, dm_attachment) if direct_message? && dm_attachment.present?
    create_tweet_attachments(msg) if tweet_message? && @tweet_data&.[](:extended_entities).present?
  end

  def create_dm_attachment(msg, attachment)
    return unless attachment[:type] == 'media'

    media_data = attachment[:media]
    msg.attachments.new(account_id: msg.account_id, file_type: determine_dm_file_type(media_data), external_url: media_data[:url])
  end

  def determine_dm_file_type(media)
    content_type = media[:content_type] || ''
    return :image if content_type.start_with?('image/')
    return :video if content_type.start_with?('video/')

    :file
  end

  def create_tweet_attachments(msg)
    @tweet_data[:extended_entities][:media]&.each do |media|
      msg.attachments.new(
        account_id: msg.account_id, file_type: media[:type] == 'photo' ? :image : :video,
        external_url: media[:media_url_https]
      )
    end
  end

  def message_content
    return @dm_event.dig(:message_create, :message_data, :text) if direct_message?
    return (@tweet_data[:truncated] ? @tweet_data.dig(:extended_tweet, :full_text) : @tweet_data[:text]) if tweet_message?

    ''
  end

  def message_content_attributes
    return {} unless tweet_message?

    { 'in_reply_to_external_id' => @tweet_data[:in_reply_to_status_id_str] || @tweet_data[:id_str] }
  end

  def sender_id
    return @dm_event.dig(:message_create, :sender_id) if direct_message?

    @tweet_data&.dig(:user, :id_str)
  end

  def message_source_id
    return @dm_event[:id] if direct_message?

    @tweet_data&.[](:id_str)
  end

  def message_timestamp
    return Time.zone.at(@dm_event[:created_timestamp].to_i / 1000).utc if direct_message?
    return Time.zone.parse(@tweet_data[:created_at]).utc if tweet_message?

    Time.current.utc
  end

  def direct_message?
    @dm_event.present?
  end

  def tweet_message?
    @tweet_data.present?
  end
end
