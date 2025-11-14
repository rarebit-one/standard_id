require "uri"
require "net/http"
require "json"
require "jwt"

module StandardId
  module SocialProviders
    class Apple
      ISSUER = "https://appleid.apple.com".freeze
      AUTH_ENDPOINT = "#{ISSUER}/auth/authorize".freeze
      TOKEN_ENDPOINT = "#{ISSUER}/auth/token".freeze
      JWKS_URI = "#{ISSUER}/auth/keys".freeze
      DEFAULT_SCOPE = "name email".freeze
      DEFAULT_RESPONSE_MODE = "form_post".freeze

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

        def get_user_info(code: nil, id_token: nil, redirect_uri: nil)
          if id_token.present?
            verify_id_token(id_token: id_token)
          elsif code.present?
            exchange_code_for_user_info(code: code, redirect_uri: redirect_uri)
          else
            raise StandardId::InvalidRequestError, "Either code or id_token must be provided"
          end
        end

        def exchange_code_for_user_info(code:, redirect_uri:)
          ensure_full_credentials!
          raise StandardId::InvalidRequestError, "Missing authorization code" if code.blank?

          token_response = HttpClient.post_form(TOKEN_ENDPOINT, {
            client_id: StandardId.config.apple_client_id,
            client_secret: generate_client_secret,
            code: code,
            grant_type: "authorization_code",
            redirect_uri: redirect_uri
          })

          unless token_response.is_a?(Net::HTTPSuccess)
            error_body = JSON.parse(token_response.body) rescue {}
            raise StandardId::InvalidRequestError, "Failed to exchange Apple authorization code: #{error_body['error']}"
          end

          parsed_token = JSON.parse(token_response.body)
          id_token = parsed_token["id_token"]
          raise StandardId::InvalidRequestError, "Apple response missing id_token" if id_token.blank?

          verify_id_token(id_token: id_token)
        rescue StandardError => e
          raise e if e.is_a?(StandardId::OAuthError)
          raise StandardId::OAuthError, e.message, cause: e
        end

        def verify_id_token(id_token:)
          raise StandardId::InvalidRequestError, "Missing id_token" if id_token.blank?

          decoded_token = JWT.decode(id_token, nil, false)
          payload = decoded_token[0]
          header = decoded_token[1]

          jwk = fetch_jwk(kid: header["kid"])

          token_audience = payload["aud"]
          authorized_client_ids = [StandardId.config.apple_client_id, StandardId.config.apple_mobile_client_id].compact

          unless authorized_client_ids.include?(token_audience)
            raise StandardId::InvalidRequestError, "ID token audience '#{token_audience}' not in authorized client IDs"
          end

          JWT.decode(
            id_token,
            jwk.public_key,
            true,
            algorithm: "RS256",
            iss: ISSUER,
            verify_iss: true,
            verify_aud: false # Audience already verified above
          )

          {
            "sub" => payload["sub"],
            "email" => payload["email"],
            "email_verified" => payload["email_verified"],
            "is_private_email" => payload["is_private_email"]
          }.compact
        rescue JWT::DecodeError => e
          raise StandardId::InvalidRequestError, "Invalid Apple ID token: #{e.message}"
        rescue StandardError => e
          raise e if e.is_a?(StandardId::OAuthError)
          raise StandardId::OAuthError, e.message, cause: e
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
            aud: ISSUER,
            sub: StandardId.config.apple_client_id
          }

          private_key = OpenSSL::PKey::EC.new(StandardId.config.apple_private_key)
          JWT.encode(payload, private_key, "ES256", header)
        end

        def fetch_jwk(kid:)
          uri = URI(JWKS_URI)
          jwks_response = Net::HTTP.get_response(uri)

          unless jwks_response.is_a?(Net::HTTPSuccess)
            raise StandardId::InvalidRequestError, "Failed to fetch Apple JWKS"
          end

          jwks_data = JSON.parse(jwks_response.body)
          jwk_data = jwks_data["keys"].find { |key| key["kid"] == kid }

          raise StandardId::InvalidRequestError, "JWK with kid '#{kid}' not found in Apple's JWKS" unless jwk_data

          JWT::JWK.import(jwk_data)
        rescue StandardError => e
          raise e if e.is_a?(StandardId::OAuthError)
          raise StandardId::OAuthError, "Failed to fetch JWK: #{e.message}"
        end
      end
    end
  end
end
