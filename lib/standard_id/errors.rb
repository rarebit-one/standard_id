module StandardId
  class NotAuthenticatedError < StandardError; end

  class InvalidSessionError < StandardError; end
  class ExpiredSessionError < InvalidSessionError; end
  class RevokedSessionError < InvalidSessionError; end

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
end
