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
          flow = nil
          begin
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
            commit_social_link!
          rescue StandardError
            removed = social_account_removed_concurrently?(account, newly_created:)
            revoke_issued_tokens!(flow)
            discard_social_attempt!(account, newly_created: newly_created)
            raise unless removed

            # The matched account was removed under this login by a
            # concurrent, refused request: retryable, not a 500.
            raise StandardId::InvalidGrantError, SOCIAL_RETRY_MESSAGE
          end

          render json: token_response, status: :ok
        end

        private

        # Write the (provider, sub) link only once the login is accepted.
        def defer_social_link?
          true
        end

        # The response was never sent, but the grant may already have
        # persisted a refresh token and a session — also when the grant itself
        # raised after writing them (e.g. an OAUTH_TOKEN_ISSUED subscriber), so
        # they are read from the flow, not from a token response. Revoke them
        # so nothing from the rejected request stays usable, and so that
        # AccountCleanup does not mistake them for a concurrent login using a
        # new account. A token whose transaction rolled back is not persisted
        # and is skipped (its session write was rolled back with it).
        def revoke_issued_tokens!(flow)
          record = flow&.issued_refresh_token
          return unless record&.persisted?

          session = record.session
          session.revoke!(reason: "social_sign_in_rejected") unless session.nil? || session.revoked?
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
