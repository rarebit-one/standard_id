require "uri"
require "net/http"
require "json"
require "jwt"

module StandardId
  module SocialProviders
    class Apple
      AUTH_ENDPOINT = "https://appleid.apple.com/auth/authorize".freeze unless const_defined?(:AUTH_ENDPOINT)
      TOKEN_ENDPOINT = "https://appleid.apple.com/auth/token".freeze unless const_defined?(:TOKEN_ENDPOINT)
      DEFAULT_SCOPE = "name email".freeze unless const_defined?(:DEFAULT_SCOPE)
      DEFAULT_RESPONSE_MODE = "form_post".freeze unless const_defined?(:DEFAULT_RESPONSE_MODE)

      class << self
        def authorization_url(state:, redirect_uri:, scope: DEFAULT_SCOPE, response_mode: DEFAULT_RESPONSE_MODE)
          ensure_basic_credentials!

          query = {
            client_id: StandardId.config.apple_client_id,
            redirect_uri: redirect_uri,
            response_type: "code",
            scope: scope,
            response_mode: response_mode,
            state: state
          }

          "#{AUTH_ENDPOINT}?#{URI.encode_www_form(query)}"
        end

        def exchange_code_for_user_info(code:, redirect_uri:)
          ensure_full_credentials!
          raise StandardId::InvalidRequestError, "Missing authorization code" if code.blank?

          token_response = post_form(TOKEN_ENDPOINT, {
            client_id: StandardId.config.apple_client_id,
            client_secret: generate_client_secret,
            code: code,
            grant_type: "authorization_code",
            redirect_uri: redirect_uri
          })

          unless token_response.is_a?(Net::HTTPSuccess)
            raise StandardId::InvalidRequestError, "Failed to exchange Apple authorization code"
          end

          parsed_token = JSON.parse(token_response.body)
          id_token = parsed_token["id_token"]
          raise StandardId::InvalidRequestError, "Apple response missing id_token" if id_token.blank?

          JWT.decode(id_token, nil, false)[0]
        rescue StandardError => e
          raise e if e.is_a?(StandardId::OAuthError)
          raise StandardId::OAuthError, e.message
        end

        private

        def ensure_basic_credentials!
          if StandardId.config.apple_client_id.blank?
            raise StandardId::InvalidRequestError, "Apple OAuth is not configured"
          end
        end

        def ensure_full_credentials!
          ensure_basic_credentials!

          required = [
            StandardId.config.apple_private_key,
            StandardId.config.apple_key_id,
            StandardId.config.apple_team_id
          ]

          if required.any?(&:blank?)
            raise StandardId::InvalidRequestError, "Apple OAuth credentials are incomplete"
          end
        end

        def generate_client_secret
          header = {
            alg: "ES256",
            kid: StandardId.config.apple_key_id
          }

          payload = {
            iss: StandardId.config.apple_team_id,
            iat: Time.current.to_i,
            exp: Time.current.to_i + 3600,
            aud: "https://appleid.apple.com",
            sub: StandardId.config.apple_client_id
          }

          private_key = OpenSSL::PKey::EC.new(StandardId.config.apple_private_key)
          JWT.encode(payload, private_key, "ES256", header)
        end

        def post_form(endpoint, params)
          uri = URI(endpoint)
          request = Net::HTTP::Post.new(uri)
          request["Content-Type"] = "application/x-www-form-urlencoded"
          request.set_form_data(params)
          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
            http.request(request)
          end
        end
      end
    end
  end
end
