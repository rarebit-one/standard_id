module StandardId
  module Oauth
    module Subflows
      class SocialLoginGrant < Base
        def call
          { redirect_to: social_provider_url, status: :found }
        end

        private

        def social_provider_url
          connection = params[:connection]
          @social_provider_url ||= if StandardId::SocialProviders::Google.supported_connection?(connection)
                                     build_google_oauth_url(connection)
          elsif connection == "apple"
                                     build_apple_oauth_url
          else
                                     raise StandardId::InvalidRequestError, "Unsupported connection: #{connection}"
          end
        end

        def build_google_oauth_url(connection)
          callback_path = case connection
          when "google-oauth2-android"
                            "/api/oauth/callback/google_android"
          when "google-oauth2-ios"
                            "/api/oauth/callback/google_ios"
          else
                            "/api/oauth/callback/google"
          end

          StandardId::SocialProviders::Google.authorization_url(
            state: encode_state_with_original_params,
            redirect_uri: "#{params[:base_url]}#{callback_path}",
            connection: connection,
            scope: "openid email profile"
          )
        end

        def build_apple_oauth_url
          StandardId::SocialProviders::Apple.authorization_url(
            state: encode_state_with_original_params,
            redirect_uri: "#{params[:base_url]}/api/oauth/callback/apple"
          )
        end

        def encode_state_with_original_params
          original_params = {
            client_id: params[:client_id],
            redirect_uri: params[:redirect_uri],
            scope: params[:scope],
            audience: params[:audience],
            state: params[:state],
            code_challenge: params[:code_challenge],
            code_challenge_method: params[:code_challenge_method]
          }.compact

          # Remove code_challenge_method if code_challenge is not present
          original_params.delete(:code_challenge_method) if original_params[:code_challenge].blank?

          Base64.urlsafe_encode64(JSON.generate(original_params))
        end
      end
    end
  end
end
