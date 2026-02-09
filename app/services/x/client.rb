class X::Client
  include HTTParty
  base_uri 'https://api.x.com/2'

  attr_reader :bearer_token

  def initialize(bearer_token:)
    @bearer_token = bearer_token
  end

  # Send Direct Message (VALIDATED ENDPOINT)
  # POST /2/dm_conversations/with/:participant_id/messages
  # Docs: https://developer.x.com/en/docs/x-api/direct-messages/manage/api-reference/post-dm_conversations-with-participant_id-messages
  def send_direct_message(participant_id:, text:, attachments: nil)
    body = { text: text }
    body[:attachments] = attachments if attachments

    post("/dm_conversations/with/#{participant_id}/messages", body: body)
  end

  # Create Tweet (VALIDATED ENDPOINT)
  # POST /2/tweets
  # Docs: https://developer.x.com/en/docs/x-api/tweets/manage-tweets/api-reference/post-tweets
  def create_tweet(text:, reply_settings: nil, reply_to_tweet_id: nil)
    body = { text: text }
    body[:reply_settings] = reply_settings if reply_settings
    body[:reply] = { in_reply_to_tweet_id: reply_to_tweet_id } if reply_to_tweet_id

    post('/tweets', body: body)
  end

  # Get user by ID (VALIDATED ENDPOINT)
  # GET /2/users/:id
  def user(user_id)
    get("/users/#{user_id}", query: { 'user.fields' => 'profile_image_url,name,username' })
  end

  # Get authenticated user (VALIDATED ENDPOINT)
  # GET /2/users/me
  def me
    get('/users/me', query: { 'user.fields' => 'profile_image_url,name,username' })
  end

  # Upload media for DMs and Tweets
  # NOTE: X API v2 uses the v1.1 media upload endpoint by design.
  # Upload media first to get media_id, then attach it to v2 DM/tweet requests.
  # Docs: https://developer.x.com/en/docs/twitter-api/v1/media/upload-media/overview
  def upload_media(file_data, mime_type:)
    response = HTTParty.post(
      'https://upload.twitter.com/1.1/media/upload.json',
      headers: { 'Authorization' => "Bearer #{bearer_token}" },
      body: {
        media_data: Base64.strict_encode64(file_data),
        media_category: media_category_from_mime(mime_type)
      }
    )

    handle_response(response)
  end

  private

  def post(path, body:)
    response = self.class.post(
      path,
      headers: auth_headers,
      body: body.to_json
    )

    handle_response(response)
  end

  def get(path, query: {})
    response = self.class.get(
      path,
      headers: auth_headers,
      query: query
    )

    handle_response(response)
  end

  def auth_headers
    {
      'Authorization' => "Bearer #{bearer_token}",
      'Content-Type' => 'application/json'
    }
  end

  def handle_response(response)
    case response.code
    when 200..201
      response.parsed_response
    when 401
      raise X::Errors::UnauthorizedError, 'Token expired or invalid'
    when 429
      # X API v2 rate limit headers
      retry_after = response.headers['x-rate-limit-reset']
      raise X::Errors::RateLimitError, "Rate limit exceeded. Reset at: #{Time.at(retry_after.to_i)}"
    else
      error_msg = response.parsed_response&.dig('errors', 0, 'message') || response.body
      raise X::Errors::APIError, "X API error (#{response.code}): #{error_msg}"
    end
  end

  def media_category_from_mime(mime_type)
    case mime_type
    when %r{^image/} then 'dm_image'
    when %r{^video/} then 'dm_video'
    when %r{^audio/} then 'dm_audio'
    else 'dm_image'
    end
  end
end

# Custom error classes
module X
  module Errors
    class APIError < StandardError; end
    class UnauthorizedError < APIError; end
    class RateLimitError < APIError; end
  end
end
