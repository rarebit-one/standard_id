# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
