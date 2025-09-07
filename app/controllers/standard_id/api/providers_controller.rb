module StandardId
  module Api
    class ProvidersController < BaseController
      skip_before_action :validate_content_type!

      def google
        expect_and_permit!([:state, :code], [:state, :code])
        handle_social_callback("google-oauth2")
      end

      def apple
        expect_and_permit!([:state, :code], [:state, :code])
        handle_social_callback("apple")
      end

      private

      def handle_social_callback(provider)
        original_params = decode_state_params
        user_info = exchange_social_code_for_user_info(provider, params[:code])
        account = find_or_create_account_from_social(user_info, provider)

        authorization_code = generate_authorization_code
        store_authorization_code(authorization_code, original_params, account, provider)

        redirect_params = {
          code: authorization_code,
          state: original_params["state"]
        }.compact

        redirect_url = build_redirect_uri(original_params["redirect_uri"], redirect_params)
        redirect_to redirect_url, allow_other_host: true, status: :found
      end

      def decode_state_params
        encoded_state = params[:state]
        raise StandardId::InvalidRequestError, "Missing state parameter" if encoded_state.blank?

        begin
          JSON.parse(Base64.urlsafe_decode64(encoded_state))
        rescue JSON::ParserError, ArgumentError
          raise StandardId::InvalidRequestError, "Invalid state parameter"
        end
      end

      def exchange_social_code_for_user_info(provider, code)
        case provider
        when "google-oauth2"
          exchange_google_code(code)
        when "apple"
          exchange_apple_code(code)
        else
          raise StandardId::InvalidRequestError, "Unsupported provider: #{provider}"
        end
      end

      def exchange_google_code(code)
        token_response = HTTParty.post("https://oauth2.googleapis.com/token", {
          body: {
            client_id: StandardId.config.google_client_id,
            client_secret: StandardId.config.google_client_secret,
            code: code,
            grant_type: "authorization_code",
            redirect_uri: "#{request.base_url}/api/oauth/callback/google"
          },
          headers: { "Content-Type" => "application/x-www-form-urlencoded" }
        })

        raise StandardId::InvalidRequestError, "Failed to exchange Google code" unless token_response.success?

        access_token = token_response.parsed_response["access_token"]

        user_response = HTTParty.get("https://www.googleapis.com/oauth2/v2/userinfo", {
          headers: { "Authorization" => "Bearer #{access_token}" }
        })

        raise StandardId::InvalidRequestError, "Failed to get Google user info" unless user_response.success?

        user_response.parsed_response
      end

      def exchange_apple_code(code)
        client_secret = generate_apple_client_secret

        token_response = HTTParty.post("https://appleid.apple.com/auth/token", {
          body: {
            client_id: StandardId.config.apple_client_id,
            client_secret: client_secret,
            code: code,
            grant_type: "authorization_code",
            redirect_uri: "#{request.base_url}/api/oauth/callback/apple"
          },
          headers: { "Content-Type" => "application/x-www-form-urlencoded" }
        })

        raise StandardId::InvalidRequestError, "Failed to exchange Apple code" unless token_response.success?

        id_token = token_response.parsed_response["id_token"]
        JWT.decode(id_token, nil, false)[0]
      end

      def generate_apple_client_secret
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

      def find_or_create_account_from_social(user_info, provider)
        email = user_info["email"]
        raise StandardId::InvalidRequestError, "No email provided by #{provider}" if email.blank?

        identifier = StandardId::EmailIdentifier.find_by(value: email)

        return identifier.account if identifier.present?

        account = Account.create!(
          name: (user_info["name"] || user_info["given_name"] || email),
          email:
        )

        identifier = StandardId::EmailIdentifier.create!(
          account:,
          value: email
        )

        identifier.verify!

        account
      end

      def generate_authorization_code
        SecureRandom.urlsafe_base64(32)
      end

      def store_authorization_code(code, original_params, account, provider)
        StandardId::AuthorizationCode.issue!(
          plaintext_code: code,
          client_id: original_params["client_id"],
          redirect_uri: original_params["redirect_uri"],
          scope: original_params["scope"],
          audience: original_params["audience"],
          account: account,
          code_challenge: original_params["code_challenge"],
          code_challenge_method: original_params["code_challenge_method"],
          metadata: { state: original_params["state"], provider: provider }.compact
        )
      end

      def build_redirect_uri(base_uri, params_hash)
        uri = URI.parse(base_uri)
        query_params = URI.decode_www_form(uri.query || "")

        params_hash.each do |key, value|
          query_params << [key.to_s, value.to_s] if value.present?
        end

        uri.query = URI.encode_www_form(query_params)
        uri.to_s
      end
    end
  end
end
