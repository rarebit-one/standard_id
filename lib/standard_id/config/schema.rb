# Schema definitions for StandardId
# This file defines the configuration schema structure

require "standard_id/config_schema"

StandardId::ConfigSchema.define do
  scope :base do
    field :account_class_name, type: :string, default: "User"
    field :cache_store, type: :any, default: nil
    field :logger, type: :any, default: nil
    field :web_layout, type: :string, default: nil
    field :passwordless_email_sender, type: :any, default: nil
    field :passwordless_sms_sender, type: :any, default: nil
    field :issuer, type: :string, default: nil

    # Whether `JwtService.decode` REQUIRES a matching `iss` claim.
    #
    # `nil` (default) means "follow the issuer": verification is on exactly
    # when `issuer` is set. That is the historic behaviour and is what you
    # want once an issuer has always been configured.
    #
    # Set `false` to MINT an `iss` claim without yet REQUIRING one. This
    # exists because the two were coupled, and that coupling makes adopting an
    # issuer an all-or-nothing flag day: every token already in flight was
    # minted without an `iss`, so turning the issuer on rejected all of them at
    # once — every access token and, far worse, every refresh token. For an app
    # that had never set an issuer there was no safe single step, which is
    # exactly the position nutripod-web was stuck in (rarebit-one/nutripod-web#1111).
    #
    # The migration is then: set `issuer` with `verify_issuer = false`, wait
    # out `refresh_token_lifetime` (the long pole — access tokens are short),
    # then remove the override. Setting `true` with no issuer raises at boot
    # rather than silently verifying nothing.
    field :verify_issuer, type: :boolean, default: nil
    field :login_url, type: :string, default: nil
    field :allowed_post_logout_redirect_uris, type: :array, default: []
    field :account_scope, type: :any, default: nil
    field :use_inertia, type: :boolean, default: false
    field :inertia_component_namespace, type: :string, default: "standard_id"
    field :alias_current_user, type: :boolean, default: false

    # Opt the gem's own associations out of an app-wide
    # `strict_loading_by_default = true`.
    #
    # `nil` (default) means "say nothing": the `strict_loading:` option is
    # omitted from the association declarations entirely, so they inherit the
    # owner's setting exactly as they always have. `false` opts them out; `true`
    # forces them on even in an app that has strict loading off.
    #
    # This must stay tri-state and `nil` must mean OMITTED, not `false`. Rails
    # checks `reflection.options.key?(:strict_loading)` before consulting the
    # owner (ActiveRecord::Associations::Association#violates_strict_loading?),
    # so declaring `strict_loading: nil` would put the key in the hash and make
    # `reflection.strict_loading?` return false — silently disabling strict
    # loading for every app that never asked for it.
    field :association_strict_loading, type: :any, default: nil

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
    # Bypass code for E2E testing — refused on production deploys (raises).
    # When set and the deploy is *not* production, this code is accepted by
    # both the built-in passwordless login and by StandardId::Otp.verify
    # for *any* realm. Use a long, non-guessable value and unset it
    # outside test environments.
    #
    # "Production" is decided by production_env_detector below (default
    # Rails.env.production?), so host apps that distinguish a physical deploy
    # environment from RAILS_ENV can still gate this correctly.
    field :bypass_code, type: :string, default: nil

    # Optional callable deciding whether the current deploy is "production"
    # for the purpose of the bypass-code guard. Takes no args, returns a
    # boolean. When nil (default), falls back to Rails.env.production? — so
    # existing consumers are unchanged. Host apps that distinguish a physical
    # deploy environment from RAILS_ENV (e.g. APP_ENVIRONMENT, which stays
    # RAILS_ENV=production on a physically-staging box) can supply
    # `-> { AppEnv.production? }` to allow a bypass code on staging while it
    # stays refused on real production.
    field :production_env_detector, type: :any, default: nil

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
    # — StandardId::ConfigSchema resolves unique field names globally.
    field :delivery, type: :symbol, default: :custom
    field :mailer_from, type: :string, default: "noreply@example.com"
    field :mailer_subject, type: :string, default: "Reset your password"
  end

  scope :session do
    field :browser_session_lifetime, type: :integer, default: 86400 # 24 hours in seconds
    field :browser_session_remember_me_lifetime, type: :integer, default: 2592000 # 30 days in seconds
    field :device_session_lifetime, type: :integer, default: 2592000 # 30 days in seconds
    field :service_session_lifetime, type: :integer, default: 7776000 # 90 days in seconds

    # Opt IN to BCrypt for the session token digest, at this cost factor.
    #
    # Default `nil` means HMAC-SHA256 under `secret_key_base`, which is the
    # right primitive here: session tokens are 256-bit random
    # (`SecureRandom.urlsafe_base64(32)`), and BCrypt's cost factor exists to
    # slow brute-force of LOW-entropy secrets. Against a token that cannot be
    # guessed at any hash speed the stretching bought nothing, while costing a
    # measured ~181 ms of CPU on every authenticated API request at cost 12 —
    # note this is paid per REQUEST, not merely per session creation.
    #
    # Set it only if you specifically want hash work on this path anyway. When
    # set, the value is clamped to BCrypt::Engine::MIN_COST..MAX_COST.
    #
    # Changing it is always safe and never strands a session:
    # Session#authenticate_token reads the scheme off the stored digest (BCrypt
    # digests are self-identifying by their `$2<x>$` prefix), so both schemes
    # verify side by side and existing rows are never rewritten. As before, a
    # change applies only to newly-created sessions.
    field :token_digest_cost, type: :integer, default: nil

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
    # List of audience values that tokens issued and accepted by this app may
    # carry in their `aud` claim. When non-empty, the API token manager passes
    # this list to `JwtService.decode(..., allowed_audiences:)` so that tokens
    # with a mismatched `aud` are rejected at decode time — closing the
    # cross-audience replay vector on the API path, independent of whether
    # individual controllers remember to
    # `include StandardId::AudienceVerification`. The Web token manager is
    # intentionally not wired through yet; that's a follow-up.
    # Empty (default) = no global audience validation; behavior matches
    # pre-threading releases. Production deployments should set this
    # explicitly (e.g., `%w[web api]`).
    field :allowed_audiences, type: :array, default: -> { [] }

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

    # RFC 7591 Dynamic Client Registration.
    #
    # When false (the default), the registration endpoint is fully absent
    # (`POST /oauth/register` returns 404) and `registration_endpoint` is NOT
    # advertised in the discovery documents. An open, unauthenticated
    # registration endpoint is state-mutating attack surface (anyone can mint
    # OAuth clients), so it is opt-in: a deployment must explicitly turn it on.
    field :dynamic_registration_enabled, type: :boolean, default: false

    # Enable the RFC 7662 token introspection endpoint (POST /oauth/introspect).
    #
    # When false (the default), the endpoint is fully absent (404) and
    # `introspection_endpoint` is NOT advertised in the discovery documents. An
    # endpoint that answers questions about other people's tokens is not something
    # to expose by accident, so it is opt-in — same posture as
    # `dynamic_registration_enabled`.
    #
    # Confidential clients only: the caller authenticates with client_id +
    # client_secret (HTTP Basic or form body). Every failure renders
    # `{"active": false}` with no other members, per RFC 7662 §2.2.
    #
    # KNOW THE LIMIT BEFORE BUILDING ON IT: access tokens are stateless — never
    # persisted, and carrying no `sid` — so a revoked session's access token
    # introspects as `active: true` until its `exp`. Introspection answers "did we
    # mint this, and is it unexpired?", NOT "is it still honoured?". Keep
    # `access_token_lifetime` short. Refresh tokens ARE persisted and are checked
    # against the row, so a revoked refresh token introspects as inactive
    # immediately.
    field :introspection_enabled, type: :boolean, default: false

    # Where the discovery documents say the ENDPOINTS live.
    #
    # The issuer and the endpoint base are different things. The issuer is a
    # stable security identifier (RFC 8414 §2) that clients match byte-for-byte
    # against their discovery URL and against the `iss` claim; it is never
    # derived from the request and cannot be overridden. This says where
    # /authorize, /oauth/token etc. actually are.
    #
    #   nil (default) — the issuer. Byte-identical to the behaviour before this
    #                   option existed. Already correct if your issuer carries
    #                   the ApiEngine mount path (e.g. "https://host/auth/api").
    #                   WRONG if it does not: the document then advertises
    #                   endpoints at the bare origin, which 404.
    #   :request      — request.base_url + the detected mount path. What you want
    #                   when ApiEngine is mounted under a prefix ("/api",
    #                   "/api/v1") the issuer does not carry.
    #   "https://..." — used verbatim.
    #   callable      — receives (request:). Use when a proxy rewrites
    #                   request.base_url, or when ApiEngine is mounted more than
    #                   once (e.g. under host constraints) so no single detected
    #                   path is right.
    #
    # Request-derived is opt-in rather than the default on purpose: defaulting to
    # it would silently rewrite the document of every app whose issuer host
    # differs from the host serving the request — the split-host setup a separate
    # issuer exists to express.
    field :discovery_endpoint_base, type: :any, default: nil

    # Members of the discovery documents that cannot be derived, as
    # `{ member => value }`. Values may be static or callable.
    #
    # A callable receives one Hash — `{ origin:, endpoint_base:, issuer:,
    # request: }`, where `origin` is scheme+host+port with no path.
    #
    # A `nil` value REMOVES the member rather than emitting null.
    #
    # Setting `issuer` RAISES — see discovery_endpoint_base above.
    #
    #   c.oauth.discovery_metadata_overrides = {
    #     # a host-owned shim that injects the audience before handing off to the
    #     # engine's /authorize
    #     authorization_endpoint: ->(ctx) { "#{ctx[:origin]}/oauth/authorize" },
    #     # deliberately narrower than everything the server can mint
    #     scopes_supported: %w[mcp mcp:read],
    #     # MUST mirror your dynamic-registration policy: advertising
    #     # client_secret_* while DCR only accepts public clients makes
    #     # spec-following clients register in a way DCR then rejects
    #     token_endpoint_auth_methods_supported: %w[none],
    #     # omit a member entirely
    #     grant_types_supported: nil
    #   }
    field :discovery_metadata_overrides, type: :hash, default: -> { {} }

    # Callable resolving the polymorphic owner assigned to clients created via
    # Dynamic Client Registration (the `owner` association on ClientApplication
    # is required). Example: `-> { Organization.default }`.
    #
    # When `dynamic_registration_enabled` is true but this resolver is nil (or
    # returns nil), registration raises a clear configuration error rather than
    # silently failing the model's presence validation — so misconfiguration is
    # caught loudly at request time.
    field :dynamic_registration_owner, type: :any, default: nil

    # Default `token_endpoint_auth_method` applied to clients created via RFC 7591
    # Dynamic Client Registration when the request omits `token_endpoint_auth_method`.
    #
    # Controls whether self-registered clients default to PUBLIC (PKCE-only, no
    # secret) or to a CONFIDENTIAL secret-bearing method. The default `"none"`
    # preserves the historical behaviour (DCR clients are public unless they ask
    # for a secret) and is the right default for interactive/native/MCP clients,
    # which cannot keep a secret.
    #
    # Valid values (validated at use in StandardId::Oauth::ClientRegistration):
    #   "none"                — public client, authenticates via PKCE alone
    #   "client_secret_basic" — confidential, secret via HTTP Basic
    #   "client_secret_post"  — confidential, secret in the request body
    field :dynamic_registration_default_auth_method, type: :string, default: "none"

    # RFC 6749 §4.1.3 strictness at the token endpoint.
    #
    # The spec is unambiguous: if `redirect_uri` was included in the
    # authorization request, the client MUST send it again at the token
    # endpoint and the two values MUST be identical. Historically this engine
    # only compared the values when the client bothered to send one, so a
    # client could silently skip the check by omitting the parameter.
    #
    # When true, redeeming a code that was minted WITH a redirect_uri fails
    # with invalid_grant unless the token request repeats the identical value.
    # Codes minted WITHOUT a redirect_uri are unaffected either way.
    #
    # Default is false — the historical, lenient behaviour — because flipping
    # it silently would break any live client that omits the parameter, and
    # this gem is consumed by several production apps. In lenient mode the
    # engine logs a warning naming the client_id every time a code with a
    # stored redirect_uri is redeemed without one, so deployments can confirm
    # no client relies on the leniency before opting in. Set it to true.
    field :strict_redirect_uri_matching, type: :boolean, default: false

    # Blast radius of POST /oauth/revoke (RFC 7009).
    #
    #   :account (default) — revoke every active DeviceSession belonging to the
    #     token's `sub`, regardless of which token was presented. Historical
    #     behaviour. Fail-safe (it over-revokes) but it means a single client's
    #     logout signs the account out on every device.
    #
    #   :grant — revoke only the authorization grant the presented token
    #     belongs to: the refresh-token family the token's `jti` resolves to,
    #     plus that refresh token's Session when one is linked. A presented
    #     ACCESS token resolves to no stored artifact (access tokens are
    #     stateless JWTs this engine cannot individually invalidate), so in
    #     :grant mode revoking an access token is a no-op returning 200 per
    #     RFC 7009 §2.2 — clients that want revocation to bite must present
    #     the refresh token.
    #
    # An unrecognised value logs a warning and falls back to :account.
    field :revocation_scope, type: :symbol, default: :account
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
    # RAR-51: Login rate limits.
    #
    # Mechanism-agnostic aliases. The `rate_limit` macro that consumes these
    # sits on Web::LoginController#create, which branches password OR
    # passwordless — so on a passwordless app these govern the OTP-SEND limit,
    # not a password login. Prefer these names for new config.
    field :login_per_ip, type: :integer, default: 20                 # per 15 minutes
    field :login_per_email, type: :integer, default: 5               # per 15 minutes

    # Deprecated mechanism-specific names, retained for backwards compatibility.
    # The schema raises ConfigurationError on unknown fields at boot, so these
    # must NOT be removed while hosts still set them. When a host leaves the
    # `login_per_*` alias at its default, the login controller falls back to
    # these values (see StandardId::RateLimitHandling.login_per_ip). New name
    # wins when explicitly set. Mirrors the max_attempts ->
    # max_attempts_per_challenge deprecation-alias precedent.
    field :password_login_per_ip, type: :integer, default: 20        # per 15 minutes; deprecated alias of login_per_ip
    field :password_login_per_email, type: :integer, default: 5      # per 15 minutes; deprecated alias of login_per_email

    # RAR-60: OTP verification
    field :otp_verify_per_ip, type: :integer, default: 20            # per 15 minutes

    # RAR-56: Email/phone verification code generation
    field :verification_start_per_target, type: :integer, default: 3 # per 15 minutes
    field :verification_start_per_ip, type: :integer, default: 10    # per hour

    # Password-reset request. The start endpoint emails a reset token, so an
    # unthrottled endpoint is an email-flooding + account-enumeration vector.
    # Mirrors the verification_start shape (per-IP hourly + per-target 15-min).
    field :password_reset_start_per_ip, type: :integer, default: 10      # per hour
    field :password_reset_start_per_target, type: :integer, default: 3   # per 15 minutes

    # Password signup — throttle account-creation spam by IP.
    field :signup_per_ip, type: :integer, default: 10                    # per hour

    # API OTP-initiation limits — the API counterpart of the web *login* limits
    # (login_per_* / the deprecated password_login_*): the API passwordless
    # `start` action and the web login action both drive the passwordless
    # `start!` strategy. NOT the counterpart of verification_start_*
    # (email/phone verification), which bypasses the strategy via a direct
    # CodeChallenge.create!.
    field :api_passwordless_start_per_ip, type: :integer, default: 10    # per hour
    field :api_passwordless_start_per_target, type: :integer, default: 5 # per 15 minutes

    # OAuth token endpoint — requests per IP.
    field :api_token_per_ip, type: :integer, default: 30                 # per 15 minutes

    # Optional per-audience tightening on top of the api_token_per_ip
    # ceiling. A Hash of audience => max token requests per IP per 15
    # minutes, e.g. `{ "mobile_app" => 10, "partner_api" => 30 }`. Only
    # requests targeting a configured audience count toward that audience's
    # limit; audiences without an entry are governed solely by the global
    # api_token_per_ip ceiling. A request must pass both its audience cap
    # and the global cap.
    field :api_token_per_audience_per_ip, type: :hash, default: -> { {} }

    # Dynamic client registration (RFC 7591) — throttle the open registration
    # endpoint by IP so an enabled deployment can't be flooded with client rows.
    field :dynamic_registration_per_ip, type: :integer, default: 10      # per hour

    # Token introspection (RFC 7662) — throttle by IP so the endpoint cannot be
    # used to bulk-classify stolen tokens. Note the limit renders the ordinary
    # `{"active": false}` / 200 rather than 429: a 429 would distinguish
    # "throttled" from "token invalid" and turn the limiter into a token-validity
    # oracle.
    field :introspection_per_ip, type: :integer, default: 30              # per 15 minutes
  end
end
