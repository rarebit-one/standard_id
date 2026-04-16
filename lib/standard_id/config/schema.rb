# Schema definitions for StandardId
# This file defines the configuration schema structure

require "standard_config"

StandardConfig.schema.draw do
  scope :base do
    field :account_class_name, type: :string, default: "User"
    field :cache_store, type: :any, default: nil
    field :logger, type: :any, default: nil
    field :web_layout, type: :string, default: nil
    field :passwordless_email_sender, type: :any, default: nil
    field :passwordless_sms_sender, type: :any, default: nil
    field :issuer, type: :string, default: nil
    field :login_url, type: :string, default: nil
    field :allowed_post_logout_redirect_uris, type: :array, default: []
    field :account_scope, type: :any, default: nil
    field :use_inertia, type: :boolean, default: false
    field :inertia_component_namespace, type: :string, default: "standard_id"
    field :alias_current_user, type: :boolean, default: false

    # Scope-aware authentication: maps scope names to profile-based access config.
    # Each scope is a hash with keys: :profile_types (Array<String>), :after_sign_in_path,
    # :no_profile_message, :label, :allow_registration, :authorizer.
    # The legacy :profile_type (singular String) key is still accepted for backward
    # compatibility and coerced into a single-element :profile_types array (deprecation
    # warning fires on use).
    field :scopes, type: :any, default: {}

    # Callable that resolves the active scope name for a given request/session.
    # Receives keyword args (request:, session:) and must return a Symbol (or nil).
    # Default (nil) reads :scope from route defaults — preserving the original behaviour.
    # Override to derive the scope from subdomains, session state, custom path
    # parameters (e.g. :control_plane), or any other app-specific mechanism.
    # See StandardId::LifecycleHooks::DEFAULT_SCOPE_RESOLVER for the built-in fallback.
    field :scope_resolver, type: :any, default: nil

    # Callable that resolves whether an account has a profile for a given scope.
    # Receives (account, profile_type) and returns true/false — for single-type scopes
    # this keeps the historical signature; for multi-type scopes, the resolver is
    # invoked once per configured profile_type and any truthy return satisfies the check.
    # Override to customise profile lookup logic.
    # Default (nil) uses: account.profiles.exists?(profileable_type: profile_type)
    field :profile_resolver, type: :any, default: nil
    # Callable (lambda/proc) that returns a Hash of extra Sentry user context fields.
    # Receives (account, session) where session may be nil. Non-callable values are ignored.
    field :sentry_context, type: :any, default: nil

    # Post-authentication lifecycle hooks (synchronous, WebEngine only)
    #
    # after_account_created: Called after a new account is created via any mechanism.
    #   Receives: (account, request, context)
    #   Context: { mechanism: "passwordless"/"social"/"signup", provider: nil/"google"/"apple" }
    field :after_account_created, type: :any, default: nil

    # before_sign_in: Called after credential verification, BEFORE session creation.
    #   Receives: (account, request, context)
    #   Context: { mechanism: "password"/"passwordless"/"social", provider: nil/"google"/"apple",
    #              first_sign_in: bool }
    #   Return: nil or truthy to proceed with sign-in.
    #   Return { error: "message" } Hash to reject sign-in (error message is passed to the error flow).
    field :before_sign_in, type: :any, default: nil

    # after_sign_in: Called after successful sign-in, before redirect.
    #   Receives: (account, request, context)
    #   Context: { first_sign_in: bool, mechanism: "password"/"passwordless"/"social",
    #              provider: nil/"google"/"apple", session: StandardId::Session }
    #   Return: nil (default redirect) or a path string (override redirect)
    #   Raise StandardId::AuthenticationDenied.new("message") to reject sign-in.
    field :after_sign_in, type: :any, default: nil
  end

  scope :events do
    field :enable_logging, type: :boolean, default: false
  end

  scope :passwordless do
    # Deprecated: use web.passwordless_login to control WebEngine passwordless login.
    # Retained for backwards compatibility with consuming apps that set this field.
    field :enabled, type: :boolean, default: false
    field :connection, type: :string, default: "email"
    field :code_ttl, type: :integer, default: 600 # 10 minutes in seconds

    # Length of generated OTP codes. Default 6 digits (~20 bits of entropy).
    # For security-sensitive deployments, 8+ is recommended. Must be between 4 and 10.
    # Changing this only affects newly generated codes; existing active challenges
    # keep their original length.
    field :code_length, type: :integer, default: 6

    # Deprecated alias for :max_attempts_per_challenge, retained for backwards
    # compatibility. When :max_attempts_per_challenge is unset (nil), the
    # verification service falls back to this value.
    field :max_attempts, type: :integer, default: 3

    # Maximum number of incorrect OTP submissions per challenge, globally
    # (across all IPs). When the ceiling is reached, the challenge is marked
    # used so further attempts fail fast. This is distinct from the per-IP
    # rate limit (config.rate_limits.otp_verify_per_ip) — the per-IP limit
    # prevents brute-forcing from a single source, while this ceiling defends
    # against distributed brute-force attempts against the same challenge.
    # When nil, falls back to :max_attempts for backwards compatibility.
    field :max_attempts_per_challenge, type: :integer, default: nil

    field :retry_delay, type: :integer, default: 30 # 30 seconds
    # Bypass code for E2E testing — NEVER set in production (raises).
    # When set and Rails.env != "production", this code is accepted by
    # both the built-in passwordless login and by StandardId::Otp.verify
    # for *any* realm. Use a long, non-guessable value and unset it
    # outside test environments.
    field :bypass_code, type: :string, default: nil

    # Custom username validator for passwordless flows.
    # When set, called before OTP generation to validate the recipient address.
    # Must be a callable (lambda/proc) that receives (username, connection_type)
    # and returns nil/false to proceed, or an error message string to reject.
    # Example: ->(username, connection_type) { "Invalid email" unless MyValidator.valid?(username) }
    field :username_validator, type: :any, default: nil

    # Custom account factory for passwordless registration.
    # When set, replaces the default find_or_create_account! logic in strategies.
    # Must be a callable (lambda/proc) that receives (identifier:, params:, request:)
    # and returns an Account (or account-like) record.
    # When nil (default), uses the built-in strategy behavior.
    field :account_factory, type: :any, default: nil

    # OTP email delivery mode:
    #   :custom   — (default) host app handles delivery via event subscriber
    #   :built_in — engine sends OTP emails automatically using PasswordlessMailer
    field :delivery, type: :symbol, default: :custom
    field :mailer_from, type: :string, default: "noreply@example.com"
    field :mailer_subject, type: :string, default: "Your sign-in code"
  end

  scope :password do
    field :minimum_length, type: :integer, default: 8
    field :require_special_chars, type: :boolean, default: true
    field :require_uppercase, type: :boolean, default: true
    field :require_numbers, type: :boolean, default: true
  end

  scope :reset_password do
    # Password reset email delivery mode:
    #   :custom   — (default) host app handles delivery via event subscriber for
    #               CREDENTIAL_PASSWORD_RESET_INITIATED
    #   :built_in — engine sends reset emails automatically using
    #               PasswordResetMailer
    #
    # Note: the scope is named `reset_password` rather than `password_reset` to
    # avoid a name collision with the `web.password_reset` boolean feature flag
    # — StandardConfig resolves unique field names globally.
    field :delivery, type: :symbol, default: :custom
    field :mailer_from, type: :string, default: "noreply@example.com"
    field :mailer_subject, type: :string, default: "Reset your password"
  end

  scope :session do
    field :browser_session_lifetime, type: :integer, default: 86400 # 24 hours in seconds
    field :browser_session_remember_me_lifetime, type: :integer, default: 2592000 # 30 days in seconds
    field :device_session_lifetime, type: :integer, default: 2592000 # 30 days in seconds
    field :service_session_lifetime, type: :integer, default: 7776000 # 90 days in seconds

    # Callable that resolves the session class to create for a given auth flow.
    # Receives keyword arguments (request:, account:, flow:) and must return one of:
    #   StandardId::BrowserSession, StandardId::DeviceSession, StandardId::ServiceSession,
    #   the symbols :browser / :device / :service (mapped to the classes above),
    #   or nil/false to skip session creation (only honoured for flows where the
    #   gem does not currently persist a session — see default resolver below).
    #
    # Flow symbols currently emitted by the gem:
    #   :web_sign_in         — Web sign-in (password / passwordless / social).
    #                          Default: :browser
    #   :api_device_auth     — Api::TokenManager#create_device_session.
    #                          Default: :device
    #   :api_service_auth    — Api::TokenManager#create_service_session.
    #                          Default: :service
    #   :oauth_token_issued  — OAuth token grant just issued a JWT. Default
    #                          behaviour is to NOT persist a session (the gem
    #                          historically only returned a JWT). Override this
    #                          flow to have the gem persist a session (e.g.
    #                          DeviceSession) for native mobile OAuth flows.
    #
    # When nil (default), the gem uses a built-in resolver that mirrors the
    # gem's historical behaviour for each flow.
    field :session_type_resolver, type: :any, default: nil
  end

  scope :oauth do
    field :default_token_lifetime, type: :integer, default: 3600 # 1 hour in seconds
    field :refresh_token_lifetime, type: :integer, default: 2592000 # 30 days in seconds
    field :token_lifetimes, type: :hash, default: -> { {} }
    field :client_id, type: :string, default: nil
    field :client_secret, type: :string, default: nil
    field :scope_claims, type: :hash, default: -> { {} }
    field :claim_resolvers, type: :hash, default: -> { {} }
    field :allowed_audiences, type: :array, default: -> { [] } # Empty = no validation, any audience allowed

    # Audience → profile type binding (first-class audience modeling).
    #
    # Maps each configured audience string to the profile type (or types)
    # that an authenticated account must hold for that audience. When set,
    # `StandardId::AudienceVerification` enforces — after the usual
    # allowed-audiences check — that the account has a matching profile.
    #
    # Values may be a single String or an Array<String> for multi-type audiences.
    #
    # Example:
    #   c.oauth.audience_profile_types = {
    #     "admin_kit"     => "PlatformProfile",
    #     "companion_kit" => "DeviceUserProfile",
    #     "harness"       => ["PlatformProfile", "DeviceUserProfile"]
    #   }
    #
    # When empty (default) or the matched audience is absent from the map,
    # the profile-type check is skipped (back-compat with apps that do not
    # model profiles or that enforce this invariant themselves).
    field :audience_profile_types, type: :hash, default: -> { {} }

    # Optional resolver for picking the profile an account uses for a given
    # audience. Called with keyword arguments `(account:, audience:, profile_types:)`
    # where `profile_types` is the `Array<String>` of acceptable profile types
    # for the matched audience. Must return the profile record (or nil).
    #
    # When nil (default), the gem looks up
    #   account.profiles.detect { |p| profile_types.include?(p.profileable_type) }
    # and prefers an `active?`-responding record if multiple match.
    field :audience_profile_resolver, type: :any, default: nil

    # JWT signing configuration (for asymmetric algorithms)
    # If nil, uses HS256 with Rails.application.secret_key_base
    field :signing_key, type: :any, default: nil

    # Previous signing keys for key rotation (array of PEM strings or Pathnames)
    # During rotation, move the old signing_key here so tokens signed with it
    # can still be verified. Remove after the grace period.
    field :previous_signing_keys, type: :array, default: -> { [] }

    # Signing algorithm (see JwtService::SUPPORTED_ALGORITHMS for full list)
    # Symmetric (HMAC): :hs256, :hs384, :hs512
    # Asymmetric (RSA): :rs256, :rs384, :rs512
    # Asymmetric (ECDSA): :es256, :es384, :es512
    field :signing_algorithm, type: :symbol, default: :hs256

    # Custom claims callable for encoding additional claims into JWT access tokens.
    # Receives keyword arguments: account:, client:, request:, audience:
    # Must return a Hash of custom claims to merge into the JWT payload.
    # Example: ->(account:, **) { { channel_id: account.channel_id } }
    field :custom_claims, type: :any, default: nil
  end

  scope :social do
    field :social_account_attributes, type: :any, default: nil
    field :allowed_redirect_url_prefixes, type: :array, default: []
    field :available_scopes, type: :array, default: -> { [] }
    field :link_strategy, type: :symbol, default: :strict
  end

  scope :web do
    field :password_login, type: :boolean, default: true
    field :signup, type: :boolean, default: true
    field :passwordless_login, type: :boolean, default: false
    field :social_login, type: :boolean, default: true
    field :password_reset, type: :boolean, default: true
    field :email_verification, type: :boolean, default: true
    field :phone_verification, type: :boolean, default: true
    field :sessions_management, type: :boolean, default: true
    field :passwordless_registration, type: :boolean, default: false
  end

  # Rate limiting defaults (used by Rails 8 built-in rate_limit DSL)
  scope :rate_limits do
    # RAR-51: Password login
    field :password_login_per_ip, type: :integer, default: 20        # per 15 minutes
    field :password_login_per_email, type: :integer, default: 5      # per 15 minutes

    # RAR-60: OTP verification
    field :otp_verify_per_ip, type: :integer, default: 20            # per 15 minutes

    # RAR-56: Email/phone verification code generation
    field :verification_start_per_target, type: :integer, default: 3 # per 15 minutes
    field :verification_start_per_ip, type: :integer, default: 10    # per hour

    # API equivalents
    field :api_passwordless_start_per_ip, type: :integer, default: 10    # per hour
    field :api_passwordless_start_per_target, type: :integer, default: 5 # per 15 minutes
    field :api_token_per_ip, type: :integer, default: 30                 # per 15 minutes
  end
end
