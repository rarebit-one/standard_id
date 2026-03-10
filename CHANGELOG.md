# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
