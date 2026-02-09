class Api::V1::Accounts::X::AuthorizationsController < Api::V1::Accounts::BaseController
  include X::OAuthHelper

  REQUIRED_SCOPES = %w[dm.read dm.write tweet.read tweet.write users.read offline.access].freeze

  def create
    # Generate JWT-encoded state with account ID (TikTok pattern)
    state = jwt_encode({ sub: Current.account.id, iat: Time.current.to_i })

    # Get OAuth2 authorization URL with PKCE
    client = auth_client
    url = client.auth_code.authorize_url(
      redirect_uri: "#{ENV.fetch('FRONTEND_URL', nil)}/x/callback",
      scope: REQUIRED_SCOPES.join(' '),
      state: state,
      code_challenge_method: 'S256' # OAuth2 gem handles PKCE automatically
    )

    render json: { authorization_url: url }
  end
end
