module StandardId
  module SocialProviders
    class Google
      AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth".freeze
      TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token".freeze
      USERINFO_ENDPOINT = "https://www.googleapis.com/oauth2/v2/userinfo".freeze
      DEFAULT_SCOPE = "openid email profile".freeze
      DEFAULT_CONNECTION = "google-oauth2".freeze

      class << self
        def authorization_url(state:, redirect_uri:, scope: DEFAULT_SCOPE, prompt: nil, connection: DEFAULT_CONNECTION)
          creds = credentials_for(connection)

          query = {
            client_id: creds[:client_id],
            redirect_uri: redirect_uri,
            response_type: "code",
            scope: scope,
            state: state
          }

          query[:prompt] = prompt if prompt.present?

          "#{AUTH_ENDPOINT}?#{URI.encode_www_form(query)}"
        end

        def get_user_info(code: nil, id_token: nil, access_token: nil, redirect_uri: nil, connection: DEFAULT_CONNECTION)
          if id_token.present?
            verify_id_token(id_token: id_token, connection: connection)
          elsif access_token.present?
            fetch_user_info(access_token: access_token, connection: connection)
          elsif code.present?
            exchange_code_for_user_info(code: code, redirect_uri: redirect_uri, connection: connection)
          else
            raise StandardId::InvalidRequestError, "Either code, id_token, or access_token must be provided"
          end
        end

        def exchange_code_for_user_info(code:, redirect_uri:, connection: DEFAULT_CONNECTION)
          creds = credentials_for(connection)
          raise StandardId::InvalidRequestError, "Missing authorization code" if code.blank?

          token_response = post_form(TOKEN_ENDPOINT, {
            client_id: creds[:client_id],
            client_secret: creds[:client_secret],
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

          fetch_user_info(access_token: access_token, connection: connection)
        rescue StandardError => e
          raise e if e.is_a?(StandardId::OAuthError)
          raise StandardId::OAuthError, e.message
        end

        def verify_id_token(id_token:, connection: DEFAULT_CONNECTION)
          raise StandardId::InvalidRequestError, "Missing id_token" if id_token.blank?

          creds = credentials_for(connection)
          token_info_uri = URI("https://oauth2.googleapis.com/tokeninfo")

          response = Net::HTTP.post_form(token_info_uri, id_token: id_token)

          unless response.is_a?(Net::HTTPSuccess)
            raise StandardId::InvalidRequestError, "Invalid or expired id_token"
          end

          token_info = JSON.parse(response.body)

          unless token_info["aud"] == creds[:client_id]
            raise StandardId::InvalidRequestError, "ID token audience mismatch. Expected: #{creds[:client_id]}, got: #{token_info['aud']}"
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
          raise StandardId::OAuthError, e.message
        end

        def fetch_user_info(access_token:, connection: DEFAULT_CONNECTION)
          raise StandardId::InvalidRequestError, "Missing access token" if access_token.blank?

          creds = credentials_for(connection)
          verify_token(access_token, creds[:client_id])

          user_response = get_with_bearer(USERINFO_ENDPOINT, access_token)

          unless user_response.is_a?(Net::HTTPSuccess)
            raise StandardId::InvalidRequestError, "Failed to fetch Google user info"
          end

          JSON.parse(user_response.body)
        rescue StandardError => e
          raise e if e.is_a?(StandardId::OAuthError)
          raise StandardId::OAuthError, e.message
        end

        def supported_connection?(connection)
          credentials_for(connection)
          true
        rescue StandardId::OAuthError
          false
        end

        private

        def credentials_for(connection)
          key = (connection.presence || DEFAULT_CONNECTION).to_s

          creds = case key
          when "google-oauth2"
                    {
                      client_id: StandardId.config.google_client_id,
                      client_secret: StandardId.config.google_client_secret
                    }
          when "google-oauth2-android"
                    {
                      client_id: StandardId.config.google_android_client_id,
                      client_secret: nil
                    }
          when "google-oauth2-ios"
                    {
                      client_id: StandardId.config.google_ios_client_id,
                      client_secret: nil
                    }
          else
                    raise StandardId::InvalidRequestError, "Unsupported Google connection: #{key}"
          end

          if creds[:client_id].blank?
            raise StandardId::InvalidRequestError, "Google connection #{key} is not configured"
          end

          if key == DEFAULT_CONNECTION && creds[:client_secret].blank?
            raise StandardId::InvalidRequestError, "Google web connection requires a client secret"
          end

          creds
        end

        def post_form(endpoint, params)
          uri = URI(endpoint)
          Net::HTTP.post_form(uri, params)
        end

        def get_with_bearer(endpoint, access_token)
          uri = URI(endpoint)
          request = Net::HTTP::Get.new(uri)
          request["Authorization"] = "Bearer #{access_token}"
          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
            http.request(request)
          end
        end

        def verify_token(access_token, expected_client_id)
          token_info_uri = URI("https://www.googleapis.com/oauth2/v3/tokeninfo")

          response = Net::HTTP.post_form(token_info_uri, access_token: access_token)

          unless response.is_a?(Net::HTTPSuccess)
            raise StandardId::InvalidRequestError, "Invalid or expired access token"
          end

          token_info = JSON.parse(response.body)

          unless token_info["aud"] == expected_client_id
            raise StandardId::InvalidRequestError, "Access token audience mismatch. Expected: #{expected_client_id}, got: #{token_info['aud']}"
          end

          token_info
        end
      end
    end
  end
end
