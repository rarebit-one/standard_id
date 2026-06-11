module StandardId
  module Api::Oauth
    module Callback
      class ProvidersController < BaseController
        public_controller

        include StandardId::SocialAuthentication

        skip_before_action :validate_content_type!

        # OAuth-flow params consumed by this controller and the SocialFlow.
        # Everything else is forwarded to SOCIAL_AUTH_COMPLETED subscribers as
        # `original_request_params` so host apps can attach attribution
        # (UTM, campaign IDs, deep-link slugs) to the signing-in account.
        RESERVED_CALLBACK_PARAMS = %w[
          id_token code scope scopes audience redirect_uri flow
          state nonce provider controller action format
          authenticity_token utf8 _method
        ].freeze

        def callback
          provider_response = fetch_provider_user_info
          social_info = provider_response[:user_info]
          provider_tokens = provider_response[:tokens]
          account = find_or_create_account_from_social(social_info)

          flow = StandardId::Oauth::SocialFlow.new(
            params,
            request,
            account:,
            connection: provider.provider_name,
            scopes: params[:scope]
          )

          token_response = flow.execute
          run_social_callback(
            provider: provider.provider_name,
            social_info:,
            provider_tokens:,
            account:,
            original_request_params: forwarded_request_params
          )
          render json: token_response, status: :ok
        end

        private

        # Mirror of the web callback's OAuthError handling: emit
        # SOCIAL_AUTH_FAILED for infrastructure-level provider failures
        # (HTTP/DNS/SSL/timeouts surfaced as OAuthError by provider
        # implementations) so host apps can observe provider outages on the
        # API flow too. Scoped to the provider call — OAuthError subclasses
        # raised later in the flow (SocialLinkError, InvalidRequestError,
        # ...) are policy/client errors, not infrastructure failures, and
        # must not emit. The error re-raises into the standard
        # handle_oauth_error JSON response.
        def fetch_provider_user_info
          get_user_info_from_provider(flow: resolve_flow_for(provider.provider_name))
        rescue StandardId::OAuthError => e
          emit_social_auth_failed(e)
          raise
        end

        def resolve_flow_for(connection)
          return :mobile unless connection == "apple"

          flow_param = params[:flow].to_s.downcase
          flow_param == "web" ? :web : :mobile
        end

        # The `except` list is the trust boundary — non-reserved values are
        # host-supplied opaque attribution data, never interpreted by the gem.
        def forwarded_request_params
          params.to_unsafe_h.stringify_keys.except(*RESERVED_CALLBACK_PARAMS)
        end
      end
    end
  end
end
