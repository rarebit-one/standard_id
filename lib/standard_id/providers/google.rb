require_relative "base"

module StandardId
  module Providers
    class Google < Base
      AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth".freeze
      TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token".freeze
      USERINFO_ENDPOINT = "https://www.googleapis.com/oauth2/v2/userinfo".freeze
      TOKEN_INFO_ENDPOINT = "https://oauth2.googleapis.com/tokeninfo".freeze
      DEFAULT_SCOPE = "openid email profile".freeze

      class << self
        def provider_name
          "google"
        end

        def authorization_url(state:, redirect_uri:, **options)
          scope = options[:scope] || DEFAULT_SCOPE
          prompt = options[:prompt]

          query = {
            client_id: credentials[:client_id],
            redirect_uri: redirect_uri,
            response_type: "code",
            scope: scope,
            state: state
          }

          query[:prompt] = prompt if prompt.present?

          "#{AUTH_ENDPOINT}?#{URI.encode_www_form(query)}"
        end

        def get_user_info(code: nil, id_token: nil, access_token: nil, redirect_uri: nil, **options)
          if id_token.present?
            build_response(
              verify_id_token(id_token: id_token),
              tokens: { id_token: id_token }
            )
          elsif access_token.present?
            build_response(
              fetch_user_info(access_token: access_token),
              tokens: { access_token: access_token }
            )
          elsif code.present?
            exchange_code_for_user_info(code: code, redirect_uri: redirect_uri)
          else
            raise StandardId::InvalidRequestError, "Either code, id_token, or access_token must be provided"
          end
        end

        def config_schema
          {
            google_client_id: { type: :string, default: nil },
            google_client_secret: { type: :string, default: nil }
          }
        end

        def default_scope
          DEFAULT_SCOPE
        end

        def exchange_code_for_user_info(code:, redirect_uri:)
          raise StandardId::InvalidRequestError, "Missing authorization code" if code.blank?

          token_response = HttpClient.post_form(TOKEN_ENDPOINT, {
            client_id: credentials[:client_id],
            client_secret: credentials[:client_secret],
            code: code,
            grant_type: "authorization_code",
            redirect_uri: redirect_uri
          }.compact)

          unless token_response.is_a?(Net::HTTPSuccess)
            raise StandardId::InvalidRequestError, "Failed to exchange Google authorization code"
          end

          parsed_token = JSON.parse(token_response.body)
          access_token = parsed_token["access_token"]
          raise StandardId::InvalidRequestError, "Google response missing access token" if access_token.blank?

          tokens = extract_token_payload(parsed_token)
          user_info = fetch_user_info(access_token: access_token)

          build_response(user_info, tokens: tokens)
        rescue StandardError => e
          raise e if e.is_a?(StandardId::OAuthError)
          raise StandardId::OAuthError, e.message, cause: e
        end

        def verify_id_token(id_token:)
          raise StandardId::InvalidRequestError, "Missing id_token" if id_token.blank?

          response = HttpClient.post_form(TOKEN_INFO_ENDPOINT, id_token: id_token)

          unless response.is_a?(Net::HTTPSuccess)
            raise StandardId::InvalidRequestError, "Invalid or expired id_token"
          end

          token_info = JSON.parse(response.body)

          unless token_info["aud"] == credentials[:client_id]
            raise StandardId::InvalidRequestError, "ID token audience mismatch. Expected: #{credentials[:client_id]}, got: #{token_info['aud']}"
          end

          unless ["accounts.google.com", "https://accounts.google.com"].include?(token_info["iss"])
            raise StandardId::InvalidRequestError, "ID token issuer invalid. Expected Google, got: #{token_info['iss']}"
          end

          {
            "sub" => token_info["sub"],
            "email" => token_info["email"],
            "email_verified" => token_info["email_verified"],
            "name" => token_info["name"],
            "given_name" => token_info["given_name"],
            "family_name" => token_info["family_name"],
            "picture" => token_info["picture"],
            "locale" => token_info["locale"]
          }.compact
        rescue StandardError => e
          raise e if e.is_a?(StandardId::OAuthError)
          raise StandardId::OAuthError, e.message, cause: e
        end

        def fetch_user_info(access_token:)
          raise StandardId::InvalidRequestError, "Missing access token" if access_token.blank?

          verify_token(access_token)
          user_response = HttpClient.get_with_bearer(USERINFO_ENDPOINT, access_token)

          unless user_response.is_a?(Net::HTTPSuccess)
            raise StandardId::InvalidRequestError, "Failed to fetch Google user info"
          end

          JSON.parse(user_response.body)
        rescue StandardError => e
          raise e if e.is_a?(StandardId::OAuthError)
          raise StandardId::OAuthError, e.message, cause: e
        end

        private

        def credentials
          @credentials ||= begin
            if StandardId.config.google_client_id.blank? || StandardId.config.google_client_secret.blank?
              raise StandardId::InvalidRequestError, "Google provider is not configured"
            end

            {
              client_id: StandardId.config.google_client_id,
              client_secret: StandardId.config.google_client_secret
            }
          end
        end

        def verify_token(access_token)
          token_info_uri = "https://www.googleapis.com/oauth2/v3/tokeninfo"

          response = HttpClient.post_form(token_info_uri, access_token: access_token)

          unless response.is_a?(Net::HTTPSuccess)
            raise StandardId::InvalidRequestError, "Invalid or expired access token"
          end

          token_info = JSON.parse(response.body)

          unless token_info["aud"] == credentials[:client_id]
            raise StandardId::InvalidRequestError, "Access token audience mismatch. Expected: #{credentials[:client_id]}, got: #{token_info['aud']}"
          end

          token_info
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

# Auto-register with the provider registry
StandardId::ProviderRegistry.register(:google, StandardId::Providers::Google)
