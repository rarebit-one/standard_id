module StandardId
  # Session errors
  class NotAuthenticatedError < StandardError; end

  class InvalidSessionError < StandardError; end
  class ExpiredSessionError < InvalidSessionError; end
  class RevokedSessionError < InvalidSessionError; end

  # Account errors
  #
  # These deliberately do NOT descend from InvalidSessionError, even though
  # doing so would make every host's existing `rescue_from InvalidSessionError`
  # catch them for free. Two reasons:
  #
  #   1. They mean something different. An InvalidSessionError says the
  #      credential is no good — expired, revoked — and the remedy is to sign in
  #      again. These say the credential is fine and the ACCOUNT is disabled;
  #      signing in again will not help, and the user needs to be told so.
  #      Hosts document that distinction in their UX (see the README's
  #      "Handling AccountDeactivatedError" / "Handling AccountLockedError").
  #   2. Reparenting them would silently HIJACK the handlers hosts already
  #      wrote. Web::BaseController registers
  #      `rescue_from NotAuthenticatedError, InvalidSessionError, with:
  #      :redirect_unauthenticated_to_login`, and Rails resolves rescue_from
  #      handlers most-recently-registered-first — a subclass's registration
  #      wins over its parent's. A host's `rescue_from AccountDeactivatedError`
  #      on ApplicationController is registered EARLIER than the gem's
  #      subclass registration, so as a subclass of InvalidSessionError these
  #      would start bouncing to /login instead of reaching the host's
  #      account-deactivated page. That is a behaviour regression for every
  #      consumer who followed the README.
  #
  # Consequently every entry point that must not raise has to rescue these
  # explicitly; StandardId::Api::BaseController does.
  class AccountDeactivatedError < StandardError; end

  class AccountLockedError < StandardError
    # lock_reason and locked_at are available for logging and admin use.
    # Avoid surfacing lock_reason in user-facing responses.
    attr_reader :lock_reason, :locked_at

    def initialize(account)
      @lock_reason = account.lock_reason
      @locked_at = account.locked_at
      super("Account has been locked")
    end
  end

  # OAuth errors
  class OAuthError < StandardError
    def oauth_error_code
      :invalid_request
    end

    def http_status
      :bad_request
    end
  end

  class UnsupportedGrantTypeError < OAuthError
    def oauth_error_code = :unsupported_grant_type
  end

  class MissingClientSecretCredentialsError < OAuthError
    def oauth_error_code = :invalid_request
  end

  class InvalidClientSecretCredentialsError < OAuthError
    def oauth_error_code = :invalid_client
    def http_status = :unauthorized
  end

  class InvalidRequestError < OAuthError
    def oauth_error_code = :invalid_request
  end

  # A lib-level rate limit tripped (StandardId::RateLimiter). A subclass of
  # InvalidRequestError so every path that already turns a refused OTP start
  # into a flash, a failure result or an OAuth error body keeps doing so; the
  # API error handler renders it as 429 `rate_limit_exceeded`, the same shape
  # the controller-level limits produce.
  class RateLimitExceededError < InvalidRequestError
    # Length in seconds of the window that tripped (an upper bound on the
    # wait, not the time remaining), for a Retry-After header.
    attr_reader :retry_after

    def initialize(message = "Too many requests. Please try again later.", retry_after: nil)
      super(message)
      @retry_after = retry_after
    end

    def oauth_error_code = :rate_limit_exceeded
    def http_status = :too_many_requests
  end

  # The OTP resend cooldown (`passwordless.retry_delay`) refused a start: a code
  # for this target was issued less than retry_delay seconds ago and is still
  # usable, so nothing new was sent. A subclass of InvalidRequestError so every
  # existing rescue keeps working; Otp.issue reports it as `error_code:
  # :cooldown` so a host can show its own "a code is already on its way" copy
  # and tell it apart from a send failure. `retry_after` is the seconds left.
  class RetryDelayError < InvalidRequestError
    attr_reader :retry_after

    def initialize(message = "Please wait before requesting another code", retry_after: nil)
      super(message)
      @retry_after = retry_after
    end
  end

  class InvalidClientError < OAuthError
    def oauth_error_code = :invalid_client
    def http_status = :unauthorized
  end

  class InvalidGrantError < OAuthError
    def oauth_error_code = :invalid_grant
  end

  # Raised at mint time when an account has no profile of the type bound
  # to the requested audience via `c.oauth.audience_profile_types`.
  #
  # Subclass of `InvalidGrantError` so existing OAuth error handling
  # (which renders OAuthError as RFC 6749 error responses) treats this
  # as `invalid_grant`. The audience and expected profile types are
  # surfaced via readers for audit logging only — operators MUST NOT
  # interpolate them into client-facing error responses, since the
  # configured profile-type taxonomy is internal-only information.
  class NoBoundProfileError < InvalidGrantError
    attr_reader :audience, :expected_profile_types

    def initialize(audience:, expected_profile_types:)
      @audience = audience
      @expected_profile_types = Array(expected_profile_types)
      super("No profile of type [#{@expected_profile_types.join(', ')}] " \
            "for audience '#{audience}'")
    end
  end

  # Raised at mint time when an account has more than one active profile
  # of the type bound to the requested audience. Selecting one silently
  # would be non-deterministic and unauditable, so we fail closed and let
  # the host app resolve the ambiguity (deactivate duplicates, or pass an
  # explicit `profile_id` once that grant parameter is supported).
  #
  # Same audit-only/PII rules as `NoBoundProfileError`: do NOT surface
  # profile_ids in client-facing responses.
  class AmbiguousProfileError < InvalidGrantError
    attr_reader :audience, :expected_profile_types, :profile_ids

    def initialize(audience:, expected_profile_types:, profile_ids:)
      @audience = audience
      @expected_profile_types = Array(expected_profile_types)
      @profile_ids = Array(profile_ids)
      super("Multiple active profiles of type [#{@expected_profile_types.join(', ')}] " \
            "for audience '#{audience}' (#{@profile_ids.length} profile(s))")
    end
  end

  class InvalidScopeError < OAuthError
    def oauth_error_code = :invalid_scope
  end

  # RFC 8707 §2: the `resource` parameter names something this server does not
  # issue tokens for. Raised by StandardId::Oauth::AudienceResolver when
  # `oauth.resource_audiences` is configured and the resource is not in it.
  class InvalidTargetError < OAuthError
    def oauth_error_code = :invalid_target
  end

  class UnauthorizedClientError < OAuthError
    def oauth_error_code = :unauthorized_client
  end

  class UnsupportedResponseTypeError < OAuthError
    def oauth_error_code = :unsupported_response_type
  end

  # RFC 7591 §3.2.2 client registration errors. Both render as HTTP 400 with
  # an `error` of `invalid_redirect_uri` / `invalid_client_metadata` and an
  # `error_description`. They subclass OAuthError so the existing OAuth error
  # handling renders them in the standard error shape.
  class InvalidRedirectUriError < OAuthError
    def oauth_error_code = :invalid_redirect_uri
  end

  class InvalidClientMetadataError < OAuthError
    def oauth_error_code = :invalid_client_metadata
  end

  # Lifecycle hook errors
  class AuthenticationDenied < StandardError; end

  # Raised by a host hook (`config.social.before_account`,
  # `config.social.before_mint`) to refuse a request with the host's own
  # response: the API engine renders `body` as JSON with `status` (and any
  # `headers`) verbatim, after the refusing flow has cleaned up as for any
  # other refusal. For a refusal the host's clients must be able to tell apart
  # from an OAuth error — a region block, a pending deletion — in the host's
  # error envelope.
  #
  #   raise StandardId::RequestRefused.new(status: :forbidden,
  #     body: { error: { code: "REGION_BLOCKED", message: "..." } })
  class RequestRefused < StandardError
    attr_reader :status, :body, :headers

    def initialize(status:, body:, headers: {}, message: nil)
      @status = status
      @body = body
      @headers = headers.to_h
      super(message || "Request refused (#{status})")
    end
  end

  # Raised when `config.login_method_policy` refuses an authentication method
  # for an account (e.g. "staff must sign in with the org IdP"). See
  # StandardId::LoginMethodPolicy.
  #
  # A subclass of AuthenticationDenied so every WebEngine flow that already
  # rescues AuthenticationDenied (redirect to /login with the message as the
  # flash alert, new-account cleanup) handles it unchanged. The API engine
  # renders it as `403 access_denied` (see Api::BaseController), the same
  # shape as SocialLinkError.
  #
  # The policy is only ever consulted AFTER the credential has been proven
  # (password checked, OTP verified, provider token verified), so the message
  # reaches only someone who already controls the credential. Policies may
  # raise this themselves to supply their own message:
  #
  #   raise StandardId::LoginMethodDenied, "Staff must sign in with Void Which Binds"
  #
  # `auth_method`, `provider` and `flow` are filled in by the engine for
  # logging and audit; do not surface them to end users.
  class LoginMethodDenied < AuthenticationDenied
    DEFAULT_MESSAGE = "This sign-in method is not available for your account".freeze

    attr_reader :auth_method, :provider, :flow

    def initialize(message = nil, auth_method: nil, provider: nil, flow: nil)
      @auth_method = auth_method
      @provider = provider
      @flow = flow
      super(message.presence || DEFAULT_MESSAGE)
    end

    def oauth_error_code = :access_denied
    def http_status = :forbidden
  end

  # Social login errors
  # NOTE: email and provider_name are exposed as reader attributes for host
  # apps to build custom error responses. If you report exceptions to an
  # error tracker (Sentry, etc.), be aware these attributes contain PII.
  #
  # `reason` says why the link was refused:
  #   :link_required    — the email belongs to an account the strict
  #                       link_strategy will not link this provider to
  #   :email_unverified — the provider did not report the email as verified,
  #                       so it cannot prove ownership of the existing account
  #   :subject_mismatch — the account's email identifier is already linked to a
  #                       different subject (`sub`) from this provider
  # (SOCIAL_LINK_BLOCKED also uses :subject_conflict, for the race raised as
  # SocialLinkConflictError rather than this error.)
  class SocialLinkError < OAuthError
    REASONS = %i[link_required email_unverified subject_mismatch].freeze

    attr_reader :email, :provider_name, :reason

    def initialize(email:, provider_name:, reason: :link_required)
      @email = email
      @provider_name = provider_name
      @reason = reason
      super("This email is already associated with an account. Please sign in first to link this provider.")
    end

    # Uses standard OAuth :access_denied code since account_link_required is non-standard
    def oauth_error_code = :access_denied
    def http_status = :forbidden
  end

  # Raised while a social login writes its (provider, sub) link and loses a
  # race to a concurrent login. The client sees a retryable `invalid_grant`;
  # SOCIAL_LINK_BLOCKED is published with `reason` (not SOCIAL_AUTH_FAILED,
  # which is for infrastructure failures):
  #   :subject_conflict — the same (provider, sub) was committed for a
  #     DIFFERENT account;
  #   :subject_mismatch — this identifier was linked to this provider under a
  #     DIFFERENT sub (the (identifier, provider) unique index won).
  class SocialLinkConflictError < InvalidGrantError
    attr_reader :identifier, :reason

    def initialize(message = nil, identifier: nil, reason: :subject_conflict)
      @identifier = identifier
      @reason = reason
      super(message)
    end
  end

  # Audience verification errors
  class InvalidAudienceError < StandardError
    attr_reader :required, :actual

    def initialize(required:, actual:)
      @required = required
      @actual = actual
      super("Token audience [#{actual.join(', ')}] does not match required audiences: #{required.join(', ')}")
    end
  end

  # Raised when an access token's audience is permitted for the controller
  # but the account lacks a profile of the type configured for that audience
  # in `StandardId.config.oauth.audience_profile_types`.
  #
  # Includes audit-friendly attributes (raw values from the JWT and config)
  # that callers may log but must NOT interpolate into response headers or
  # API response bodies without sanitization.
  #
  # Deliberately a separate class (not a subclass of InvalidAudienceError)
  # so host apps can distinguish "audience not permitted" from "audience
  # matched but profile binding failed" in their error handling. The
  # `AudienceVerification` concern renders both as 403 insufficient_scope.
  class InvalidAudienceProfileError < StandardError
    attr_reader :audience, :expected_profile_types, :actual_profile_type, :required, :actual

    def initialize(audience:, expected_profile_types:, actual_profile_type:, required: [], actual: [])
      @audience = audience
      @expected_profile_types = Array(expected_profile_types)
      @actual_profile_type = actual_profile_type
      @required = required
      @actual = actual
      expected = @expected_profile_types.join(", ")
      super("Token audience '#{audience}' requires profile type [#{expected}] but account has '#{actual_profile_type || 'none'}'")
    end
  end

  # JWT primitive errors raised by JwtService.verify.
  # These are distinct from the OAuth/session decode path, which returns nil
  # on failure — callers of the primitive API get rich error info.
  class InvalidTokenError < StandardError; end
  class ExpiredTokenError < InvalidTokenError; end
  class InvalidSignatureError < InvalidTokenError; end
  class InvalidAlgorithmError < InvalidTokenError; end
  class InvalidAudienceTokenError < InvalidTokenError; end

  # Raised by the API email + password endpoints (StandardId::EmailPassword).
  # +code+ is one of CODES — stable symbols a client can branch on — and the
  # status is fixed per code, so `c.email_password.error_renderer` can change
  # the body without having to know the status. +details+ carries field
  # messages for :weak_password and :invalid_request.
  class EmailPasswordError < StandardError
    CODES = {
      invalid_credentials: { status: :unauthorized, message: "Invalid email or password" },
      unverified: { status: :forbidden, message: "The email address has not been verified" },
      account_exists: { status: :conflict, message: "An account with this email already exists" },
      social_account: { status: :conflict, message: "This email is registered with a different sign-in method" },
      invalid_code: { status: :unprocessable_content, message: "Invalid or expired verification code" },
      invalid_reset_token: { status: :unprocessable_content, message: "The password reset link is invalid or has expired" },
      weak_password: { status: :unprocessable_content, message: "The password does not meet the requirements" },
      invalid_request: { status: :unprocessable_content, message: "The request is invalid" },
      login_method_denied: { status: :forbidden, message: "This sign-in method is not available for this account" },
      rate_limited: { status: :too_many_requests, message: "Too many requests. Please try again later." }
    }.freeze

    attr_reader :code, :details, :retry_after

    def initialize(code, message = nil, details: {}, retry_after: nil)
      @code = code.to_sym
      raise ArgumentError, "Unknown EmailPasswordError code: #{code.inspect}" unless CODES.key?(@code)

      @details = details.to_h
      @retry_after = retry_after
      super(message.presence || CODES.dig(@code, :message))
    end

    def status
      CODES.dig(code, :status)
    end

    def http_status
      Rack::Utils.status_code(status)
    end
  end

  # Raised for engine misconfiguration — a required config value is missing,
  # malformed, points at a non-callable with the wrong arity, or references a
  # scope whose claims have no resolver registered. Always indicates a
  # host-app bug at boot or first-use; never surfaced to end users.
  class ConfigurationError < StandardError; end
end
