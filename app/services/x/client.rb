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

  # Upload media for DMs and Tweets using X API v2 chunked upload (INIT -> APPEND -> FINALIZE)
  # Docs: https://docs.x.com/x-api/media/quickstart/media-upload-chunked
  def upload_media(file_data, mime_type:)
    media_id = media_upload_init(file_data, mime_type)
    media_upload_append(media_id, file_data)
    finalize_data = media_upload_finalize(media_id)
    { 'media_id_string' => finalize_data.dig('data', 'id') }
  end

  private

  def media_upload_init(file_data, mime_type)
    response = HTTParty.post(
      'https://api.x.com/2/media/upload',
      headers: { 'Authorization' => "Bearer #{bearer_token}" },
      body: { command: 'INIT', media_type: mime_type, total_bytes: file_data.bytesize, media_category: media_category_from_mime(mime_type) }
    )
    handle_response(response).dig('data', 'id')
  end

  def media_upload_append(media_id, file_data)
    HTTParty.post(
      'https://api.x.com/2/media/upload',
      headers: { 'Authorization' => "Bearer #{bearer_token}", 'Content-Type' => 'multipart/form-data' },
      multipart: true,
      body: { command: 'APPEND', media_id: media_id, segment_index: 0, media: file_data }
    )
  end

  def media_upload_finalize(media_id)
    response = HTTParty.post(
      'https://api.x.com/2/media/upload',
      headers: { 'Authorization' => "Bearer #{bearer_token}" },
      body: { command: 'FINALIZE', media_id: media_id }
    )
    handle_response(response)
  end

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
      raise X::Errors::RateLimitError, "Rate limit exceeded. Reset at: #{Time.zone.at(retry_after.to_i)}"
    else
      error_msg = response.parsed_response&.dig('errors', 0, 'message') || response.body
      raise X::Errors::APIError, "X API error (#{response.code}): #{error_msg}"
    end
  end

  def media_category_from_mime(mime_type)
    return 'dm_video' if mime_type.match?(%r{^video/})
    return 'dm_audio' if mime_type.match?(%r{^audio/})

    'dm_image'
  end
end
