module StandardId
  module Web
    module Auth
      module Callback
        class ProvidersController < StandardId::Web::BaseController
          include StandardId::WebAuthentication
          include StandardId::SocialAuthentication

          # Social callbacks must be accessible without an existing browser session
          # because they create/sign-in the session upon successful callback.
          skip_before_action :require_browser_session!, only: [:google, :apple]

          def google
            handle_social_callback("google-oauth2")
          end

          def apple
            handle_social_callback("apple")
          end

          private

          def handle_social_callback(connection)
            if params[:error].present?
              handle_callback_error
              return
            end

            state_data = nil

            begin
              state_data = decode_state_params
              redirect_uri = connection == "apple" ? apple_callback_url : google_callback_url
              user_info = get_user_info_from_provider(connection, redirect_uri: redirect_uri)
              account = find_or_create_account_from_social(user_info, connection)
              session_manager.sign_in_account(account)

              redirect_to state_data["redirect_uri"], notice: "Successfully signed in with #{connection.humanize}"
            rescue StandardId::OAuthError => e
              redirect_to login_path(redirect_uri: state_data&.dig("redirect_uri")), alert: "Authentication failed: #{e.message}"
            end
          end

          def google_callback_url
            auth_callback_google_url
          end

          def apple_callback_url
            auth_callback_apple_url
          end

          def decode_state_params
            encoded_state = params[:state]
            raise StandardId::InvalidRequestError, "Missing state parameter" if encoded_state.blank?

            state = JSON.parse(Base64.urlsafe_decode64(encoded_state))
            state["redirect_uri"] ||= after_authentication_url
            state
          rescue JSON::ParserError, ArgumentError
            raise StandardId::InvalidRequestError, "Invalid state parameter"
          end

          def handle_callback_error
            error_message = case params[:error]
            when "access_denied"
                            "Authentication was cancelled"
            when "invalid_request"
                            "Invalid authentication request"
            else
                            "Authentication failed"
            end

            redirect_to login_path, alert: error_message
          end
        end
      end
    end
  end
end
