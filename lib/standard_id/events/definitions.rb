module StandardId
  module Events
    module Definitions
      AUTHENTICATION_ATTEMPT_STARTED = "authentication.attempt.started"
      AUTHENTICATION_SUCCEEDED = "authentication.attempt.succeeded"
      AUTHENTICATION_FAILED = "authentication.attempt.failed"
      PASSWORD_VALIDATED = "authentication.password.validated"
      PASSWORD_VALIDATION_FAILED = "authentication.password.failed"
      OTP_VALIDATED = "authentication.otp.validated"
      OTP_VALIDATION_FAILED = "authentication.otp.failed"

      SESSION_CREATING = "session.creating"
      SESSION_CREATED = "session.created"
      SESSION_VALIDATING = "session.validating"
      SESSION_VALIDATED = "session.validated"
      SESSION_EXPIRED = "session.expired"
      SESSION_REVOKED = "session.revoked"
      SESSION_REFRESHED = "session.refreshed"

      ACCOUNT_CREATING = "account.creating"
      ACCOUNT_CREATED = "account.created"
      ACCOUNT_VERIFIED = "account.verified"
      ACCOUNT_STATUS_CHANGED = "account.status_changed"
      ACCOUNT_ACTIVATED = "account.activated"
      ACCOUNT_DEACTIVATED = "account.deactivated"
      ACCOUNT_LOCKED = "account.locked"
      ACCOUNT_UNLOCKED = "account.unlocked"

      IDENTIFIER_CREATED = "identifier.created"
      IDENTIFIER_VERIFICATION_STARTED = "identifier.verification.started"
      IDENTIFIER_VERIFICATION_SUCCEEDED = "identifier.verification.succeeded"
      IDENTIFIER_VERIFICATION_FAILED = "identifier.verification.failed"
      IDENTIFIER_LINKED = "identifier.linked"

      OAUTH_AUTHORIZATION_REQUESTED = "oauth.authorization.requested"
      OAUTH_AUTHORIZATION_GRANTED = "oauth.authorization.granted"
      OAUTH_AUTHORIZATION_DENIED = "oauth.authorization.denied"
      OAUTH_TOKEN_ISSUING = "oauth.token.issuing"
      OAUTH_TOKEN_ISSUED = "oauth.token.issued"
      OAUTH_TOKEN_REFRESHED = "oauth.token.refreshed"
      OAUTH_CODE_CONSUMED = "oauth.code.consumed"
      OAUTH_TOKEN_REVOKED = "oauth.token.revoked"
      OAUTH_REFRESH_TOKEN_REUSE_DETECTED = "oauth.refresh_token.reuse_detected"
      OAUTH_AUDIENCE_MISMATCH = "oauth.audience.mismatch"

      PASSWORDLESS_CODE_REQUESTED = "passwordless.code.requested"
      PASSWORDLESS_CODE_GENERATED = "passwordless.code.generated"
      PASSWORDLESS_CODE_SENT = "passwordless.code.sent"
      PASSWORDLESS_CODE_VERIFIED = "passwordless.code.verified"
      PASSWORDLESS_CODE_FAILED = "passwordless.code.failed"
      PASSWORDLESS_ACCOUNT_CREATED = "passwordless.account.created"

      SOCIAL_AUTH_STARTED = "social.auth.started"
      SOCIAL_CALLBACK_RECEIVED = "social.auth.callback_received"
      SOCIAL_USER_INFO_FETCHED = "social.user_info.fetched"
      SOCIAL_ACCOUNT_CREATED = "social.account.created"
      SOCIAL_ACCOUNT_LINKED = "social.account.linked"
      SOCIAL_LINK_BLOCKED = "social.link.blocked"
      SOCIAL_AUTH_COMPLETED = "social.auth.completed"
      SOCIAL_AUTH_FAILED = "social.auth.failed"

      CREDENTIAL_PASSWORD_CREATED = "credential.password.created"
      CREDENTIAL_PASSWORD_RESET_INITIATED = "credential.password.reset_initiated"
      CREDENTIAL_PASSWORD_RESET_COMPLETED = "credential.password.reset_completed"
      CREDENTIAL_PASSWORD_CHANGED = "credential.password.changed"
      CREDENTIAL_CLIENT_SECRET_CREATED = "credential.client_secret.created"
      CREDENTIAL_CLIENT_SECRET_ROTATED = "credential.client_secret.rotated"
      CREDENTIAL_CLIENT_SECRET_REVOKED = "credential.client_secret.revoked"

      AUTHENTICATION_EVENTS = [
        AUTHENTICATION_ATTEMPT_STARTED,
        AUTHENTICATION_SUCCEEDED,
        AUTHENTICATION_FAILED,
        PASSWORD_VALIDATED,
        PASSWORD_VALIDATION_FAILED,
        OTP_VALIDATED,
        OTP_VALIDATION_FAILED
      ].freeze

      SESSION_EVENTS = [
        SESSION_CREATING,
        SESSION_CREATED,
        SESSION_VALIDATING,
        SESSION_VALIDATED,
        SESSION_EXPIRED,
        SESSION_REVOKED,
        SESSION_REFRESHED
      ].freeze

      ACCOUNT_EVENTS = [
        ACCOUNT_CREATING,
        ACCOUNT_CREATED,
        ACCOUNT_VERIFIED,
        ACCOUNT_STATUS_CHANGED,
        ACCOUNT_ACTIVATED,
        ACCOUNT_DEACTIVATED,
        ACCOUNT_LOCKED,
        ACCOUNT_UNLOCKED
      ].freeze

      IDENTIFIER_EVENTS = [
        IDENTIFIER_CREATED,
        IDENTIFIER_VERIFICATION_STARTED,
        IDENTIFIER_VERIFICATION_SUCCEEDED,
        IDENTIFIER_VERIFICATION_FAILED,
        IDENTIFIER_LINKED
      ].freeze

      OAUTH_EVENTS = [
        OAUTH_AUTHORIZATION_REQUESTED,
        OAUTH_AUTHORIZATION_GRANTED,
        OAUTH_AUTHORIZATION_DENIED,
        OAUTH_TOKEN_ISSUING,
        OAUTH_TOKEN_ISSUED,
        OAUTH_TOKEN_REFRESHED,
        OAUTH_CODE_CONSUMED,
        OAUTH_TOKEN_REVOKED,
        OAUTH_REFRESH_TOKEN_REUSE_DETECTED,
        OAUTH_AUDIENCE_MISMATCH
      ].freeze

      PASSWORDLESS_EVENTS = [
        PASSWORDLESS_CODE_REQUESTED,
        PASSWORDLESS_CODE_GENERATED,
        PASSWORDLESS_CODE_SENT,
        PASSWORDLESS_CODE_VERIFIED,
        PASSWORDLESS_CODE_FAILED,
        PASSWORDLESS_ACCOUNT_CREATED
      ].freeze

      SOCIAL_EVENTS = [
        SOCIAL_AUTH_STARTED,
        SOCIAL_CALLBACK_RECEIVED,
        SOCIAL_USER_INFO_FETCHED,
        SOCIAL_ACCOUNT_CREATED,
        SOCIAL_ACCOUNT_LINKED,
        SOCIAL_LINK_BLOCKED,
        SOCIAL_AUTH_COMPLETED,
        SOCIAL_AUTH_FAILED
      ].freeze

      CREDENTIAL_EVENTS = [
        CREDENTIAL_PASSWORD_CREATED,
        CREDENTIAL_PASSWORD_RESET_INITIATED,
        CREDENTIAL_PASSWORD_RESET_COMPLETED,
        CREDENTIAL_PASSWORD_CHANGED,
        CREDENTIAL_CLIENT_SECRET_CREATED,
        CREDENTIAL_CLIENT_SECRET_ROTATED,
        CREDENTIAL_CLIENT_SECRET_REVOKED
      ].freeze

      SECURITY_EVENTS = [
        # Authentication
        AUTHENTICATION_SUCCEEDED,
        AUTHENTICATION_FAILED,
        PASSWORD_VALIDATION_FAILED,
        OTP_VALIDATION_FAILED,
        # Session
        SESSION_CREATED,
        SESSION_REVOKED,
        SESSION_EXPIRED,
        # Account
        ACCOUNT_CREATED,
        ACCOUNT_VERIFIED,
        ACCOUNT_STATUS_CHANGED,
        ACCOUNT_ACTIVATED,
        ACCOUNT_DEACTIVATED,
        ACCOUNT_LOCKED,
        ACCOUNT_UNLOCKED,
        # Identifier
        IDENTIFIER_VERIFICATION_FAILED,
        # OAuth
        OAUTH_AUTHORIZATION_GRANTED,
        OAUTH_AUTHORIZATION_DENIED,
        OAUTH_TOKEN_ISSUED,
        OAUTH_TOKEN_REFRESHED,
        OAUTH_TOKEN_REVOKED,
        OAUTH_REFRESH_TOKEN_REUSE_DETECTED,
        OAUTH_AUDIENCE_MISMATCH,
        # Passwordless
        PASSWORDLESS_CODE_FAILED,
        PASSWORDLESS_ACCOUNT_CREATED,
        # Credential
        CREDENTIAL_PASSWORD_CREATED,
        CREDENTIAL_PASSWORD_RESET_INITIATED,
        CREDENTIAL_PASSWORD_RESET_COMPLETED,
        CREDENTIAL_PASSWORD_CHANGED,
        CREDENTIAL_CLIENT_SECRET_CREATED,
        CREDENTIAL_CLIENT_SECRET_ROTATED,
        CREDENTIAL_CLIENT_SECRET_REVOKED,
        # Social
        SOCIAL_ACCOUNT_CREATED,
        SOCIAL_ACCOUNT_LINKED,
        SOCIAL_LINK_BLOCKED,
        SOCIAL_AUTH_FAILED
      ].freeze

      ALL_EVENTS = (
        AUTHENTICATION_EVENTS +
        SESSION_EVENTS +
        ACCOUNT_EVENTS +
        IDENTIFIER_EVENTS +
        OAUTH_EVENTS +
        PASSWORDLESS_EVENTS +
        SOCIAL_EVENTS +
        CREDENTIAL_EVENTS
      ).freeze
    end

    # Include definitions at module level for convenience
    include Definitions
  end
end
