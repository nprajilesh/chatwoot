# Processes X webhook events for direct messages and mentions
# https://developer.x.com/en/docs/x-api/webhooks/introduction
class Webhooks::XEventsJob < MutexApplicationJob
  queue_as :default
  retry_on LockAcquisitionError, wait: 2.seconds, attempts: 8

  def perform(event)
    @event = event.with_indifferent_access

    return if channel_is_inactive?

    process_event
  end

  private

  def channel_is_inactive?
    return true if channel.blank?
    return true unless channel.account.active?

    false
  end

  def process_event
    # X webhooks can contain multiple event types
    process_direct_messages if @event[:direct_message_events].present?
    process_tweets if @event[:tweet_create_events].present?
  end

  def process_direct_messages
    @event[:direct_message_events].each do |dm_event|
      next unless dm_event[:message_create].present?

      sender_id = dm_event.dig(:message_create, :sender_id)
      recipient_id = dm_event.dig(:message_create, :target, :recipient_id)

      key = format(::Redis::Alfred::X_MESSAGE_MUTEX, sender_id: sender_id, recipient_id: recipient_id)
      with_lock(key, 10.seconds) do
        X::IncomingMessageService.new(
          channel: channel,
          dm_event: dm_event
        ).perform
      end
    end
  end

  def process_tweets
    @event[:tweet_create_events].each do |tweet_event|
      # Only process mentions directed at the channel's profile
      next unless tweet_event[:in_reply_to_user_id] == channel.profile_id

      tweet_event[:id_str]
      sender_id = tweet_event[:user][:id_str]

      key = format(::Redis::Alfred::X_MESSAGE_MUTEX, sender_id: sender_id, recipient_id: channel.profile_id)
      with_lock(key, 10.seconds) do
        X::IncomingMessageService.new(
          channel: channel,
          tweet_data: tweet_event
        ).perform
      end
    end
  end

  def channel
    # X webhooks include the user_id (profile_id) in the for_user_id field
    @channel ||= Channel::X.find_by(profile_id: @event[:for_user_id])
  end
end
