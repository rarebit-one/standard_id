module StandardId
  module Web
    module Auth
      module Callback
        class ProvidersController < StandardId::Web::BaseController
          include StandardId::WebAuthentication

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

          def handle_social_callback(provider)
            # This handles the callback from social providers in web context
            # After successful social auth, we need to:
            # 1. Extract user info from the callback
            # 2. Create/find account
            # 3. Sign in the user with web session
            # 4. Redirect to original destination

            if params[:error].present?
              handle_callback_error
              return
            end

            begin
              user_info = extract_user_info(provider)
              account = find_or_create_account_from_social(user_info, provider)
              session_manager.sign_in_account(account)

              redirect_to decode_redirect_uri, notice: "Successfully signed in with #{provider.humanize}"
            rescue StandardId::OAuthError => e
              redirect_to login_path, alert: "Authentication failed: #{e.message}"
            end
          end

          def extract_user_info(provider)
            case provider
            when "google-oauth2"
              extract_google_user_info
            when "apple"
              extract_apple_user_info
            else
              raise StandardId::InvalidRequestError, "Unsupported connection/provider: #{provider}"
            end
          end

          def extract_google_user_info
            # Exchange code for Google user info
            # This would integrate with Google OAuth API
            {
              email: params[:email] || "user@example.com", # Placeholder
              name: params[:name] || "Google User",
              provider: "google-oauth2",
              provider_id: params[:sub] || "google_123"
            }
          end

          def extract_apple_user_info
            # Extract user info from Apple Sign In callback
            # This would decode the Apple ID token
            {
              email: params[:email] || "user@privaterelay.appleid.com", # Placeholder
              name: params[:name] || "Apple User",
              provider: "apple",
              provider_id: params[:sub] || "apple_123"
            }
          end

          def find_or_create_account_from_social(user_info, provider)
            # Find existing account by email or create new one
            identifier = StandardId::EmailIdentifier.find_by(value: user_info[:email])

            if identifier
              identifier.account
            else
              # Create new account with social login
              account = ::Account.create!(
                email: user_info[:email],
                name: user_info[:name].presence || "User"
              )
              StandardId::EmailIdentifier.create!(
                account: account,
                value: user_info[:email]
              )
              account
            end
          end

          def decode_redirect_uri
            return "/" unless params[:state].present?

            begin
              state_data = JSON.parse(Base64.urlsafe_decode64(params[:state]))
              state_data["redirect_uri"] || "/"
            rescue JSON::ParserError, ArgumentError
              "/"
            end
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
