module X
  module OAuthHelper
    def auth_client
      ::OAuth2::Client.new(
        GlobalConfigService.load('X_CLIENT_ID', ''),
        GlobalConfigService.load('X_CLIENT_SECRET', ''),
        site: 'https://api.x.com',
        authorize_url: 'https://x.com/i/oauth2/authorize',
        token_url: '/2/oauth2/token'
      )
    end

    def generate_pkce_verifier
      # Generate random code_verifier (43-128 characters, URL-safe)
      SecureRandom.urlsafe_base64(96).tr('+/', '-_').tr('=', '')[0...128]
    end

    def generate_pkce_challenge(verifier)
      # code_challenge = BASE64URL(SHA256(code_verifier))
      Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    end

    def jwt_encode(payload)
      JWT.encode(
        payload,
        GlobalConfigService.load('X_CLIENT_SECRET', ''),
        'HS256'
      )
    end

    def jwt_decode(token)
      JWT.decode(
        token,
        GlobalConfigService.load('X_CLIENT_SECRET', ''),
        true,
        { algorithm: 'HS256' }
      )[0]
    end
  end
end
