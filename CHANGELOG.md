# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.24.0] - 2026-06-13

### Added

- **Public-client (PKCE) support at `POST /oauth/token` for the
  `authorization_code` grant.** Public clients (native/SPA/MCP clients per
  RFC 8252 / OAuth 2.1) can now exchange an authorization code for tokens
  using PKCE alone, with no `client_secret`. Confidential clients still
  authenticate with a secret exactly as before (regression-safe). The flow
  looks up the `ClientApplication` by `client_id`, validates a secret only
  for confidential clients, rejects a public client that sends a
  `client_secret` (`invalid_client`), and **fails closed** when a public
  client's authorization code carries no `code_challenge` — PKCE is the
  client's only authentication factor, so a code minted without one is
  rejected with `invalid_grant`. `"none"` is now advertised in
  `token_endpoint_auth_methods_supported` in both discovery documents.
- **`oauth.dynamic_registration_default_auth_method` config** (default
  `"none"`). Controls the `token_endpoint_auth_method` applied to clients
  created via RFC 7591 Dynamic Client Registration when the request omits
  one — i.e. whether self-registered clients default to public (PKCE-only)
  or confidential (secret-bearing). Validated at use against
  `none` / `client_secret_basic` / `client_secret_post`; an out-of-range
  value raises `ConfigurationError`. Default preserves existing behaviour.

### Fixed

- **Consent screen now completes for Inertia-rendered hosts.** When a host
  renders the OAuth consent screen via Inertia (`use_inertia`), the
  approve/deny decision arrives as an Inertia XHR, which cannot follow a 302
  to the external client `redirect_uri` — the browser would hang on the
  consent screen. `ConsentController` now emits an Inertia-Location
  (`409` + `X-Inertia-Location`) for Inertia requests so the client performs a
  hard navigation to the callback, while plain (ERB) form posts keep the
  ordinary redirect. No effect on non-Inertia hosts.

## [0.23.0] - 2026-06-12

### Added

- **Per-audience rate limits at `POST /oauth/token`** — new
  `rate_limits.api_token_per_audience_per_ip` config (Hash of
  audience => max requests per IP per 15 minutes, default `{}`). Lets hosts
  tighten the cap for higher-risk audiences (e.g. a public mobile app) while
  internal/partner audiences keep the global `api_token_per_ip` ceiling. A
  request must pass both its audience cap and the global cap. Implemented as
  an explicit `before_action` counter rather than the Rails `rate_limit`
  DSL: the DSL counts every request reaching the action, and a `by:` block
  returning `nil` does not exempt a request — it collapses into a shared
  bucket keyed without the discriminator, so one audience's rule would
  throttle every other audience's traffic. Only requests that actually
  target a configured audience increment that audience's per-IP counter.
  Exceeding the cap renders the standard `rate_limit_exceeded` JSON error
  with `Retry-After`.

### Fixed

- **`SOCIAL_AUTH_FAILED` is now emitted on the API (mobile) callback path
  too.** Since 0.16.0 the event fired only from the web callback
  (`Web::Auth::Callback::ProvidersController`); on
  `POST /api/oauth/callback/:provider` an infrastructure-level provider
  failure (`StandardId::OAuthError` from the provider call) fell through to
  the standard `handle_oauth_error` JSON response without emitting, so host
  apps observing provider outages via the event were blind on the API flow
  (and had to monkey-patch `get_user_info_from_provider` to compensate).
  The rescue is scoped to the provider call: `OAuthError` subclasses raised
  later in the flow (`SocialLinkError`, `InvalidRequestError`, ...) are
  policy/client errors and still do not emit. The JSON error response is
  unchanged.

## [0.22.0] - 2026-06-11

### Added

- **RFC 7591 Dynamic Client Registration** behind a default-off toggle. New
  endpoint `POST /oauth/register`
  (`Api::Oauth::RegistrationsController` -> `StandardId::Oauth::ClientRegistration`)
  lets clients self-register OAuth client applications.
  - **Rate limited.** Throttled by IP via
    `rate_limits.dynamic_registration_per_ip` (default 10/hour) so an enabled
    deployment can't be flooded with client rows.
  - **Default off.** Gated on `oauth.dynamic_registration_enabled` (default
    `false`). While off, the endpoint returns **404** (fully absent, not just a
    guarded 403) and the discovery documents do **not** advertise a
    `registration_endpoint`. An open, unauthenticated registration endpoint is
    state-mutating attack surface, so it is strictly opt-in.
  - **Owner resolver.** When enabled, set
    `oauth.dynamic_registration_owner` to a callable resolving the polymorphic
    owner for registered clients (e.g. `-> { Organization.default }`). If the
    toggle is on but the resolver is nil/returns nil, registration raises a
    clear `StandardId::ConfigurationError` rather than silently failing model
    validation.
  - **Metadata -> ClientApplication mapping** (RFC 7591 §2): `redirect_uris`
    (REQUIRED — empty/invalid yields `invalid_redirect_uri`), `client_name` ->
    `name` (a name is generated when absent), `scope` (default
    `"openid profile email"`). `grant_types` is whitelisted to
    `authorization_code`/`refresh_token` and `response_types` to `code` (others
    rejected as `invalid_client_metadata`). `token_endpoint_auth_method` `none`
    -> **public** client; `client_secret_basic`/`client_secret_post` ->
    **confidential** (a one-time `client_secret` is generated and returned with
    `client_secret_expires_at: 0`). Default auth method is `none` (public).
  - **Forced security defaults.** All registered clients are forced onto
    `require_pkce: true` + `code_challenge_methods: "S256"` (the model also
    validates this for public clients). Registered clients default to
    `require_consent: true` — they get the HTML consent screen shipped in
    0.21.0 rather than the old `require_consent: false` workaround.
  - **Discovery advertisement.** Both `/.well-known/openid-configuration` and
    `/.well-known/oauth-authorization-server` advertise
    `registration_endpoint` **only when** `oauth.dynamic_registration_enabled`
    is true (the flag is now read from config and passed into
    `DiscoveryDocument.build`).
  - Responses follow RFC 7591 §3.2.1 (HTTP 201) on success and §3.2.2 (HTTP
    400, `invalid_redirect_uri` / `invalid_client_metadata`) on error. No
    migration required — all `ClientApplication` columns already exist.

