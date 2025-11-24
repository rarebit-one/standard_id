module StandardId
  module Web
    module Auth
      module Callback
        class ProvidersController < StandardId::Web::BaseController
          include StandardId::WebAuthentication
          include StandardId::SocialAuthentication

          # Social callbacks must be accessible without an existing browser session
          # because they create/sign-in the session upon successful callback.
          skip_before_action :require_browser_session!, only: [:google, :apple, :apple_mobile]
          skip_before_action :verify_authenticity_token, only: [:apple, :apple_mobile]

          def google
            handle_social_callback("google")
          end

          def apple
            handle_social_callback("apple")
          end

          def apple_mobile
            state_data = decode_state_params
            destination = state_data["redirect_uri"]

            unless allow_other_host_redirect?(destination)
              raise StandardId::InvalidRequestError, "Redirect URI is not allowed"
            end

            relay_params = mobile_relay_params
            @mobile_redirect_url = build_mobile_redirect(destination, relay_params)
            render :apple_mobile, layout: false
          rescue StandardId::InvalidRequestError => e
            render plain: e.message, status: :unprocessable_entity
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
              provider_response = get_user_info_from_provider(connection, redirect_uri: redirect_uri)
              social_info = provider_response[:user_info]
              provider_tokens = provider_response[:tokens]
              account = find_or_create_account_from_social(social_info, connection)
              session_manager.sign_in_account(account)

              run_social_callback(
                provider: connection,
                social_info: social_info,
                provider_tokens: provider_tokens,
                account: account,
              )

              destination = state_data["redirect_uri"]
              redirect_options = { notice: "Successfully signed in with #{connection.humanize}" }
              redirect_options[:allow_other_host] = true if allow_other_host_redirect?(destination)
              redirect_to destination, redirect_options
            rescue StandardId::OAuthError => e
              redirect_to StandardId::WebEngine.routes.url_helpers.login_path(redirect_uri: state_data&.dig("redirect_uri")), alert: "Authentication failed: #{e.message}"
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

            redirect_to StandardId::WebEngine.routes.url_helpers.login_path, alert: error_message
          end

          def mobile_relay_params
            params.permit(:code, :state, :user, :userIdentifier, :id_token, :identity_token, :nonce).to_h.compact
          end

          def build_mobile_redirect(destination, extra_params)
            uri = URI.parse(destination)
            existing = Rack::Utils.parse_nested_query(uri.query)
            merged = existing.merge(extra_params)
            uri.query = merged.to_query.presence
            uri.to_s
          rescue URI::InvalidURIError
            destination
          end
        end
      end
    end
  end
end
