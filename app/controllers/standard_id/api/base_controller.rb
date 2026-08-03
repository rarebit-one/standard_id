module StandardId
  module Api
    class BaseController < ActionController::API
      include ActionController::RateLimiting
      include StandardId::ControllerPolicy
      include StandardId::ApiAuthentication
      include StandardId::SetCurrentRequestDetails
      include StandardId::RateLimitHandling

      before_action -> { Current.scope = :api if defined?(::Current) }
      before_action :validate_content_type!

      after_action :set_no_store_headers

      rescue_from StandardId::NotAuthenticatedError, with: :handle_not_authenticated
      rescue_from StandardId::InvalidSessionError, with: :handle_invalid_session
      rescue_from StandardId::OAuthError, with: :handle_oauth_error

      # AccountStatus / AccountLocking raise these from the SESSION_VALIDATING
      # subscriber, i.e. mid-request on an ALREADY authenticated call, not just
      # at sign-in or token mint. Unrescued they are a 500 on every gem-owned
      # API route. Unlike Web::BaseController — which descends from the host's
      # ApplicationController, so a host `rescue_from` covers it — this class
      # descends from ActionController::API, so the host has nowhere to put a
      # handler in the ancestry and the gem must answer for itself.
      rescue_from StandardId::AccountDeactivatedError, with: :handle_account_deactivated
      rescue_from StandardId::AccountLockedError, with: :handle_account_locked

      protected

      def validate_content_type!
        return if request.media_type&.match?(%r{\Aapplication\/(.+\+)?json\z})
        raise StandardId::InvalidRequestError, "Content-Type must be application/json or application/*+json"
      end

      def set_no_store_headers
        response.headers["Cache-Control"] = "no-store"
        response.headers["Pragma"] = "no-cache"
      end

      def expect_and_permit!(expected_keys, permitted_keys)
        params.expect(expected_keys)
        params.permit(*permitted_keys)
      rescue ActionController::ParameterMissing => e
        raise StandardId::InvalidRequestError, "The #{e.param} parameter is required"
      end

      def handle_not_authenticated(error)
        render_bearer_unauthorized!(error_description: error.message.presence || default_invalid_token_message)
      end

      def handle_invalid_session(error)
        render_bearer_unauthorized!(error_description: default_invalid_token_message)
      end

      # RFC 6750 §3.1 offers exactly three error codes, and `invalid_token` is
      # the right one: it covers a token "expired, revoked, malformed, or
      # invalid for other reasons", and a bearer token whose subject account has
      # been disabled is invalid for one of those other reasons. It also carries
      # the correct client instruction — discard the token and re-authenticate —
      # which is what we want, since no retry with this token will ever succeed.
      # `insufficient_scope` (403) would be wrong: nothing here is about scope,
      # and a 403 invites the client to keep the token and retry. `invalid_request`
      # (400) would be wrong: the request is well-formed.
      def handle_account_deactivated(_error)
        render_bearer_unauthorized!(error_description: "The account is deactivated")
      end

      # Deliberately does NOT surface `error.lock_reason`. It is operator-authored
      # text intended for logs and admin screens (see StandardId::AccountLockedError),
      # and the WWW-Authenticate header this renders into is a quoted string that
      # arbitrary text would break as well as leak.
      def handle_account_locked(_error)
        render_bearer_unauthorized!(error_description: "The account is locked")
      end

      def handle_oauth_error(error)
        render json: {
          error: error.oauth_error_code,
          error_description: error.message
        }, status: error.http_status
      end

      def render_bearer_unauthorized!(error_description: default_invalid_token_message, error_code: "invalid_token")
        response.set_header(
          "WWW-Authenticate",
          %Q(Bearer realm="StandardId", error="#{error_code}", error_description="#{error_description}")
        )
        render json: { error: error_code, error_description: error_description }, status: :unauthorized
      end

      def default_invalid_token_message
        "The access token is invalid or has expired"
      end
    end
  end
end
