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
          newly_created = account.previously_new_record?

          # Everything after find_or_create_account_from_social can still
          # reject the login: SocialFlow.new (InvalidScopeError), the grant's
          # audience/profile binding (InvalidGrantError), the login-method
          # policy, a SOCIAL_AUTH_COMPLETED subscriber, or anything unexpected.
          # Any of them leaves no link (it is only written on acceptance), no
          # new account, and no usable token or session from this request.
          token_response = nil
          begin
            token_response = StandardId::Oauth::SocialFlow.new(
              params,
              request,
              account:,
              connection: provider.provider_name,
              scopes: params[:scope]
            ).execute
            run_social_callback(
              provider: provider.provider_name,
              social_info:,
              provider_tokens:,
              account:,
              original_request_params: forwarded_request_params
            )
            commit_social_link!
          rescue StandardError
            revoke_issued_tokens!(token_response)
            discard_social_attempt!(account, newly_created: newly_created)
            raise
          end

          render json: token_response, status: :ok
        end

        private

        # Write the (provider, sub) link only once the login is accepted.
        def defer_social_link?
          true
        end

        # The response was never sent, but the grant already persisted a
        # refresh token (and possibly a session). Revoke them so nothing from
        # the rejected request stays usable. (For a new account they are
        # deleted with it by AccountCleanup.)
        def revoke_issued_tokens!(token_response)
          refresh_token = token_response.is_a?(Hash) ? token_response[:refresh_token] : nil
          return if refresh_token.blank?

          jti = StandardId::JwtService.decode(refresh_token)&.dig(:jti)
          record = jti && StandardId::RefreshToken.find_by_jti(jti)
          return unless record

          record.session&.revoke!(reason: "social_sign_in_rejected") unless record.session.nil? || record.session.revoked?
          record.revoke!
        end

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
          get_user_info_from_provider(flow: provider.flow_for(params))
        rescue StandardId::OAuthError => e
          emit_social_auth_failed(e)
          raise
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