## [0.21.1] - 2026-06-11

### Fixed

- **ERB login view now respects the `web.signup` and `web.password_reset`
  toggles.** The packaged login view rendered an unconditional "Sign up" link
  (both the passwordless and password branches) and a "Forgot password?" link
  (password branch), so an app with `web.signup = false` or
  `web.password_reset = false` showed links to routes that 404. The links are
  now gated on their respective toggles. No effect on apps that leave the
  toggles at their defaults.

## [0.21.0] - 2026-06-11

### Added

- **RFC 8414 OAuth 2.0 Authorization Server Metadata** — new endpoint
  `/.well-known/oauth-authorization-server` (`Api::WellKnown::OauthAuthorizationServerController`),
  serving the same document as `/.well-known/openid-configuration`. Both
  controllers now render a single shared builder,
  `StandardId::Oauth::DiscoveryDocument.build(issuer, registration_enabled: false)`,
  so the OIDC and OAuth metadata documents cannot drift.
  - **Mount caveat:** the ApiEngine is consumer-mounted at a sub-path (e.g.
    `/auth/api`), so the gem can only serve this at
    `/auth/api/.well-known/oauth-authorization-server`. A strict RFC 8414 client
    that derives a *root-anchored* URL from a path-carrying issuer
    (`<host>/.well-known/oauth-authorization-server/auth/api`) lands outside any
    engine mount; hosts needing the root-anchored form must add their own root
    route — the gem cannot. The `registration_endpoint` is intentionally NOT
    emitted yet; the `registration_enabled:` kwarg is a seam for Phase 2 (DCR).
- **PKCE advertisement** — both discovery documents now advertise
  `code_challenge_methods_supported: ["S256"]` (always on; PKCE is always
  enforced).
- **HTML consent view for the authorization-code flow** — an authenticated,
  interactive (HTML) `/authorize` for a client with `require_consent` enabled
  and no prior grant is now handed off to a new WebEngine consent screen
  (`GET/POST /consent`, asset-free ERB; Inertia consumers receive props for
  their own component) instead of dead-ending. On approve, a `ClientGrant` is
  recorded and the authorization code is issued by re-running the same
  authorization-code flow (so `redirect_uri` and PKCE are revalidated, not
  duplicated); on deny, the user is redirected back with `error=access_denied`
  (+ `state`). Repeat authorizations with a matching grant skip consent. The
  API authorize endpoint carries the original `/authorize` params to the
  consent screen through a signed, expiring payload
  (`StandardId::Oauth::ConsentPayload`, mirroring the OTP `message_verifier`
  pattern). New table `standard_id_client_grants` (one row per account+client).
  JSON / non-interactive / implicit / social-login flows are unaffected.

### Changed

- **`audience` is now OPTIONAL at the authorization-code `/authorize`** — moved
  from `expect_params` to `permit_params` in
  `AuthorizationCodeAuthorizationFlow`. Token-time validation already no-ops on a
  blank audience (or when no `allowed_audiences` are configured), so omitting it
  is safe and lets standards-compliant clients (e.g. MCP) authorize without it.
  `client_credentials` still REQUIRES `audience` (unchanged). This is a
  relaxation, not a break.
- **Passwordless-aware ERB login view** — the gem's ERB login view now selects
  its form using the same passwordless-first precedence the controller's
  `#create` uses: passwordless-only renders an asset-free email-only form (no
  external `tailwindcss.com` logo, no Tailwind-utility dependence, so it renders
  under a minimal element-CSS layout); password mode renders the existing form
  unchanged (password consumers are unaffected); neither-enabled renders a "No
  login method is enabled" message instead of a 500. Social login still renders
  in both modes when configured.

### Migration notes

- Run the new `CreateStandardIdClientGrants` migration (adds
  `standard_id_client_grants`). No existing columns change.

## [0.20.1] - 2026-05-24

### Added

- **`after_sign_in` hook context now includes `:redirect_uri`** — the caller-supplied destination (from the form param for password/signup flows, from the OAuth state cookie for social flows, from `session[:return_to_after_authenticating]` for passwordless OTP). Host hooks that always return a default path (e.g. `PostLoginRedirect.new(account).path`) silently shadowed the caller's `redirect_uri` because `redirect_override` wins in the destination chain. Hooks can now return `nil` when `context[:redirect_uri]` is present so the originator's URL is honoured — required for OAuth/SSO flows where the host bounces through `/login?redirect_uri=/oauth/authorize?…` and expects the handshake to complete back to the originating consumer (e.g. external API clients hitting `/api/v1/authorize`).
- **All four sign-in flows now forward the caller's redirect_uri into the hook context**: password login, signup, social callback, AND passwordless OTP verify (`web/login_verify_controller.rb`). Previously only the first three were covered; passwordless users initiating OAuth from a consumer landed on the host default page.

### Fixed

