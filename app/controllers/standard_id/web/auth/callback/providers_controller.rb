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
              extract_state_and_nonce => { state_data:, nonce:, code_verifier: }
              code_verifier = pkce_verifier_for_provider!(code_verifier)
              caller_redirect_uri = state_data&.dig("redirect_uri").presence
              redirect_uri = callback_url_for
              provider_response = get_user_info_from_provider(redirect_uri:, nonce:, code_verifier:)
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
              session_manager.sign_in_account(
                account,
                scope_name: state_data&.dig("scope"),
                auth_method: :social,
                provider: provider.provider_name,
                flow: :web_social
              )

              provider_name = provider.provider_name
              invoke_after_account_created(account, { mechanism: "social", provider: provider_name }) if newly_created

              run_social_callback(
                provider: provider_name,
                social_info: social_info,
                provider_tokens: provider_tokens,
                account: account,
                original_request_params: state_data
              )

              context = {
                mechanism: "social",
                provider: provider_name,
                redirect_uri: caller_redirect_uri
              }
              redirect_override = invoke_after_sign_in(account, context)

              # When the hook defers (returns nil), the originator-supplied URL becomes the
              # destination. Validate it before redirect_to — without this, an attacker who
              # tricks a victim into clicking /login?connection=google&redirect_uri=<evil>
              # can steer the post-auth landing page. redirect_override is host-internal so
              # we trust it; only the fallthrough needs validation.
              destination = redirect_override || (safe_destination?(caller_redirect_uri) ? caller_redirect_uri : safe_post_signin_default)
              redirect_options = { notice: "Successfully signed in with #{provider_name.humanize}" }
              redirect_options[:allow_other_host] = true if allow_other_host_redirect?(destination)

              # Accepted: only now write the (provider, sub) link, in the same
              # transaction as the redirect, which can still raise (e.g. an
              # after_sign_in URL on a host that is not allowed). If it does,
              # the link is rolled back with it.
              commit_social_link! { redirect_to destination, redirect_options }
            rescue StandardId::AuthenticationDenied => e
              rollback_social_link!
              handle_authentication_denied(e, account: account, newly_created: newly_created)
            rescue StandardId::SocialLinkError => e
              # Policy/link error — SOCIAL_LINK_BLOCKED has already been emitted
              # by validate_social_link!, so do not also emit SOCIAL_AUTH_FAILED
              # (which is reserved for infrastructure-level failures).
              redirect_to StandardId::WebEngine.routes.url_helpers.login_path(redirect_uri: state_data&.dig("redirect_uri")), alert: "Authentication failed: #{e.message}"
            rescue StandardId::OAuthError => e
              discard_rejected_social_sign_in!(account, newly_created:)
              # A (provider, sub) conflict with a concurrent login is a link
              # refusal (SOCIAL_LINK_BLOCKED, already published), not an
              # infrastructure failure.
              emit_social_auth_failed(e, account: account) unless e.is_a?(StandardId::SocialLinkConflictError)
              redirect_to StandardId::WebEngine.routes.url_helpers.login_path(redirect_uri: state_data&.dig("redirect_uri")), alert: "Authentication failed: #{e.message}"
            rescue StandardError => e
              # Unexpected failure after the link/account may have been
              # written: undo them, then let the error surface as before —
              # unless the matched account was removed under this login by a
              # concurrent, refused request, which is retryable.
              removed = social_account_removed_concurrently?(account, newly_created:)
              discard_rejected_social_sign_in!(account, newly_created:)
              raise unless removed

              emit_social_auth_failed(e, account: account)
              redirect_to StandardId::WebEngine.routes.url_helpers.login_path(redirect_uri: state_data&.dig("redirect_uri")), alert: "Authentication failed: #{SOCIAL_RETRY_MESSAGE}"
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

          # A rejection after find_or_create_account_from_social leaves no
          # link, no new account and no session — including one that
          # sign_in_account created before raising (a failing SESSION_CREATED
          # subscriber), which is why this reads session_manager.created_session
          # rather than relying on sign_in_account having returned.
          # AuthenticationDenied has its own path (handle_authentication_denied);
          # SocialLinkError is raised before anything is written.
          def discard_rejected_social_sign_in!(account, newly_created:)
            created = session_manager.created_session
            if created
              created.revoke!(reason: "social_sign_in_rejected") unless created.revoked?
              session_manager.clear_session!
            end
            discard_social_attempt!(account, newly_created: newly_created, sessions: [created])
          end

          # Write the (provider, sub) link only once the login is accepted.
          def defer_social_link?
            true
          end

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
              nonce: oauth_state["nonce"],
              code_verifier: oauth_state["code_verifier"].presence
            }
          end

          # Core-managed PKCE (Providers::Base.supports_pkce?): the provider
          # receives the verifier stored with this flow's state, and only
          # then. A PKCE provider's flow must have been started with one (by
          # /login for this provider), so a missing verifier — a state issued
          # for another provider, or stored before the provider opted in — is
          # refused rather than the code exchanged without it.
          def pkce_verifier_for_provider!(code_verifier)
            return nil unless provider.supports_pkce?
            raise StandardId::InvalidRequestError, "Missing PKCE verifier for this sign-in" if code_verifier.nil?

            code_verifier
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

            # Preserve redirect_uri across the bounce-back-to-/login so the user can retry
            # the OAuth handshake and complete it back to the originator. Symmetric with
            # the SocialLinkError / OAuthError rescue paths above.
            redirect_uri = begin
              extract_state_and_nonce => { state_data: }
              state_data&.dig("redirect_uri").presence
            rescue StandardId::InvalidRequestError
              nil
            end

            redirect_to StandardId::WebEngine.routes.url_helpers.login_path(redirect_uri: redirect_uri), alert: error_message
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
