# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