- **Cancel-at-provider preserves `redirect_uri`** — `handle_callback_error` (provider returns `?error=access_denied`) now extracts the state and forwards `redirect_uri` to `login_path`, symmetric with the `SocialLinkError`/`OAuthError` rescue paths. Previously a user who cancelled at the provider lost the OAuth handshake context entirely.
- **Open-redirect / 500 mitigation in social callback** — when the host hook defers (returns nil), the social callback validates the originator-supplied destination via `safe_destination?` (same-origin paths or `allowed_redirect_url_prefixes` matches only; rejects protocol-relative and arbitrary cross-host URLs). On failure, falls back to `/` instead of feeding the unsafe value into `redirect_to`. Closes a class of phishing vectors that opened when host hooks started deferring instead of always returning an internal path.
- **`params[:redirect_uri]` Array/Hash type safety** — login, signup, login_verify, and logout controllers now use a `string_param` helper that returns nil for non-String shapes (e.g. `redirect_uri[]=a&redirect_uri[]=b`), preventing a self-DoS 500 from `redirect_to <Array>`. Covers all `params[:redirect_uri]` read sites: form re-renders (`show`/error branches), session writes (`handle_passwordless_login`), state encoding (`signup_controller#encode_state`), and direct redirects (`logout`). Also normalizes empty-string values via `.presence` consistently across the context and destination chain.
- **Open-redirect validation extended to password, signup, logout, AND passwordless verify** — `safe_destination?` and `safe_post_signin_default` are now promoted to `Web::BaseController` and applied to the destination chain for password login, password signup, logout, and passwordless OTP verify (was previously social callback only). `safe_destination?` accepts same-origin absolute URLs (compares against `request.base_url`) so legitimate `store_location_for_redirect` round-trips still work. Cross-host URLs not in `allowed_redirect_url_prefixes`, protocol-relative URLs (`//evil.com/`), and same-origin-looking-but-cross-host URLs (e.g. `http://evil.com:80/`) fall back to `after_authentication_url` / `safe_post_signin_default` instead of redirecting to an attacker-controlled target. Closes a residual open-redirect in passwordless verify where a malicious String redirect_uri passed `string_param` (which only blocks Array/Hash) and got stashed in `session[:return_to_after_authenticating]`, then served unfiltered.
- **Scope-level `after_sign_in_path` no longer shadows caller's redirect_uri** — when the host hook returns nil AND `context[:redirect_uri]` is present, `LifecycleHooks#invoke_after_sign_in` now returns nil (the documented "defer to originator" signal) instead of `scope_config&.after_sign_in_path`. Hosts that configure both a scope path AND OAuth/SSO flows previously had the scope path silently win and break the handshake.
- **Defensive nil-guard on `state_data['redirect_uri']`** in the social callback — uses `state_data&.dig("redirect_uri").presence` consistent with the rescue paths.

## [0.20.0] - 2026-05-21

### Changed (BREAKING — behavior)

- **OAuth token grants now fail closed when the requested audience has a configured profile binding but the account has no matching active profile.** Previously, `TokenGrantFlow` only validated `aud ∈ allowed_audiences`; if `c.oauth.audience_profile_types[aud]` was set but the account lacked a matching profile, the mint silently succeeded with profile-derived claims (e.g. `gid`) resolving to `nil`. The new behavior raises `StandardId::NoBoundProfileError` (a subclass of `InvalidGrantError`), which the standard OAuth error handler renders as RFC 6749 `invalid_grant` (HTTP 400). Decode-time enforcement via `AudienceVerification` is unchanged.
- **`AudienceProfileResolver` now exposes a strict `.resolve!(account:, audience:)` method** used by `TokenGrantFlow`. It returns the uniquely matching active profile, or raises `NoBoundProfileError` (no match) / `AmbiguousProfileError` (multiple matches). The legacy `.call(account:, audience:)` is unchanged — it still returns the "first active else first match" profile and is used by the decode-time `AudienceVerification` concern, where back-compat tolerance is intentional.

### Added

- `StandardId::NoBoundProfileError` and `StandardId::AmbiguousProfileError` — both subclass `InvalidGrantError` so existing OAuth error handlers map them to `invalid_grant`. Exposed readers (`audience`, `expected_profile_types`, `profile_ids`) are for audit logging only; do **not** interpolate them into client-facing responses.
- **`OAUTH_TOKEN_ISSUED` event payload now includes** `profile_id`, `audience`, `jti`, and `requested_scopes` (in addition to the existing `grant_type`, `client_id`, `account`, `expires_in`). Without these, downstream subscribers (SIEM, audit log, anomaly detection) could not correlate a successful mint to the entity it authorized, the resource server it targeted, the specific token for revocation, or the scopes the client requested. Existing subscribers are unaffected — payload additions are backward-compatible.
- `claim_resolvers_context` now exposes the pre-resolved `profile` (when a binding matched), so host-app claim resolvers can use it directly via keyword filtering instead of re-querying.

### Migration notes

Host apps with **multiple active profiles of the same type for a single account** will see previously-silent mints now fail with `AmbiguousProfileError`. Two options:

1. **Recommended:** Treat duplicates as a data-integrity bug and deactivate the superfluous profiles. The previous "pick the first arbitrary active match" behavior was non-deterministic across reloads and unsafe to rely on.
2. **Temporary:** Configure a custom `c.oauth.audience_profile_resolver` callable that applies your own selection rule. The strict path delegates to it when set.

An explicit per-grant `profile_id` parameter is intentionally out of scope for this release; the grant-parameter contract for profile selection will be designed separately once host apps have migrated off duplicate profiles.

## [0.19.0] - 2026-05-19

### Added

- **`Api::Oauth::Callback::ProvidersController` now forwards non-OAuth request params** to `SOCIAL_AUTH_COMPLETED` subscribers as `original_request_params`. Previously the API (mobile) flow always passed an empty hash, blocking host-app attribution tracking for mobile signups. Reserved OAuth/Rails keys (`id_token`, `code`, `scope`, `scopes`, `audience`, `redirect_uri`, `flow`, `state`, `nonce`, `provider`, `controller`, `action`, `format`, `authenticity_token`, `utf8`, `_method`) are stripped; everything else is treated as opaque host-supplied data and forwarded through. Mirrors the web flow's existing `state_data` pass-through contract.

## [0.18.0] - 2026-05-19

### Changed

