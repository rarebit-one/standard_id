module StandardId
  # Session errors
  class NotAuthenticatedError < StandardError; end

  class InvalidSessionError < StandardError; end
  class ExpiredSessionError < InvalidSessionError; end
  class RevokedSessionError < InvalidSessionError; end

  # Account errors
  class AccountDeactivatedError < StandardError; end

  class AccountLockedError < StandardError
    # These attributes are for internal/admin logging only.
    # Do not surface them in HTTP responses or user-facing messages.
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

  class InvalidScopeError < OAuthError
    def oauth_error_code = :invalid_scope
  end

  class UnauthorizedClientError < OAuthError
    def oauth_error_code = :unauthorized_client
  end

  class UnsupportedResponseTypeError < OAuthError
    def oauth_error_code = :unsupported_response_type
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
end
