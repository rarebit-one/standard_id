require "uri"
require "net/http"
require "json"
require "jwt"
require_relative "response_builder"

module StandardId
  module SocialProviders
    class Apple
      include ResponseBuilder

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

        def get_user_info(code: nil, id_token: nil, redirect_uri: nil, client_id: StandardId.config.apple_client_id)
          if id_token.present?
            build_response(
              verify_id_token(id_token: id_token, client_id: client_id),
              tokens: { id_token: id_token }
            )
          elsif code.present?
            exchange_code_for_user_info(code: code, redirect_uri: redirect_uri, client_id: client_id)
          else
            raise StandardId::InvalidRequestError, "Either code or id_token must be provided"
          end
        end

        def exchange_code_for_user_info(code:, redirect_uri:, client_id: StandardId.config.apple_client_id)
          ensure_full_credentials!(client_id: client_id)
          raise StandardId::InvalidRequestError, "Missing authorization code" if code.blank?

          token_response = HttpClient.post_form(TOKEN_ENDPOINT, {
            client_id: client_id,
            client_secret: generate_client_secret(client_id: client_id),
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

          tokens = extract_token_payload(parsed_token)
          user_info = verify_id_token(id_token: id_token, client_id: client_id)

          build_response(user_info, tokens: tokens)
        rescue StandardError => e
          raise e if e.is_a?(StandardId::OAuthError)
          raise StandardId::OAuthError, e.message, cause: e
        end

        def verify_id_token(id_token:, client_id: StandardId.config.apple_client_id)
          raise StandardId::InvalidRequestError, "Missing id_token" if id_token.blank?
          if client_id.blank?
            raise StandardId::InvalidRequestError, "Apple client_id is not configured"
          end

          decoded_token = JWT.decode(id_token, nil, false)
          header = decoded_token[1]

          jwk = fetch_jwk(kid: header["kid"])

          verified_payload, = JWT.decode(
            id_token,
            jwk.public_key,
            true,
            algorithm: "RS256",
            iss: ISSUER,
            verify_iss: true,
            aud: client_id,
            verify_aud: true
          )

          {
            "sub" => verified_payload["sub"],
            "email" => verified_payload["email"],
            "email_verified" => verified_payload["email_verified"],
            "is_private_email" => verified_payload["is_private_email"]
          }.compact
        rescue JWT::InvalidAudError => e
          raise StandardId::InvalidRequestError, "Invalid Apple ID token audience: #{e.message}"
        rescue JWT::DecodeError => e
          raise StandardId::InvalidRequestError, "Invalid Apple ID token: #{e.message}"
        rescue StandardError => e
          raise e if e.is_a?(StandardId::OAuthError)
          raise StandardId::OAuthError, e.message, cause: e
        end

        private

        def ensure_basic_credentials!(client_id: StandardId.config.apple_client_id)
          if client_id.blank?
            raise StandardId::InvalidRequestError, "Apple OAuth is not configured"
          end
        end

        def ensure_full_credentials!(client_id: nil)
          ensure_basic_credentials!(client_id: client_id)

          required = [
            StandardId.config.apple_private_key,
            StandardId.config.apple_key_id,
            StandardId.config.apple_team_id
          ]

          if required.any?(&:blank?)
            raise StandardId::InvalidRequestError, "Apple OAuth credentials are incomplete"
          end
        end

        def generate_client_secret(client_id: StandardId.config.apple_client_id)
          header = {
            alg: "ES256",
            kid: StandardId.config.apple_key_id
          }

          payload = {
            iss: StandardId.config.apple_team_id,
            iat: Time.current.to_i,
            exp: Time.current.to_i + 3600,
            aud: ISSUER,
            sub: client_id
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

        def extract_token_payload(parsed_token)
          {
            access_token: parsed_token["access_token"],
            refresh_token: parsed_token["refresh_token"],
            id_token: parsed_token["id_token"]
          }.compact
        end
      end
    end
  end
end
