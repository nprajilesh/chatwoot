module X
  module OAuthHelper
    def auth_client
      ::OAuth2::Client.new(
        GlobalConfigService.load('X_CLIENT_ID'),
        GlobalConfigService.load('X_CLIENT_SECRET'),
        site: 'https://api.x.com',
        authorize_url: '/i/oauth2/authorize',
        token_url: '/2/oauth2/token'
      )
    end

    def jwt_encode(payload)
      JWT.encode(
        payload,
        GlobalConfigService.load('X_CLIENT_SECRET'),
        'HS256'
      )
    end

    def jwt_decode(token)
      JWT.decode(
        token,
        GlobalConfigService.load('X_CLIENT_SECRET'),
        true,
        { algorithm: 'HS256' }
      )[0]
    end
  end
end
