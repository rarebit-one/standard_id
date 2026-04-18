module StandardId
  module Web
    module Auth
      module Callback
        class ProvidersController < StandardId::Web::BaseController
          public_controller
          requires_web_mechanism :social_login

          include StandardId::WebAuthentication
          include StandardId::SocialAuthentication
          include StandardId::Web::SocialLoginParams
          include StandardId::LifecycleHooks

          # Social callbacks must be accessible without an existing browser session
          # because they create/sign-in the session upon successful callback.
          skip_before_action :require_browser_session!, only: [:callback, :mobile_callback]
          skip_before_action :verify_authenticity_token, only: [:callback, :mobile_callback], if: :skip_csrf_verification?

          def callback
            if params[:error].present?
              handle_callback_error
              return
            end

            state_data = nil

            begin
              extract_state_and_nonce => { state_data:, nonce: }
              redirect_uri = callback_url_for
              provider_response = get_user_info_from_provider(redirect_uri:, nonce:)
              social_info = provider_response[:user_info]
              provider_tokens = provider_response[:tokens]
              begin
                account = find_or_create_account_from_social(social_info)
              rescue ActiveRecord::RecordNotUnique
                # Race condition: concurrent request created the account first — retry to find it
                account = find_or_create_account_from_social(social_info)
              end
              newly_created = account.previously_new_record?

              invoke_before_sign_in(account, { mechanism: "social", provider: provider.provider_name })
              session_manager.sign_in_account(account, scope_name: state_data&.dig("scope"))

              provider_name = provider.provider_name
              invoke_after_account_created(account, { mechanism: "social", provider: provider_name }) if newly_created

              run_social_callback(
                provider: provider_name,
                social_info: social_info,
                provider_tokens: provider_tokens,
                account: account,
                original_request_params: state_data
              )

              context = { mechanism: "social", provider: provider_name }
              redirect_override = invoke_after_sign_in(account, context)

              destination = redirect_override || state_data["redirect_uri"]
              redirect_options = { notice: "Successfully signed in with #{provider_name.humanize}" }
              redirect_options[:allow_other_host] = true if allow_other_host_redirect?(destination)
              redirect_to destination, redirect_options
            rescue StandardId::AuthenticationDenied => e
              handle_authentication_denied(e, account: account, newly_created: newly_created)
            rescue StandardId::SocialLinkError => e
              # Policy/link error — SOCIAL_LINK_BLOCKED has already been emitted
              # by validate_social_link!, so do not also emit SOCIAL_AUTH_FAILED
              # (which is reserved for infrastructure-level failures).
              redirect_to StandardId::WebEngine.routes.url_helpers.login_path(redirect_uri: state_data&.dig("redirect_uri")), alert: "Authentication failed: #{e.message}"
            rescue StandardId::OAuthError => e
              emit_social_auth_failed(e, account: account)
              redirect_to StandardId::WebEngine.routes.url_helpers.login_path(redirect_uri: state_data&.dig("redirect_uri")), alert: "Authentication failed: #{e.message}"
            end
          end

          def mobile_callback
            unless provider.supports_mobile_callback?
              raise StandardId::InvalidRequestError, "Provider #{provider.provider_name} does not support mobile callback"
            end

            extract_state_and_nonce => { state_data: }
            destination = state_data["redirect_uri"]

            unless allow_other_host_redirect?(destination)
              raise StandardId::InvalidRequestError, "Redirect URI is not allowed"
            end

            relay_params = mobile_relay_params
            @mobile_redirect_url = build_mobile_redirect(destination, relay_params)
            render :mobile_callback, layout: false
          rescue StandardId::InvalidRequestError => e
            render plain: e.message, status: :unprocessable_entity
          end

          private

          def callback_url_for
            "#{request.base_url}#{provider.callback_path}"
          end

          def skip_csrf_verification?
            provider.skip_csrf?
          end

          def extract_state_and_nonce
            state_token = params[:state]
            raise StandardId::InvalidRequestError, "Missing state parameter" if state_token.blank?

            oauth_state = consume_oauth_request(state_token)
            raise StandardId::InvalidRequestError, "Invalid or expired state parameter" if oauth_state.nil?

            {
              state_data: oauth_state["params"],
              nonce: oauth_state["nonce"]
            }
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
