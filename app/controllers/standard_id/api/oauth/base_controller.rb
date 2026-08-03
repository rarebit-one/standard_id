module StandardId
  module Api
    module Oauth
      class BaseController < StandardId::Api::BaseController
        rescue_from StandardId::OAuthError, with: :handle_oauth_error

        # These two are ALREADY rescued on Api::BaseController (since 0.36.1),
        # which renders RFC 6750 §3.1 `401 invalid_token` with a
        # `WWW-Authenticate` challenge. That is the correct answer for a
        # bearer-PROTECTED RESOURCE — /api/v1/sessions, /api/v1/userinfo —
        # where the caller presented a token and must be told to discard it.
        #
        # It is the wrong answer here. Everything under Api::Oauth is an OAuth
        # PROTOCOL endpoint: at /api/oauth/token the client is *obtaining* a
        # credential, not presenting one, so there is no bearer token to
        # challenge and RFC 6749 §5.2 mandates a token-endpoint error object
        # (HTTP 400, `error`, `error_description`) instead. Re-registering the
        # pair here is what keeps the two contracts apart — Rails resolves
        # rescue_from handlers most-recently-registered-first, and a subclass
        # registers after its parent, so these win for OAuth routes only and
        # the resource-endpoint 401 is left exactly as 0.36.1 shipped it.
        rescue_from StandardId::AccountDeactivatedError, with: :handle_account_unusable
        rescue_from StandardId::AccountLockedError, with: :handle_account_unusable

        private

        def handle_oauth_error(exception)
          error_code = exception.respond_to?(:oauth_error_code) ? exception.oauth_error_code : :invalid_request
          status = exception.respond_to?(:http_status) ? exception.http_status : :bad_request
          description = exception.message.presence || "An error occurred processing the request"

          render json: {
            error: error_code.to_s,
            error_description: description
          }, status: status
        end

        # `invalid_grant` — chosen deliberately from the RFC 6749 §5.2
        # enumeration, and rendered explicitly rather than by falling through
        # `handle_oauth_error`.
        #
        # WHY invalid_grant. §5.2 defines it as the grant being "invalid,
        # expired, revoked, ... or issued to another client", which is exactly
        # what an authorization code or refresh token belonging to a disabled
        # account has become: the resource owner's authorization no longer
        # stands, and no retry of this grant will ever succeed.
        # `unauthorized_client` was the alternative and is wrong on subject —
        # it says the CLIENT is not permitted to use this grant type, a
        # property of client registration that has not changed here; the
        # client is fine, the account behind the grant is not. Mapping account
        # state onto a client-scoped code would send well-behaved clients off
        # to audit their registration.
        #
        # WHY EXPLICIT, not the respond_to? fallback. AccountDeactivatedError
        # and AccountLockedError are bare StandardErrors with no
        # `oauth_error_code` / `http_status`, so routing them through
        # `handle_oauth_error` would yield `invalid_request` / 400 by default.
        # 400 is right; `invalid_request` is not — §5.2 reserves it for a
        # MALFORMED request (missing parameter, repeated parameter), and this
        # request is perfectly well-formed. It would also leak the raw
        # exception message ("Account is deactivated" / "Account has been
        # locked") into `error_description`, which is precisely what must not
        # happen. Relying on a default that is wrong in both fields is not
        # reuse, it is a coincidence waiting to break.
        #
        # WHY THE DESCRIPTION IS GENERIC. Whoever presents a grant may not be
        # its legitimate holder — a leaked refresh token is the scenario the
        # account guard exists for — so the response must not confirm account
        # state to the presenter. Both errors therefore render the same
        # RFC-shaped sentence, and `AccountLockedError#lock_reason` (operator
        # text for logs and admin screens) is never surfaced. The specific
        # reason belongs in the host's ACCOUNT_LOCKED / ACCOUNT_DEACTIVATED
        # subscriber, server-side.
        def handle_account_unusable(_error)
          render json: {
            error: "invalid_grant",
            error_description: "The provided authorization grant is invalid, expired or revoked"
          }, status: :bad_request
        end
      end
    end
  end
end
