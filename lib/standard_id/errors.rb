module StandardId
  # Session errors
  class NotAuthenticatedError < StandardError; end

  class InvalidSessionError < StandardError; end
  class ExpiredSessionError < InvalidSessionError; end
  class RevokedSessionError < InvalidSessionError; end

  # Account errors
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

  class UnauthorizedClientError < OAuthError
    def oauth_error_code = :unauthorized_client
  end

  class UnsupportedResponseTypeError < OAuthError
    def oauth_error_code = :unsupported_response_type
  end

  # Lifecycle hook errors
  class AuthenticationDenied < StandardError; end

  # Social login errors
  # NOTE: email and provider_name are exposed as reader attributes for host
  # apps to build custom error responses. If you report exceptions to an
  # error tracker (Sentry, etc.), be aware these attributes contain PII.
  class SocialLinkError < OAuthError
    attr_reader :email, :provider_name

    def initialize(email:, provider_name:)
      @email = email
      @provider_name = provider_name
      super("This email is already associated with an account. Please sign in first to link this provider.")
    end

    # Uses standard OAuth :access_denied code since account_link_required is non-standard
    def oauth_error_code = :access_denied
    def http_status = :forbidden
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

  # Raised for engine misconfiguration — a required config value is missing,
  # malformed, points at a non-callable with the wrong arity, or references a
  # scope whose claims have no resolver registered. Always indicates a
  # host-app bug at boot or first-use; never surfaced to end users.
  class ConfigurationError < StandardError; end
end
