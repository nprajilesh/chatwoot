class X::CallbacksController < ApplicationController
  include X::OAuthHelper

  def show
    # Validate JWT state and extract account_id and code_verifier
    decoded_state = jwt_decode(params[:state])
    account = Account.find(decoded_state['sub'])
    code_verifier = decoded_state['code_verifier']

    # Exchange code for tokens using OAuth2 gem with PKCE
    client = auth_client
    token = client.auth_code.get_token(
      params[:code],
      redirect_uri: "#{ENV.fetch('FRONTEND_URL', nil)}/x/callback",
      code_verifier: code_verifier
    )

    # Fetch user profile
    user_data = fetch_user_profile(token.token)

    # Create or update channel
    x_channel = create_or_update_channel(
      account: account,
      user_data: user_data,
      access_token: token.token,
      refresh_token: token.refresh_token,
      expires_in: token.expires_in
    )

    # Reload to ensure inbox association is loaded
    x_channel.reload

    redirect_to "#{ENV.fetch('FRONTEND_URL', nil)}/app/accounts/#{account.id}/settings/inboxes/#{x_channel.inbox.id}"
  rescue JWT::DecodeError => e
    Rails.logger.error("X OAuth state decode error: #{e.message}")
    redirect_to error_url('Invalid state parameter')
  rescue StandardError => e
    Rails.logger.error("X OAuth callback error: #{e.message}")
    redirect_to error_url(e.message)
  end

  private

  def fetch_user_profile(access_token)
    # Use X API /2/users/me endpoint
    response = HTTParty.get(
      'https://api.x.com/2/users/me',
      headers: {
        'Authorization' => "Bearer #{access_token}",
        'Content-Type' => 'application/json'
      },
      query: { 'user.fields' => 'profile_image_url,name,username' }
    )

    response.parsed_response['data']
  end

  def create_or_update_channel(account:, user_data:, access_token:, refresh_token:, expires_in:)
    x_channel = Channel::X.find_or_initialize_by(
      profile_id: user_data['id']
    )

    x_channel.update!(
      account: account,
      username: user_data['username'],
      name: user_data['name'],
      profile_image_url: user_data['profile_image_url'],
      bearer_token: access_token,
      refresh_token: refresh_token,
      token_expires_at: Time.current + expires_in.seconds,
      refresh_token_expires_at: 6.months.from_now, # X default
      authorization_error_count: 0
    )

    # Create inbox if new
    unless x_channel.inbox
      account.inboxes.create!(
        name: "X (@#{user_data['username']})",
        channel: x_channel
      )
    end

    x_channel
  end

  def error_url(message)
    "#{ENV.fetch('FRONTEND_URL', nil)}/app?error=#{CGI.escape(message)}"
  end
end