- Relaxed `jwt` dependency constraint from `~> 2.7` to `>= 2.7, < 4`, allowing consumers to satisfy the GHSA security advisory for `jwt` 2.x by upgrading to `jwt` 3.x. Existing 2.x users are unaffected. Consuming apps that bump to `jwt` 3.x should verify their own JWT encode/decode call sites against the [jwt 3.0 release notes](https://github.com/jwt/ruby-jwt/blob/main/CHANGELOG.md) — `JWT.encode` / `JWT.decode` calls inside `StandardId::JwtService` already pass an explicit algorithm and are 3.x-compatible.

## [0.17.1] - 2026-05-07

### Fixed

- **`Otp.issue(delivery: :manual)` no longer double-delivers when `c.passwordless.delivery == :built_in`.** Previously, `BaseStrategy#start!` emitted `PASSWORDLESS_CODE_GENERATED` unconditionally and `PasswordlessDeliverySubscriber` gated only on the global delivery config — so callers who passed `delivery: :manual` and delivered the code themselves (custom widget/verification/step-up flows) silently received a duplicate email from the bundled mailer on top of their own. `skip_sender` is now forwarded into the event payload, and the subscriber short-circuits when it sees the flag. Manual callers get exactly one delivery again, in line with the documented contract for `:manual`. (#206)

## [0.17.0] - 2026-04-29

### Changed

- Release workflow migrated to the shared `rarebit-one/.github` reusable workflow (`reusable-gem-release.yml@v1`); `.github/workflows/release.yml` is now a thin shim. CI workflow remains bespoke pending unrelated open PRs that touch it.
- **Widened Rails constraint to `>= 8.0`** — gemspec now allows Rails 9+ when available. Aligns with the org-wide policy of supporting Rails 8 and up with no upper bound.
- Replaced the vendored `StandardConfig` schema/manager (~430 LOC across `lib/standard_config/`) with `ActiveSupport::OrderedOptions` plus a small internal `StandardId::ConfigSchema` helper (~200 LOC). No public API change for consumers using `StandardId.configure { |c| ... }` or `StandardId.config.foo`. The top-level `StandardConfig` constant has been removed — it was internal-only and shipped under standard_id's lib path, but its name implied a separate gem and risked namespace collisions.

### Added

- **Rails edge CI canary** — a non-blocking `test (rails-edge)` job runs the spec suite against `rails/rails@main` on every PR. Failures surface upstream breakage during development rather than at a host app's `bundle update` after a Rails 9 release. Allowed to fail (`continue-on-error: true`) so it never blocks merges.

### Fixed

- **Weekly maintenance concurrency guard** — added a `concurrency:` block to `weekly-maintenance.yml` so a manual `workflow_dispatch` during an in-flight scheduled run no longer spawns a parallel job. `cancel-in-progress: false` lets the running job finish rather than orphan a half-open PR. Follow-up to #199.

### Removed

- **BREAKING:** Dropped support for Ruby < 4.0. `required_ruby_version` is now `>= 4.0`. Hosts must upgrade to Ruby 4.0+ before bundling this version. CI tests all four published 4.0.x patches.

## [0.16.1] - 2026-04-19

### Performance

- **API authentication guard reuses `session_manager.current_account`** — `Api::AuthenticationGuard` previously ran its own `find_by(id: api_session.account_id)` twice per bearer-authenticated request (once each for `SESSION_VALIDATED` and `SESSION_EXPIRED`), on top of the session_manager's already-memoized `current_account`. The guard now threads `session_manager` through to the event emitters and delegates account resolution to it. Eliminates 1-2 redundant queries per API request. (#188)
- **`RefreshToken#revoke_family!` uses a recursive CTE** — family chain traversal was a Ruby loop doing `.pluck(:id)` per generation (O(depth) queries). Now a single recursive CTE collects every ancestor and descendant in one round trip. `UNION` (not `UNION ALL`) deduplicates against the full accumulator to prevent infinite loops on cyclic data. Supported by PostgreSQL, SQLite 3.8+, and MySQL 8+. (#188)
- **`Api::SessionsController#serialize_session` drops redundant `respond_to?` guards** — all `Session` subclasses share the STI table, so per-field `respond_to?` checks were defensive overhead with no missing method to defend against. Direct column access is both cheaper and clearer. (#188)

### Added

- **`config.session.token_digest_cost`** — opt-in BCrypt cost factor for session `token_digest`. Default `nil` preserves current behavior (bcrypt-ruby's built-in default — cost 12 in production). Since session tokens are 256-bit random (`SecureRandom.urlsafe_base64(32)`), any cost `>= 10` is well beyond brute-force, and setting `10` saves ~200ms of CPU per session creation. Clamped to `BCrypt::Engine::MIN_COST..MAX_COST`. (#188)
- **Current request details mirrored into `Rails.event` context** — host apps observing structured logs/events see the same `request_id`, `remote_ip`, and `user_agent` values that StandardId records on sessions, without needing to duplicate the wiring. (#187)

## [0.16.0] - 2026-04-19

### Security

- **OTP verification race-condition fix and per-challenge brute-force defenses** — `VerificationService.verify` now wraps the challenge lookup, failed-attempt increment, and consumption in a single `SELECT ... FOR UPDATE` transaction, closing the TOCTOU window between "find active challenge" and "mark it used." Failed-attempt counting is now atomic and scoped to the specific challenge (previously a loose read-modify-write on the account). Events are deferred to post-commit so observers never see rolled-back state. New `config.passwordless.max_attempts_per_challenge` (default `5`) supersedes the now-deprecated account-wide `max_attempts` (kept as a fallback for existing installs). (#169)
- **JWT audience enforcement at decode time** — `JwtService.decode` now accepts an `allowed_audiences:` kwarg and raises `StandardId::InvalidAudienceError` on mismatch. `Api::TokenManager#verify_jwt_token` threads `config.oauth.allowed_audiences` through automatically, so cross-audience JWT replay is now blocked even on controllers that forget to include the `AudienceVerification` concern. Production emits a warning when `allowed_audiences` is unset. (#170, #174)
- **Web flow polish** — password-reset delivery moved to an async job with a constant-time success response (closes enumeration timing leak); OAuth `redirect_uri` validation tightened to exact scheme+host+port+path match at both registration and authorize time (blocks query-string piggyback); engine logs a warning when the host app has no `secret_key_base` configured so encrypted session cookies can't silently fall back to plaintext. New `reset_password` config scope with `:delivery` (`:custom` default, `:built_in` opt-in) and mailer-sender/subject knobs. `CREDENTIAL_PASSWORD_RESET_INITIATED` event now fires from the job. (#171)
- **Per-client PKCE enforcement at the authorize endpoint** — honors the existing `require_pkce` column on `ClientApplication`. Requests missing `code_challenge` are rejected with `invalid_request` when the client requires PKCE. Per-client `code_challenge_methods` replaces the global S256-only hardcode (case-insensitive). New validation blocks public clients from opting out (`public_clients_must_require_pkce`). (#175)
- **Hardened GitHub Actions workflows** — minimal `permissions:` blocks added to every workflow; third-party actions pinned to commit SHAs. (#185)

### Added

- **Typed identifier accessors on `AccountAssociations`** — `account.email_identifier`, `account.phone_number_identifier`, `account.username_identifier` replace the manual `identifiers.detect { |i| i.type == "…" }` pattern used by consuming apps. Uses loaded-association detection to stay N+1-safe. (#180)
- **`SOCIAL_AUTH_FAILED` event** — emitted when social provider callbacks catch `StandardId::OAuthError` from an infrastructure failure (DNS, SSL, timeout). Policy/link errors (`SocialLinkError`) emit their existing `SOCIAL_LINK_BLOCKED` event instead. Enables host apps to observe provider outages without monkey-patching. (#180)
- **Idempotent event subscriptions** in `AccountStatus` / `AccountLocking` — guarded with a module-level flag so re-including a concern (e.g., Rails reload) no longer accumulates duplicate subscribers. (#180)
- **Errors module eager-loaded from all engines** — `StandardId::SocialLinkError` and the full error hierarchy are available at engine load time, so `rescue_from StandardId::SocialLinkError` at controller class-body time resolves as a constant instead of needing a string literal. (#180)
- **`bin/dev`** — dummy-app boot script for contributors; provisions the SQLite dev DB via `rake app:db:setup` if absent and execs `spec/dummy/Procfile.dev` through overmind/hivemind/foreman. (#173)
- **Boot-time config validators** — new `StandardId::Config::CallableValidator` and `StandardId::Config::ScopeClaimsValidator` raise `StandardId::ConfigurationError` at engine `after_initialize` if lifecycle callables have wrong arity or if `scope_claims` entries reference claims without a matching resolver. Surfaces typos at deploy time instead of at callback time. (#173)
- **Cleanup rake tasks** — `standard_id:cleanup:{sessions,refresh_tokens,authorization_codes,code_challenges,all}` honoring `GRACE_DAYS` env var, plus `docs/OPERATIONS.md` with scheduling examples for SolidQueue recurring, sidekiq-cron, whenever, and cron. (#173)

### Performance

- **`first_sign_in?` uses `.exists?` instead of `.count`** on the `LifecycleHooks` hot path — removes a full count on every login. (#172)
- **Bulk session revocation uses `update_all`** in `Api::OAuth::RevocationsController` — one SQL UPDATE instead of O(N) per-row UPDATEs across sessions + cascaded refresh_tokens. `SESSION_REVOKED` event emission preserved per-session. (#172)
- **Partial indexes on hot active-row lookups** — `standard_id_sessions(expires_at) WHERE revoked_at IS NULL`, same for `refresh_tokens`, and `code_challenges(realm, channel, target, created_at) WHERE used_at IS NULL`. Dropped the unused Postgres GIN index on `code_challenges.metadata`. Migration uses `algorithm: :concurrently` with `disable_ddl_transaction!` on Postgres. (#172)
- **Isolate `SESSION_REVOKED` subscriber failures during bulk revoke** — a failing subscriber no longer aborts the revocation loop. (#172)

### Deprecated

- **`config.passwordless.max_attempts`** — use `max_attempts_per_challenge` instead. The old key is still read as a fallback when the new one is unset, so existing installs keep working. Planned for removal in 2.0. (#169)

### Changed

- **OTP code format now allows leading zeros** — `StandardId::Passwordless.generate_otp_code` (new consolidated generator, replacing the inline generators in `VerifyEmail::StartController`, `VerifyPhone::StartController`, and `BaseStrategy`) produces codes in the range `[0, 10**n)` zero-padded to the configured length, so values like `"000123"` are now valid. The previous generators produced integers in `[10**(n-1), 10**n)`, which never had leading zeros. Entropy is unchanged; host apps that stored or displayed codes as integers should treat them as strings. (#169)

### Chore

- Deleted stale top-level `test_authorization_flows.rb` scaffolding. (#173)

## [0.15.0] - 2026-04-18

### Added

- **`StandardId::Otp` public primitive** — New realm-parameterized module (`Otp.issue` / `Otp.verify`) that wraps the hardened passwordless `VerificationService`. Enables OTP flows outside authentication (e.g. contact-verification widgets) without reimplementing enumeration defense, atomic failed-attempt tracking, or the `bypass_code` E2E hook. Supports `:built_in`, `:custom`, and `:manual` delivery modes. (#181)
- **`JwtService.sign` / `.verify` primitives** — Low-level JWT encode/decode that don't consult config, useful for HS256 service-to-service tokens and similar use cases. Existing `encode` / `decode` / `decode_session` methods unchanged — use those for OAuth flows. Typed error hierarchy under `StandardId::InvalidTokenError` (`ExpiredTokenError`, `InvalidSignatureError`, `InvalidAlgorithmError`, `InvalidAudienceTokenError`). (#177)
- **`session_type_resolver` callback** — New `config.session.session_type_resolver` decides whether web/API/OAuth sign-ins produce a `BrowserSession`, `DeviceSession`, or `ServiceSession`. Default mirrors current selection. OAuth token grants can now optionally persist a session row (opt-in via the resolver). (#182)
- **`audience_profile_types` map + audience-aware claim resolvers** — New `config.oauth.audience_profile_types` maps each audience to an allowed profile type (or array), enforced automatically in `AudienceVerification`. `claim_resolvers` now receive `audience:` in their context (via `CallableParameterFilter`), so resolvers can branch per audience. New `OAUTH_AUDIENCE_MISMATCH` event and `InvalidAudienceProfileError`. (#179)
- **Multi-profile-type scopes + per-scope `authorizer` + `scope_resolver` callback** — Scope config accepts `profile_types:` (plural array) in addition to legacy `profile_type:` singular (deprecated but still works). Each scope may declare an `authorizer:` callable for role-based / wildcard logic that runs after the profile-type check. New `config.scope_resolver` detaches scope resolution from the URL convention — apps using alternate URL schemes (e.g. `control_plane` param) no longer need to override `current_scope_config`. (#178)
- **Cleanup jobs for authorization codes + code challenges** — `CleanupExpiredAuthorizationCodesJob` and `CleanupExpiredCodeChallengesJob` with dual grace windows (7-day for expired, 1-day for consumed/used — replay-forensics only). Full `standard_id:cleanup:{sessions,refresh_tokens,authorization_codes,code_challenges,all}` rake task set. (#183)
- **Multi-step install generator** — `rails g standard_id:install` now writes the initializer with grouped sections, appends `mount StandardId::WebEngine` / `ApiEngine` to `config/routes.rb`, auto-runs `rake standard_id:install:migrations`, and prints a post-install checklist pointing at `AccountAssociations`, `WebAuthentication`/`ApiAuthentication`, and cleanup jobs. Flags: `--skip-initializer`, `--skip-routes`, `--skip-migrations`. Idempotent on re-run. (#176)

### Deprecated

- **`ScopeConfig#profile_type` singular** — Use `profile_types:` (plural) instead. Singular still accepted, emits an `ActiveSupport::Deprecation` warning. Planned for removal in 2.0. (#178)

## [0.14.4] - 2026-04-14

### Fixed

- **Prevent OTP race condition with multiple active challenges** — When a user requests a new OTP before the previous one expires, multiple active challenges could accumulate. The verification lookup returned an arbitrary match, causing valid codes to be rejected. Now invalidates existing active challenges when creating a new one, with ordered lookup as a defensive fallback. Adds composite index on `code_challenges` for the new query pattern. (#165)

### Changed

- Bump puma from 7.2.0 to 8.0.0 (#162)
- Group all Dependabot updates including majors (#163)

## [0.14.3] - 2026-04-02

### Fixed

- **Guard `apply_skips!` against unloaded `ControllerPolicy`** — When `skip_host_authorization` is called from a Rails initializer, `ControllerPolicy` may not be autoloaded yet by Zeitwerk, causing a `NameError`. The method now checks `defined?` before accessing the constant. Controllers that register later still receive skips via the `apply_to_controller` callback and the `to_prepare` re-run. (#160)

## [0.14.2] - 2026-04-02

### Fixed

- **Lowercase controller name in Inertia component name generation** — `inertia_component_name` produced PascalCase names like `"standard_id/Login/show"` because `.demodulize` preserves class casing. Adding `.underscore` produces `"standard_id/login/show"` which matches the lowercase page file conventions used by consuming apps. (#158)

## [0.14.1] - 2026-03-28

### Fixed

- **Preserve TLS SNI hostname in SSRF-protected connections** — The SSRF protection layer now preserves the original hostname for TLS Server Name Indication (SNI), preventing certificate verification failures when connecting through resolved IP addresses. (#154)

## [0.14.0] - 2026-03-26

### Added

- **Configurable `username_validator` for passwordless flows** — New `config.passwordless.username_validator` callable that runs before OTP generation to validate the recipient address (e.g. via truemail). Returns nil/false to proceed, or an error message string to reject with `InvalidRequestError`. Follows the same pattern as `account_factory` and `before_sign_in` hooks. (#150)
- **Integration tests for multi-mount WebEngine with scope defaults (RAR-93)** — Comprehensive integration tests verifying multiple WebEngine mounts with independent scopes, session tracking, and lifecycle hooks. (#149)

## [0.13.0] - 2026-03-26

### Added

- **Scope-aware lifecycle hooks (RAR-95, RAR-96)** — Named authentication scopes with profile-type gating. `ScopeConfig` and `StandardId.scope_for(name)` define scopes; lifecycle hooks receive scope context. Built-in profile validation runs before custom `before_sign_in` hooks, raising `AuthenticationDenied` when required profile is missing. Configurable `profile_resolver` and per-scope `no_profile_message`. (#145)
- **Multi-scope session tracking (RAR-97)** — `sign_in_account` accepts `scope_name:` and accumulates scopes in `session[:standard_id_scopes]`. New `current_scope_names` helper exposed to controllers and views. Scopes preserved across session fixation reset, cleared on logout. OAuth callback scope preserved via `state_data`. (#146)
- **Reusable `PasswordlessFlow` concern (RAR-94)** — Public concern wrapping `PasswordlessStrategy` with `generate_passwordless_otp(username:)` and `verify_passwordless_otp(username:)`. YARD documentation added to `WebAuthentication`, `LifecycleHooks`, and `PasswordlessFlow` for host app adoption. `handle_authentication_denied` falls back gracefully when WebEngine is not mounted. (#147)

## [0.12.0] - 2026-03-25

### Added

- CI-driven gem publishing via GitHub Actions trusted publisher

## [0.11.0] - 2026-03-25

### Added

- **Pre-authentication lifecycle hook (RAR-73)** — `before_sign_in` callback for pre-session gating. Supports `AuthenticationDenied` rejection before session creation across all auth paths. (#137)
- Test coverage thresholds with SimpleCov (RAR-27) (#136)

## [0.10.0] - 2026-03-24

### Security

- **Rate limiting on all auth endpoints (RAR-51, RAR-60, RAR-56)** — Add Rails 8 built-in `rate_limit` to password login, OTP verification, email/phone verification code generation, API passwordless, and API token endpoints. Configurable limits via `rate_limits` config scope. Includes `RateLimitStore` for lazy cache resolution and `RateLimitHandling` concern for graceful 429 responses with `Retry-After` header. (#129)

### Added

- **Post-authentication lifecycle hooks (RAR-73)** — `after_sign_in` and `after_account_created` configurable callbacks. Support redirect overrides, `AuthenticationDenied` rejection, and `first_sign_in?` detection across all auth paths (password, passwordless, social, signup). (#131)
- **Passwordless account factory callback (RAR-71)** — `passwordless.account_factory` config callable receives `identifier:`, `params:`, `request:` and replaces default `find_or_create_account!` logic. Runs inside transaction for rollback protection. Eliminates monkey-patching in host apps. (#130)
- **Passwordless registration flow in WebEngine (RAR-74)** — `web.passwordless_registration` config enables automatic account creation during passwordless login. Fires `PASSWORDLESS_ACCOUNT_CREATED` event. Challenge preserved on rejection for retry. (#131)
- **Extensible JWT session struct (RAR-68)** — Session struct gains `claims` field with full decoded JWT payload. New `oauth.custom_claims` config callable for encoding custom claims into access tokens. Reserved JWT keys protected from override. (#132)
- **Built-in OTP email delivery (RAR-63)** — `PasswordlessMailer` with HTML + text templates. `passwordless.delivery` config (`:custom` default / `:built_in`), `mailer_from`, `mailer_subject`. Eliminates ~15 lines of event subscriber boilerplate per host app. (#133)
- **Reusable OTP verification API (RAR-45)** — `StandardId::Passwordless.verify` public method for host apps with custom controllers. Result object with `error_code` symbols (`:invalid_code`, `:expired`, `:max_attempts`, `:not_found`, `:blank_code`, `:account_not_found`, `:server_error`). (#134)
- `find_existing_account` method on passwordless strategies for account lookup without creation
- `RateLimitStore` lazy-resolving cache wrapper for rate limiting infrastructure

## [0.9.0] - 2026-03-10

### Security

- **Database-backed refresh token revocation with rotation and reuse detection (RAR-49)** — Refresh tokens are now stored in the database with token digest, expiry, and revocation tracking. Each refresh rotates the token (old one revoked, new one issued). Reuse of a rotated token triggers family-wide revocation and emits `OAUTH_REFRESH_TOKEN_REUSE_DETECTED` event.
- **Enforce PKCE S256 only, reject plain method (RAR-50)** — The insecure PKCE `plain` method is no longer accepted. Only `S256` is supported, per OAuth 2.1 best practices.
- **Hash PKCE code_challenge at storage time (RAR-58)** — The `code_challenge` column now stores a SHA256 hex digest instead of the raw challenge value, for defense-in-depth against database compromise.
- **Secure password strength defaults (RAR-59)** — `require_special_chars`, `require_uppercase`, and `require_numbers` now default to `true`. Apps that intentionally want weaker passwords must explicitly set `false`.

### Added

- `StandardId::RefreshToken` model with token digest, expiry, revocation, and family chain tracking
- `StandardId::CleanupExpiredRefreshTokensJob` for periodic cleanup of expired/revoked refresh tokens
- `StandardId::PasswordStrength` concern for config-driven password complexity validation
- `OAUTH_REFRESH_TOKEN_REUSE_DETECTED` security event
- Session `revoke!` now cascades revocation to associated refresh tokens
- Session `before_destroy` revokes active refresh tokens before deletion

### Changed

- **Breaking**: PKCE `plain` method no longer accepted — clients must use `S256`
- **Breaking**: Password complexity defaults changed from `false` to `true`
- Refresh tokens now include `jti` claim for database lookup; legacy tokens without `jti` are handled gracefully during migration period

### Migration Required

```bash
rails standard_id:install:migrations
rails db:migrate
```

## [0.8.1] - 2026-03-24

### Security

- **Fix social login account takeover via implicit email linking (RAR-46)** — When a social login returned an email matching an existing identifier from a different provider, the system granted access without verification. Now validates provider ownership with a configurable `link_strategy` (`:strict` default blocks cross-provider linking, `:trust_provider` preserves legacy behavior)
- Add SSRF protection to `HttpClient` — resolve hostnames before connecting and reject private/loopback IP ranges; fix DNS rebinding by pinning connections to resolved IPs; validate URL scheme (http/https only)
- Add session fixation protection — call `reset_session` before creating authenticated browser sessions on both login and remember-me flows
- Filter sensitive OAuth parameters (`code_verifier`, `code_challenge`, `client_secret`, `id_token`, `refresh_token`, `access_token`, `state`, `nonce`, `authorization_code`) from Rails logs via engine initializer

### Added

- `StandardId::SocialLinkError` exception with `email` and `provider_name` attributes for host apps to build custom error responses
- `social.link_strategy` config option (`:strict` or `:trust_provider`)
- `SOCIAL_LINK_BLOCKED` event in both `SOCIAL_EVENTS` and `SECURITY_EVENTS`
- `provider` column on `standard_id_identifiers` table (nullable, backfilled on social re-login)
- `SsrfError` exception class for blocked internal requests

### Migration Required

```bash
rails standard_id:install:migrations
rails db:migrate
```

## [0.8.0] - 2026-03-23

### Added

- Post-authentication lifecycle hooks: `after_sign_in` and `after_account_created` config callbacks for host apps to run custom logic after authentication events (#118)
- `StandardId::AuthenticationDenied` exception for rejecting sign-ins from hooks, with automatic session revocation and redirect
- Configurable auth mechanism toggles for WebEngine via `config.web.*` scope — selectively enable/disable password login, passwordless OTP, social login, signup, password reset, email/phone verification, and session management (#119)
- `WebMechanismGate` concern with `requires_web_mechanism` class method for controller-level enforcement
- `first_sign_in?` helper in `LifecycleHooks` concern using active session count

### Fixed

- Orphaned accounts when `after_sign_in` raises `AuthenticationDenied` during signup or social login — newly created accounts are now cleaned up atomically (#120)
- Race condition in social login: `RecordNotUnique` on concurrent requests is now rescued with retry
- `first_sign_in?` now only counts active sessions (excludes expired/revoked)
- Hardcoded `connection: "email"` in passwordless verify now uses `@otp_data[:connection]`
- `enforce_web_mechanism!` validates mechanism names with `respond_to?` for actionable errors on typos
- Removed obsolete brakeman ignore entries, added ignores for hook-controlled redirects

### Deprecated

- `passwordless.enabled` config field — use `web.passwordless_login` instead

## [0.7.1] - 2026-03-20

### Added

- Configurable `bypass_code` for E2E testing of passwordless verification flows (#113)

## [0.7.0] - 2026-03-19

### Added

- `POST /oauth/revoke` endpoint for RFC 7009-compliant token revocation (#108)
- `GET /.well-known/openid-configuration` endpoint for OIDC discovery (#109)
- `GET /api/sessions` and `DELETE /api/sessions/:id` endpoints for mobile session management (#110)
- `OAUTH_TOKEN_REVOKED` event published on successful token revocation

## [0.6.0] - 2026-03-19

### Added

- `Account.find_or_create_by_verified_email!` class method for race-safe account creation with verified email identifiers (#107)
- Publishes `ACCOUNT_CREATING` and `ACCOUNT_CREATED` lifecycle events during account creation
- Auto-sets `email` column on Account if it exists and isn't already provided

### Changed

- Social OAuth callback now only accepts `scope` (singular) parameter per OAuth 2.0 spec; the `scopes` (plural) fallback has been removed (#106)

## [0.5.2] - 2026-03-17

### Added

- Configurable `sentry_context` lambda for host apps to supply extra Sentry user context fields (email, username, etc.) without overriding the concern method (#98)

### Fixed

- Rescue `ArgumentError` in `skip_host_authorization` when controllers inherit ActionPolicy but haven't called `verify_authorized` (#98)
- Guard `sentry_context` lambda against nil returns, non-Hash returns, and non-callable config values (#98)
- Base Sentry context keys (`id`, `session_id`) cannot be overridden by the lambda (#98)

## [0.5.1] - 2026-03-17

### Fixed

- Use `skip_verify_authorized` for ActionPolicy framework in `skip_host_authorization`, with `respond_to?` guard for API controllers that don't include ActionPolicy (#96)
- Guard `SentryContext` against sessions without `id` method (#95)

### Changed

- Bump production dependencies (#94)

## [0.5.0] - 2026-03-13

### Added

- Engine scope context to events for richer event payloads (#91)
- Nonce parameter support through authorization code flow (#89)

### Changed

- Automate GitHub Releases from CHANGELOG.md on tag push (#90)

## [0.4.0] - 2026-03-12

### Added

- Controller auth-skip declarations and `StandardId.skip_host_authorization` for authorization gem integration (RAR-64) (#85)
- `StandardId::PasswordlessVerificationService` for custom passwordless login UIs (RAR-65) (#84)
- `StandardId::Testing` support package for host app test suites (RAR-66) (#74)

### Fixed

- Thread-safe class-level memoization in `JwtService` and `PasswordFlow` (#87)

## [0.3.2] - 2026-03-11

### Added

- Optional `SentryContext` concern for enriching Sentry error reports with auth context (#76)
- Optional `current_user` alias for `current_account` (#75)
- `account_scope` configuration for eager-loading account associations (#77)

### Fixed

- Normalize IPv6 localhost (`::1`) to `127.0.0.1` for consistent IP handling (#79)

### Changed

- Add repo hygiene files: CONTRIBUTING, SECURITY, CODE_OF_CONDUCT (#78)

## [0.3.1] - 2026-03-11

### Added

- Bearer token extraction concern for flexible JWT authentication (RAR-48)
- JWT audience (`aud`) verification on token decode (RAR-48)
- Expired session cleanup job with configurable grace period (RAR-62)
- Boot-time warning when JWT issuer is not configured (RAR-54)

### Fixed

- Social login now checks provider `email_verified` field before marking emails as verified (RAR-47)
- Prevent user enumeration via timing side-channel on password login with dummy bcrypt comparison (RAR-53)
- Replace database error leak in signup with generic message to prevent account enumeration (RAR-61)
- Remove `account` attribute from `AccountLockedError` to prevent sensitive data exposure (RAR-57)
- Add HTTP client timeouts (5s open, 10s read) to prevent resource exhaustion from slow OAuth providers (RAR-52)
- Cap token lifetimes at 24h (access) and 90d (refresh) with log warnings on clamping (RAR-55)

## [0.3.0] - 2026-03-10

### Added

- Passwordless OTP login flow for WebEngine (RAR-44)
- Audit logging documentation for integration with `standard_audit` gem

### Fixed

- Disable `strict_loading` on `current_account` in session managers

### Changed

- Upgrade to Ruby 4.0.1
- Standardize GitHub Actions workflows and lefthook git hooks
- Bump dependencies: sqlite3, puma, brakeman, rspec-rails, shoulda-matchers

## [0.2.9] - 2025-12-02

### Fixed

- Add `alg` and `use` fields to JWKS endpoint response

## [0.2.8] - 2025-11-28

### Added

- Signing key rotation with zero-downtime support (CORE-164)

## [0.2.7] - 2025-11-20

### Added

- Basic auth support for client secret authentication
- Redirect to `login_page` when not logged in

## [0.2.6] - 2025-11-15

### Added

- JWKS endpoint for JWT public key exposure (SWE-701)

## [0.2.5] - 2025-11-10

### Added

- Store `aud` on refresh tokens and expose via `current_session`

## [0.2.4] - 2025-11-05

### Added

- Refresh token support for social OAuth flow

## [0.2.3] - 2025-10-30

### Added

- Scope parameter support in social provider token exchange (SWE-697)

## [0.2.2] - 2025-10-25

### Added

- Action Cable authentication support

## [0.2.1] - 2025-10-20

### Added

- Login params support in OAuth sign-in flow

## [0.2.0] - 2025-10-15

### Added

- Account activation/deactivation with event-driven side effects
- Account locking/unlocking for administrative security
- Configurable session expiration
- Event-driven architecture replacing single callbacks

### Changed

- Refactor social provider to prepare for plugin architecture
- Extract Apple and Google providers into separate gems (`standard_id-apple`, `standard_id-google`)
- Make gem thread-safe for multi-threaded servers
- Ensure event payloads are audit-ready for external subscribers

## [0.1.7] - 2025-09-15

### Added

- Event-driven architecture for extensibility and observability

## [0.1.6] - 2025-09-01

### Added

- Inertia.js support for React/Vue/Svelte frontends

## [0.1.5] - 2025-08-15

### Added

- Apple Sign In integration
- Social login callback support
- Server-side authorization code flow for mobile

### Fixed

- Social callback no longer always required

## [0.1.4] - 2025-08-01

### Added

- Google OAuth integration
- Configurable custom scopes and claims

## [0.1.3] - 2025-07-15

### Added

- JWT scope validation in API authentication
- Configurable OAuth token expiration

## [0.1.2] - 2025-07-01

### Fixed

- Client credential flow bugs

## [0.1.1] - 2025-06-15

### Changed

- Initial version bump after core setup

## [0.1.0] - 2025-06-01

### Added

- Core authentication engine with web and API dual-mount architecture
- Cookie-based web sessions with CSRF protection
- JWT-based API authentication
- OAuth 2.0 authorization code flow with PKCE support
- Implicit, client credentials, and password grant flows
- Refresh token flow
- Passwordless authentication via email/SMS OTP
- STI-based session management (Browser, Device, Service)
- STI-based identifiers (Email, Phone, Username)
- Client application management with secret rotation
- Configuration system with schema DSL
- Install generator
