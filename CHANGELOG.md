# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.37.0] - 2026-08-05

### Fixed

- **`refresh_tokens.session_id` is finally populated, and the cause was statement ordering, not a missing feature.** Every refresh token in every consuming app had a nil `session_id`, so every session→refresh revocation cascade — the gem's own `Session#revoke!`, `Session.revoke_sessions!`, and each app's equivalent — matched **zero rows**, and 0.35.0's parent-session check had no parent to consult. Measured in production: jumpdrive 15 tokens / 0 linked; nutripod 238 / 0, with **177 live at the time of measurement**.

  `generate_token_response` created the refresh token one statement *before* `maybe_persist_session_for_token!` ran, inside the same transaction — so when `persist_refresh_token!` wrote `session_id`, there was no session yet to point at. The link was nil **by construction**, not by omission. Swapping the two statements is the fix; `refresh_token_session_id` now returns the session the same grant just materialised.

  See rarebit-one/rarebit-ops#304.

### Changed

- **BEHAVIOUR NARROWED — `validate_parent_session!` now refuses only on a REVOKED parent, no longer on an expired one.** This is a deliberate relaxation of what 0.35.0 shipped, and hosts should read it before upgrading.

  `Session#active?` is `!revoked? && !expired?`, so the original `return if session.active?` also refused a refresh whose parent had merely aged out. That was harmless while nothing was linked — with no parent, neither branch could fire. The moment linkage above becomes real, an expiry branch silently becomes a **lifetime policy**, and a badly-scaled one: an app running an 86400s `browser_session_lifetime` against a 2592000s `refresh_token_lifetime` would see its session-backed clients drop from monthly to **daily** re-authorization, as a side effect of a security fix that was never about login frequency.

  Revocation is the property the estate wants: an operator revokes a session and access ends. Lifetime remains `refresh_token_lifetime`'s job, which already exists and is already configured per host. Keeping them separate is what lets linkage ship without renegotiating anyone's login cadence.

- **`ServiceSession` is carved out of linkage on purpose.** Machine credentials keep their own lifecycle, matching the exclusion the `:account` revocation scope already makes, so a human's browser logout cannot kill a running CLI or MCP agent sharing the account.

### Notes for hosts

**This release does not retroactively repair your app.** Linkage happens only where the host materialises a session at token-issue time via `config.session.session_type_resolver`. A host with no resolver configured keeps nil `session_id` and is unchanged in every respect. The gem now makes the property *achievable and automatic*; enabling it per app is separate work.

Existing rows cannot be linked retroactively — there is no record of which session issued them.

## [0.36.2] - 2026-08-04

**The third release in one chain, and the last of it.** 0.36.0 made the account guards bite on live sessions; 0.36.1 repaired the 500 that exposed on `ApiEngine`; this repairs 0.36.1's own overreach onto the OAuth token endpoint. That reads like flailing, so state it plainly: 0.36.0 was a correct behaviour change, and each follow-up is a narrower blast radius of the same root cause — an exception pair that no controller in the ancestry had ever had to answer for, meeting two route families with two different wire contracts. 0.36.1 fixed the first family and, by rescuing on the shared parent, silently annexed the second. 0.36.2 draws the line between them. Nothing here reverts 0.36.0 or 0.36.1; resource-endpoint behaviour is byte-identical to 0.36.1.

### Fixed

- **`POST /api/oauth/token` answers `400 invalid_grant` again — not `401 invalid_token` — when the account behind the grant is deactivated or locked.** 0.36.1 registered `rescue_from StandardId::AccountDeactivatedError` / `AccountLockedError` on `StandardId::Api::BaseController`, rendering RFC 6750 §3.1's bearer challenge. That is right for a bearer-**protected resource** (`/api/v1/sessions`, `/api/v1/userinfo`): the caller presented an access token and must be told to discard it. But `StandardId::Api::Oauth::BaseController` re-rescues only `OAuthError`, so both account errors fell through to the inherited bearer handler on every OAuth protocol route as well. The token endpoint is not a protected resource — the client is *obtaining* a credential, not presenting one — so there is no token to challenge, and RFC 6749 §5.2 requires a token-endpoint error object instead. A `401` carrying `WWW-Authenticate: Bearer …` is not a legal answer to a grant request, and a conformant client has no defined way to interpret it.

  `StandardId::Api::Oauth::BaseController` now rescues both errors itself. Rails resolves `rescue_from` handlers most-recently-registered-first and a subclass registers after its parent, so the OAuth handler wins on OAuth routes while `Api::BaseController`'s `401` continues to govern every other API route — unchanged. Specs now pin **both** contracts side by side (`spec/requests/standard_id/api/account_error_response_shape_spec.rb`), since the whole defect was one shape applied to two contracts; the file carries the negative control for each half.

- **Why `invalid_grant`, and why it is rendered explicitly.** RFC 6749 §5.2 enumerates six codes. `invalid_grant` — the grant is "invalid, expired, revoked, … or was issued to another client" — is what an authorization code or refresh token belonging to a disabled account has become: the resource owner's authorization no longer stands and no retry will succeed. `unauthorized_client` was the alternative and is wrong on **subject**: it says the *client* is not permitted to use this grant type, a property of client registration that has not changed. The client is fine; the account behind the grant is not. Mapping account state onto a client-scoped code would send well-behaved clients off to audit a registration that is correct.

  The handler renders that code and status literally rather than routing through `handle_oauth_error`. Both account errors are bare `StandardError`s with no `oauth_error_code` / `http_status`, so `handle_oauth_error`'s `respond_to?` fallbacks would yield `invalid_request` / `400`. The status is right by luck; the code is not — §5.2 reserves `invalid_request` for a **malformed** request, and this request is perfectly well-formed. Worse, the fallback path uses `exception.message`, which would put `"Account is deactivated"` / `"Account has been locked"` straight into `error_description`. Depending on a default that is wrong in two of three fields is a coincidence, not reuse.

- **The `error_description` discloses nothing about account state.** Both errors render the same generic sentence — `"The provided authorization grant is invalid, expired or revoked"` — because whoever presents a grant may not be its legitimate holder, which is the exact scenario the account guard exists for. Telling the presenter of a leaked refresh token that the account is suspended is a disclosure, and returning distinguishable text for "deactivated" versus "locked" is a smaller one. `AccountLockedError#lock_reason` is operator-authored text for logs and admin screens and is surfaced in neither the body nor any header; a spec pins that across both. The specific reason belongs in the host's `ACCOUNT_LOCKED` / `ACCOUNT_DEACTIVATED` subscriber, server-side.

### Documentation

- **README: never guard a `rescue_from` with a `rescue_handlers` check.** This release exists partly because a consumer's own token-endpoint shim was written as `rescue_from X unless StandardId::Api::BaseController.rescue_handlers.any? { … }` — defensive-looking, and a trap. When 0.36.1 registered a handler for that class on the gem superclass, the guard stopped matching, the host's block never registered, and the gem's `401` silently replaced the host's `400` with no error, no deprecation, and nothing in the host's diff. The two failure modes compounded: the gem shipped the wrong shape *and* disabled the shim that would have corrected it. The README now says to register unconditionally — a later registration already outranks the gem's, which is what the guard was groping for. The hazard is the gem's to warn about, since only the gem can create it.

## [0.36.1] - 2026-08-04

**A follow-up to 0.36.0's own regression, released the same day.** 0.36.0 is correct and stays — read its entry first for why `SESSION_VALIDATING` had to start carrying `account:`. This release repairs the fallout of that fix on the gem's own API routes. Two releases land together because the second is only reachable *because* of the first.

### Fixed

- **`StandardId::Api::BaseController` now answers `401` — not `500` — when the authenticated account is deactivated or locked.** 0.36.0 made `AccountStatus` / `AccountLocking` fire on a live authenticated request for the first time, which is the intended behaviour. But `AccountDeactivatedError` and `AccountLockedError` are bare `StandardError` subclasses, under neither `InvalidSessionError` nor `OAuthError`, and the API base controller rescued only those three families. So the very change that started refusing a disabled account's bearer token turned every route under `ApiEngine` — `/api/v1/sessions`, `/api/v1/userinfo`, all of it — into an unhandled exception for that account. Every consumer mounting `ApiEngine` inherited it. Before 0.36.0 the guard was inert on that path, so the hole existed but was unreachable; the release is what exposed it.

  Observed independently in two consumers during the 0.36.0 rollout: `luminality-web`, which has an app-side handler on `Api::ErrorHandling` and so saw only the *gem-owned* routes fail, and `sidekick-web`, which has none and saw its whole API tree fail.

  A 500 is not a refusal. It carries no `WWW-Authenticate`, tells the client nothing about discarding a token that will never work again, and pages the on-call for a routine account state. Both errors now render the established bearer shape — `401`, `{ "error": "invalid_token", "error_description": … }`, plus the matching `WWW-Authenticate` challenge — via the same `render_bearer_unauthorized!` the other credential failures use. No new response shape was invented.

  **Why `invalid_token`.** RFC 6750 §3.1 defines exactly three codes. `invalid_token` covers a token "expired, revoked, malformed, or **invalid for other reasons**", and a token whose subject account has been disabled is invalid for one of those other reasons; it also carries the right client instruction — discard the token and re-authenticate — which is precisely correct here, since no retry with this token can ever succeed. `insufficient_scope` (403) would be wrong twice over: nothing about this is a scope failure, and 403 invites a client to keep the token and retry. `invalid_request` (400) would be wrong because the request is perfectly well-formed.

  `AccountLockedError#lock_reason` is **not** surfaced. It is operator-authored text meant for logs and admin screens, and `WWW-Authenticate` is a quoted string that arbitrary text would break as well as leak. A spec pins that the reason appears in neither the body nor the header.

### Unchanged, deliberately — two decisions worth knowing about

- **The `WebEngine`'s own routes (`/sessions`, `/account`, `/logout`) get no gem-side handler, and this is not an oversight.** `StandardId::Web::BaseController` descends from the **host's** `ApplicationController`, so the `rescue_from StandardId::AccountDeactivatedError` the README has always told hosts to write already covers those routes. A gem handler there would not add safety, it would remove it: Rails scans `rescue_handlers` most-recently-registered-first, and a subclass registers after its parent, so anything the gem registered on `Web::BaseController` would outrank and silently override the host's — replacing a host's "your account has been deactivated" page with whatever the gem chose. `Api::BaseController` has no such escape hatch; descending from `ActionController::API`, there is nowhere in its ancestry for a host to put a handler, which is exactly why only that side is rescued in the gem.

  **Hosts must therefore still carry their own `ApplicationController` handler for these two errors.** If you do not have one, a deactivated or locked account hitting a web route — yours or the engine's — is an unhandled exception. That was true before 0.36.0 for the sign-in path and remains true; 0.36.0 simply widened the set of requests that can reach it from "sign-in and token mint" to "any authenticated request". The README's account sections now spell out which routes the engine answers for and which it does not.

- **`AccountDeactivatedError` / `AccountLockedError` still descend from `StandardError`, not from `InvalidSessionError`.** Reparenting them was considered as the broader fix — it would make every consumer's existing `rescue_from StandardId::InvalidSessionError` catch them automatically, with no consumer change at all — and rejected on two grounds. First, they mean something genuinely different: an `InvalidSessionError` says the credential is no good and the remedy is to sign in again, while these say the credential is fine and the account is disabled, where signing in again will not help and the user needs to be told so. Consumers who deliberately distinguish the two would lose that distinction silently. Second, and decisively, it would hijack handlers hosts have already written: `Web::BaseController` registers `rescue_from NotAuthenticatedError, InvalidSessionError, with: :redirect_unauthenticated_to_login`, so under the reparented hierarchy a host's `rescue_from AccountDeactivatedError` — registered *earlier*, on the parent — would lose to the gem's subclass registration, and every consumer following the README would start bouncing disabled users to `/login` instead of to their account-disabled page. A patch release that quietly re-routes a documented UX is not a patch. The narrow fix leaves both hierarchies and both sets of host handlers exactly as they were.

### Testing

`spec/requests/standard_id/live_session_account_guard_spec.rb` gains three API examples (401 shape for deactivated, 401 shape for locked, and `lock_reason` non-disclosure) and two web examples pinning the delegate-to-host design above. Proven by negative control: with the two `rescue_from` lines deleted from `Api::BaseController`, the three API examples fail with the raw error escaping the request; restored, the file is 14/14 and the suite 2097/2097.

Relates to rarebit-one/rarebit-ops#306.

## [0.36.0] - 2026-08-04

### Security

- **`SESSION_VALIDATING` now carries the `account:` its subscribers guard on, so `AccountStatus` and `AccountLocking` finally stop a LIVE authenticated request.** Both concerns subscribe to `OAUTH_TOKEN_ISSUING`, `SESSION_CREATING` and `SESSION_VALIDATING` and branch on `event[:account]&.inactive?` / `&.locked?`. Neither publisher of `SESSION_VALIDATING` ever sent an `account:` — `Web::AuthenticationGuard#emit_session_validating` and `Api::AuthenticationGuard#emit_session_validating` both published `session:` alone. `Events#enrich_payload` injects `:current_account`, a *different* key, so `event[:account]` was `nil` and that leg of both guards never fired.

  That it was an omission rather than a design is plain from the sibling emitters in the same two files: `emit_session_validated` and `emit_session_expired` each pass `account:`. Only the *validating* hook — the one that runs before the request is allowed to proceed, and therefore the only one of the three that can stop it — left it out.

  **Upgrade implication — expect previously-working sessions and tokens to start failing. That is the fix.** Three shapes were getting through and now do not:

  1. **API bearer tokens, the big one.** `AccountStatusSubscriber` / `AccountLockingSubscriber` revoke `account.sessions.active` on `deactivate!` / `lock!`, but an access token is a stateless JWT with no `Session` row — revoking sessions does nothing to it. Until its `exp`, `SESSION_VALIDATING` was the only thing that could refuse it, and it was inert. Any client holding an access token minted before the account went bad kept working; it now gets `AccountDeactivatedError` / `AccountLockedError` on the next request.
  2. **A status change that skips the callbacks** — `update_all`, `update_column`, a data migration, direct SQL, an admin bulk action. No `ACCOUNT_DEACTIVATED` / `ACCOUNT_LOCKED` event fires, so no session revocation happens, and the browser session stayed live until it expired.
  3. **A session minted after the account went bad by a path that emits no `SESSION_CREATING`.** `Web::SessionManager#load_session_from_remember_token` calls `create_browser_session` directly and publishes nothing, so remember-me re-auth walked straight past the sign-in guard.

  Hosts that lock or deactivate accounts should expect support traffic from users whose sessions used to survive. `sidekick-web`'s `LockAccountModal` copy — *"The user will be immediately locked out / All active sessions will be terminated"* — is now true rather than aspirational.

  **No new query on either hot path.** The web guard reads the `:account` association only when it is already loaded (`SessionManager` loads the session with `eager_load(:account)`) and otherwise falls back to a single indexed `find_by` — it must never lazily touch the association, because several consumers run `strict_loading_by_default` and this emitter is on the path of *every* authenticated request, where a `StrictLoadingViolationError` would turn an inert guard into a 500. It also runs *before* the blank/expired/revoked checks, so it handles a nil session. The API guard threads its `SessionManager` through to reuse the memoized, strict-loading-cleared `#current_account` that `emit_session_validated` resolves anyway.

  The spec that let this survive for so long asserted enforcement by publishing `SESSION_VALIDATING` **by hand** with the very key the real publisher omitted — proof that the subscriber reacts to a correctly-shaped payload, not that any caller produces one. Those examples now drive the real guards over real HTTP requests (`spec/requests/standard_id/live_session_account_guard_spec.rb`), and were confirmed to fail with the `account:` key removed.

  Tracked in rarebit-one/rarebit-ops#306.

### Added

- **`POST /oauth/revoke` logs a warning when `revocation_scope: :grant` resolves a presented `jti` to no `RefreshToken`.** Under `:grant`, presenting an access token is a deliberate no-op that still answers 200 (RFC 7009 §2.2) — correct, because access tokens are stateless and never persisted, but until now completely silent. A client that only ever presents access tokens looked like it was revoking when it was not. As `:grant` is adopted across the estate, post-flip no-ops need to be visible. Emitted via `StandardId.logger&.warn`, consistent with the existing `revocation_scope` fallback warning. No behaviour change. Relates to rarebit-one/rarebit-ops#304.

## [0.35.0] - 2026-07-31

### Security

- **A refresh token is now refused when its parent session is revoked or expired.** `Oauth::RefreshTokenFlow` validated the `RefreshToken` row only — found, not revoked, not expired — and never consulted the session it belongs to.

  So "revoking a session ends that session's access" was not a property of the gem. It was an emergent consequence of every caller reaching for `Session#revoke!` (a transaction that ALSO does `refresh_tokens.active.update_all(revoked_at:)`) rather than the obvious-looking `session.update!(revoked_at: ...)`, which revokes the session row and leaves its refresh tokens live. Two apps wrote the second form independently and shipped it (rarebit-one/nutripod-web#1100, luminalityai/luminality-web#1048), because the natural spec asserts the session's own `revoked_at` — exactly the half that does work.

  On the device path that meant a refresh-token holder kept minting access tokens after the user had explicitly signed that device out. Checking the parent in the flow makes the property true by construction: it now holds however the session was revoked — `revoke!`, a bare `update!`, a bulk `update_all`, a DBA, a data fix — and covers session expiry too.

  **Unaffected:** refresh tokens with no session (`session_id` nil) — the machine-to-machine shape, including `client_credentials`. There is no parent to outlive, so nothing is checked. No configuration flag was added because no flow in the gem legitimately needs a refresh to outlive its session; every token that carries a `session_id` was minted against that session, and rotation carries the same `session_id` forward.

  The refusal reuses the existing `invalid_grant` / `"Refresh token is no longer valid"` response verbatim (RFC 6749 §5.2). A distinct error would be an oracle — it would tell a holder that the token itself is still good and only the session was pulled.

  The parent session is fetched by `eager_load` in the same query as the token row, so the hot `/oauth/token` path gains no extra round trip.

  Tracked in rarebit-one/rarebit-ops#297.

- **`POST /oauth/introspect` reports the same refresh token as `active: false`.** The RFC 7662 endpoint (off by default, behind `config.oauth.introspection_enabled`) checked the `RefreshToken` row and not its session, so it had the identical gap. Left alone it would have reported `active: true` for a token `/oauth/token` now refuses — introspection contradicting the endpoint it describes. Access tokens are unchanged and still introspect as active until their `exp`; that documented limit is unaffected, because they are stateless and carry no `sid`.

## [0.34.0] - 2026-07-31

### Added

- **`config.verify_issuer`** — decouples MINTING an `iss` claim from REQUIRING one. `nil` (default) follows `config.issuer`, which is the historic behaviour and changes nothing. Set `false` to stamp `iss` on new tokens without yet verifying it.

  This exists because the two were one switch, which made adopting an issuer a flag day: every token already in flight was minted without an `iss`, so setting `config.issuer` rejected all of them at once — every access token and, far worse, every refresh token. An app that had never configured an issuer had no safe single step, which is where `nutripod-web` was stuck (rarebit-one/nutripod-web#1111) and why it could not retire its hand-rolled discovery controller with the rest of the estate.

  Migration: set `issuer` with `verify_issuer = false`, wait out `refresh_token_lifetime` (the long pole — access tokens are short), then remove the override. Setting `true` with no issuer raises at boot rather than silently verifying against `nil` and accepting anything.

## [0.33.0] - 2026-07-30

### Added

- **RFC 7662 token introspection** — `POST /oauth/introspect`, behind
  `config.oauth.introspection_enabled` (default **false**). When off the
  endpoint returns 404 and `introspection_endpoint` is not advertised in either
  discovery document, mirroring how `dynamic_registration_enabled` gates
  `/oauth/register`.

  Confidential clients only: `client_id` + `client_secret`, via HTTP Basic or
  the form body (RFC 6749 §2.3.1 — never both). Every failure mode renders
  `{"active": false}` with **no other members**, per RFC 7662 §2.2.

  Throttled per IP via `config.rate_limits.introspection_per_ip` (default 30 per
  15 minutes).

  Two properties are load-bearing and deliberately not what you would reach for:

  - **The rate limit renders `{"active": false}` / 200, never 429.** A 429
    distinguishes "you are throttled" from "that token is not valid", which turns
    the limiter into a token-validity oracle — an attacker probes until throttled
    and then reads the *status code* to classify tokens. This opts out of
    `RateLimitHandling.rate_limit`'s wrapper by passing an explicit `with:`. The
    reason is commented at the call site, because it reads like a bug otherwise.
  - **The limit keys on `request.remote_ip`** — not Rack's `request.ip`, which
    resolves the forwarding chain against Rack's own trusted-proxy list rather
    than `config.action_dispatch.trusted_proxies` and therefore collapses every
    caller behind a CDN into one bucket. And never on the `Authorization` header
    or `client_id`: `rate_limit` is a `before_action` that runs *before* client
    authentication, so a header-derived key is attacker-controlled and a caller
    could mint a fresh bucket per request by rotating it.

  **Know this limit before building an authorization gate on it.** Access tokens
  are stateless — never persisted, carrying no `sid` — so **a revoked session's
  access token introspects as `active: true` until its `exp`**. Introspection
  answers "did we mint this, and is it unexpired?", not "is it still honoured?".
  The only mitigation is a short access-token lifetime. Refresh tokens *are*
  persisted (as `SHA256(jti)`) and are checked against the row, so a revoked or
  expired refresh token introspects as inactive immediately, and is reported with
  `token_type: "refresh_token"`. Both halves are asserted by specs, the access-token
  one deliberately, so nobody later "corrects" the documentation to overclaim.

- `config.oauth.introspection_enabled` and
  `config.rate_limits.introspection_per_ip`, both documented inline in the
  install template.


- `StandardId::ProviderRegistry.declare_config_schemas!`,
  `.declare_config_schema(provider_class)` and `.provider_classes` — public
  entry points for the above. Useful if you define a provider somewhere the
  boot-time sweep cannot see it (e.g. under `app/`, autoloaded) and need to
  declare its fields yourself.

- **`config.association_strict_loading`** — a supported way to opt the gem's own
  associations out of an app-wide `strict_loading_by_default = true`.

  Two consuming apps were reaching into Rails internals to do this:

  ```ruby
  Account.reflect_on_association(assoc)&.options&.[]=(:strict_loading, false)
  ```

  both with a comment asking for exactly this hook. They could not simply
  re-declare the associations: they are declared inside
  `StandardId::AccountAssociations`, and `credentials` is a `has_many :through`,
  where re-declaration risks ordering breakage. Passing `strict_loading:` at
  declaration time is the supported Rails API, and unlike re-declaration it
  works for the `:through` association.

  Covers `Account#identifiers`, `#credentials`, `#sessions`, `#refresh_tokens`,
  `#client_applications`, plus `Session#refresh_tokens` and
  `Identifier#credentials`.

  **Tri-state, and `nil` is not `false`:**

  | value | effect |
  |---|---|
  | `nil` (default) | no `strict_loading:` option is declared at all — the associations inherit the owner's setting, exactly as before |
  | `false` | opt out; may lazy-load even with strict loading on app-wide |
  | `true` | opt in; strict loading enforced even if off app-wide |

  That distinction is load-bearing rather than stylistic. Rails checks
  `reflection.options.key?(:strict_loading)` *before* consulting the owner
  (`Association#violates_strict_loading?`), so declaring `strict_loading: nil`
  would put the key in the options hash and make `reflection.strict_loading?`
  return `false` — silently disabling strict loading on every gem association in
  every app that never asked for it. The option is therefore omitted entirely
  when unconfigured, and a spec asserts the key's absence.

  **Set it in `config/initializers/standard_id.rb`, not in an
  `after_initialize` block.** The associations read it when your `Account` class
  body runs. StandardId raises a `ConfigurationError` at boot naming the ordering
  problem if a declaration disagrees with the configured value — otherwise a
  too-late assignment fails silently, surfacing as an
  `ActiveRecord::StrictLoadingViolationError` deep inside a request or a quiet
  N+1 in production.

- **`StandardId::Session.revoke_all_for!(account, reason:)`** — bulk session
  revocation that cascades to refresh tokens, promoted from the private
  `RevocationsController#revoke_sessions!` where it had lived since the RFC 7009
  endpoint was built.

  Consuming apps that bulk-revoked with a bare
  `Session.where(account:).update_all(revoked_at:)` were silently skipping the
  refresh-token cascade that `Session#revoke!` performs, leaving the holder of a
  refresh token able to keep minting access tokens after a password reset or
  account deactivation — and skipping the `session.revoked` event, so
  audit-trail and account-locking subscribers never learned. This gives them a
  supported API instead of a local re-implementation.

  Two set-based UPDATEs (one per table) rather than `sessions.each(&:revoke!)`,
  which is O(N) UPDATEs plus O(N) cascades — these call sites are admin bulk
  actions and password resets.

  ```ruby
  result = StandardId::Session.revoke_all_for!(account, reason: "password_reset")
  result.sessions_revoked       # => 3
  result.refresh_tokens_revoked # => 5
  ```

  Honours the current scope, so callers narrow as they need:
  `StandardId::DeviceSession.active.revoke_all_for!(account, reason: "logout")`.
  Accepts an account record or a bare id.

  **Events: one `SESSION_REVOKED` per revoked session, never a single
  aggregate** — subscribers must not need a second code path for bulk
  revocation. Because `update_all` skips callbacks, each event is re-emitted
  explicitly after the transaction commits, and each is individually rescued: a
  raising subscriber must not short-circuit the loop and leave later sessions
  without their event, which would permanently desync audit consumers from the
  DB. Callers emit their own aggregate from the returned counts.

- **`StandardId::Session.revoke_sessions!(sessions, account:, reason:)`** — the
  same set-based core over an explicit collection, for callers that have already
  selected the sessions (e.g. the tokens of a single authorization grant).


- **`config.oauth.discovery_endpoint_base`** — where the advertised endpoints
  actually live.

  | value | meaning |
  |---|---|
  | `nil` (default) | the issuer — byte-identical to 0.32.0 |
  | `:request` | `request.base_url` + the detected mount path |
  | `"https://…"` | verbatim |
  | `->(request:) { … }` | for a proxy that rewrites `base_url`, or an app mounting `ApiEngine` more than once (e.g. under host constraints) where no single detected path is right |

  Request-derived is **opt-in, not the default**, on purpose: defaulting to it
  would silently rewrite the document of every app whose issuer host differs from
  the host serving the request — the split-host setup a separate issuer exists to
  express.

  Inside the mount the mount path needs no configuring or detecting: Rails sets
  `SCRIPT_NAME` to the mount prefix, so `request.script_name` *is* the mount
  path, exactly.

- **`standard_id_well_known_routes at: "<mount path>"`** — a routes-file mapper
  helper that serves the documents at the **origin root**.

  RFC 8615 clients probe the origin root, which is outside every engine mount, so
  the gem could not draw those routes itself — this has to live in the host's
  routes file.

  For each metadata document it draws **both** the bare root form and the RFC
  8414 §3.1 **path-inserted** form:

  ```
  /.well-known/oauth-authorization-server
  /.well-known/oauth-authorization-server/api/v1
  ```

  The second looks redundant and is not. §3.1 inserts the well-known segment
  *before* a path-carrying issuer's path rather than appending to it, and that is
  the URL Claude Code actually requests in production. Without it the client 404s,
  falls back to issuer-relative defaults — hitting the engine's own `/authorize`
  rather than a host audience shim — and every subsequent authenticated request
  401s, a long way from the cause. It is drawn for you rather than documented as
  an extra step.

  `only:` / `except:` select among `:oauth_authorization_server`,
  `:openid_configuration`, `:jwks` — `only: :jwks` for an app that keeps its own
  metadata controller but wants the gem's JWKS at the root. `extra_paths:` adds
  further path-inserted suffixes. `path_inserted: false` draws only the bare root
  forms. No path-inserted JWKS is drawn: it is a concrete file path, not a
  document whose location §3.1 relocates.

- **`config.oauth.discovery_metadata_overrides`** — the members that cannot be
  derived: an authorization endpoint pointing at a host-owned audience-injecting
  shim (needed by all five apps, and the original reason they each wrote a
  controller), a scope list deliberately narrower than what the server can mint,
  an auth-method list that must mirror the host's dynamic-registration policy.

  Values are static or callable; a callable receives
  `{ origin:, endpoint_base:, issuer:, request: }` with `origin` carrying no
  path. A **`nil` value removes the member** rather than emitting `null` — real
  apps omit `scopes_supported` entirely, and a typed RFC 8414 member set to null
  is worse than either alternative.

  **Setting `issuer` raises `StandardId::ConfigurationError`**, naming
  `discovery_endpoint_base` as the thing you probably wanted. It is refused
  rather than ignored because an issuer diverging from what the token service
  stamps yields a document that validates against nothing, failing far from its
  cause.

  See `docs/MIGRATION_GUIDE.md` for how to retire a hand-rolled controller.

### Fixed

- **The discovery documents no longer ignore the `ApiEngine` mount prefix.**

  `Oauth::DiscoveryDocument` derived every endpoint from the issuer
  (`base = issuer.to_s.chomp("/")`). An app mounting `ApiEngine` under a prefix
  its issuer does not carry — `/api`, `/api/v1` — therefore advertised
  `<issuer>/oauth/token` while the endpoint actually lived at
  `<origin>/api/oauth/token`. **Every advertised endpoint 404'd.** Both documents
  were affected; the OIDC one had the identical bug.

  All five consuming apps hand-rolled a replacement controller because of it.

  `issuer` and the endpoint base are now separate values, and stay separate.
  `issuer` is a stable security identifier (RFC 8414 §2) that clients match
  byte-for-byte against both their discovery URL and the `iss` claim of issued
  tokens: it is never derived from the request and cannot be overridden.


- `Session.revoke_sessions!` no longer aborts the revocation loop when logging
  itself fails. The rescue around each `SESSION_REVOKED` publish exists so a
  failing subscriber cannot short-circuit the loop and leave later sessions
  without their event — but it logged via `StandardId.logger.error`, and
  `StandardId.logger` is a *memoized* `config.logger || Rails.logger`, so
  whatever the first reader in the process saw is what every later caller gets,
  including a value that is not a logger at all. In that case the rescue raised
  from inside itself and the guarantee evaporated. It now checks the logger
  responds to `error` first.

- **Provider plugin config fields are now declared before host initializers
  run**, so `config.social.google_client_id = ...` works in a plain
  `config/initializers/standard_id.rb` — the way the install template, this
  README, and both plugin READMEs all said it did.

  It did not. `social.google_client_id` is not in the core schema; the plugin
  declares it via `Providers::Google.config_schema`, which reached
  `ConfigSchema.add_field` only through `ProviderRegistry.register`, called from
  the plugin Railtie's `config.after_initialize` — long after
  `:load_config_initializers`. The host's write therefore hit
  `ConfigSchema::Scope#[]=` → `validate!` against a schema that did not yet know
  the field and raised `StandardId::ConfigurationError: Unknown field
  'google_client_id' for scope 'social'`, with nothing in the message to suggest
  the cause was boot ordering. Every consuming app that used a provider plugin
  independently rediscovered the same
  `Rails.application.config.after_initialize { ... }` workaround, and the three
  documented forms disagreed with each other — two of them raised.

  A new core Engine initializer, `standard_id.provider_config_schemas`, runs
  `before: :load_config_initializers` and declares the fields of every loaded
  provider class. **No plugin release is required**: provider classes are
  required at gem-require time, so they are already loaded at that point.

  Only *field declaration* moved earlier. Full `ProviderRegistry.register` —
  which also runs `validate_provider!` and the provider's `setup` — stays in
  `after_initialize`, where host configuration is complete.

  **Existing `after_initialize` wrappers keep working verbatim.**
  `add_field` is retroactive: `Scope#validate!` and `Scope#[]` both consult the
  schema live, the latter falling back to the field's declared default for an
  unwritten key, so declaring a field late is indistinguishable from declaring
  it early. There is nothing to migrate.

  The dummy app now loads a stand-in provider at application-require time and
  writes its fields from an ordinary initializer, so a regression stops the app
  booting rather than failing one assertion.

### Documentation

- The install template's social-login section now states that these fields come
  from the plugin gems, that omitting the gem is what makes them raise, and that
  the `after_initialize` workaround is no longer needed. Documenting "requires
  0.33.0" alone would have been wrong: uncommenting a line without the provider
  gem in the Gemfile still raises.

## [0.32.0] - 2026-07-28

### Changed

- **Session token digests now default to HMAC-SHA256 instead of BCrypt.**
  `Session#token_digest` was a BCrypt hash at bcrypt-ruby's default cost 12.
  BCrypt's cost factor exists to make brute-force of a *low-entropy* secret
  expensive; session tokens are `SecureRandom.urlsafe_base64(32)` — 256 bits —
  so guessing one is infeasible at any hash speed, and the stretching bought
  nothing while costing real CPU on every authenticated request.

  The cost was measured in a consuming app, and it is not small: **~181 ms per
  verify**, paid per *request* rather than per session creation, which collapsed
  API throughput **19.7×** versus the same requests authenticated by JWT (5.07
  vs 99.95 rps at concurrency 1). Every endpoint in that mix shifted by the same
  ~185 ms. Note this is CPU, not lock contention — bcrypt releases the GVL, so
  four concurrent verifies complete in 3.87× less wall time than four serial
  ones; it saturates cores rather than serializing requests.

  The new digest is HMAC-SHA256 under `secret_key_base`, domain-separated from
  `lookup_hash` by both construction and a versioned prefix so the two values
  can never coincide. This aligns session tokens with how the gem already
  handles comparable credentials: `RefreshToken` digests with SHA256, and
  `Session#lookup_hash` is SHA256.

  **Nothing is stranded.** Existing rows are never rewritten and no token
  rotation is needed. `Session#authenticate_token` reads the scheme off the
  *stored* digest — BCrypt digests are self-identifying by their `$2<x>$`
  prefix — so old and new digests verify side by side indefinitely. Sessions
  issued before upgrading keep working at their old cost until they expire or
  are re-issued; sessions issued after are fast.

  **Consumer impact — read this if you verify token digests yourself.** If you
  authenticate opaque session tokens through `Session.authenticate_by_token` or
  `Session#authenticate_token` (the API added in 0.30), there is nothing to do.

  If you still hand-roll the pre-0.30 pattern —

  ```ruby
  BCrypt::Password.new(session.token_digest) == token
  ```

  — **this release breaks you**, and loudly: a newly-created session's digest is
  a 64-character HMAC, so `BCrypt::Password.new` raises
  `BCrypt::Errors::InvalidHash` (or, if you rescue that, rejects every new
  session). That pattern was the only option before 0.30, so it is worth
  grepping for. Two ways out, either fine:

  1. **Switch to the gem's verifier** (recommended, and correct on both
     schemes): `StandardId::Session.api_compatible.active.authenticate_by_token(token)`,
     or `session.authenticate_token(token)` if you already hold the row.
  2. **Stay on BCrypt for now** by setting `config.session.token_digest_cost`
     to your preferred cost. New sessions keep being BCrypt-digested and your
     existing code keeps working, so you can migrate callers on your own
     schedule. You can flip it back at any time — the scheme is read off each
     stored digest, so mixing the two is always safe.

  **If you want BCrypt anyway**, set `config.session.token_digest_cost` to the
  cost you want; that setting now opts *in* to BCrypt rather than merely tuning
  it. Its previous meaning is preserved for anyone who set it deliberately, and
  changing it remains safe in both directions because the scheme is read off the
  stored digest, not off configuration.

## [0.31.0] - 2026-07-27

### Fixed

- **`EmailIdentifier` now rejects dot-atom violations in the local part.**
  `URI::MailTo::EMAIL_REGEXP` models the local part as one flat character class
  that happens to include `.`, so it accepted dot placements RFC 5322 forbids in
  an unquoted local part — a leading dot, a trailing dot, and consecutive dots.
  `a..b@example.com` passed it. Email service providers do not accept these:
  Postmark rejects them at *send* time with `InvalidEmailRequestError`, so a
  typo accepted at sign-up only surfaced much later as a failed delivery job,
  long after the user could have corrected it. The domain pattern is
  `URI::MailTo`'s own, unchanged; only the local part is stricter.

  **Consumer impact.** Addresses your app previously accepted may now be
  rejected at the identifier layer. The validation is scoped to a *changed*
  value, so rows created under the looser rule keep saving until someone edits
  the address — an existing account will not be locked out of a flow that merely
  stamps `verified_at`. Check any test fixtures or seeds using addresses with
  doubled or edge dots.

## [0.30.0] - 2026-07-26

### Added

- **`config.oauth.strict_redirect_uri_matching`** (default `false`). RFC 6749
  §4.1.3 requires a `redirect_uri` that was present at `/authorize` to be
  repeated, identically, at `/token`; the token endpoint previously only
  compared the values when the client bothered to send one, so omitting the
  parameter skipped the check entirely. Strictness is opt-in so the flip is
  deliberate. While it is off, a code minted **with** a `redirect_uri` that is
  redeemed **without** one logs a warning naming the `client_id` — watch for
  it, then set the flag to `true`. Codes minted without a `redirect_uri` are
  unaffected either way, and a *mismatched* value has always been (and remains)
  rejected.

- **`config.oauth.revocation_scope`** (default `:account`, the existing
  behaviour). `POST /oauth/revoke` bulk-revoked **every** active `DeviceSession`
  for the token's subject regardless of which token was presented, so one
  client's logout signed the account out everywhere. Setting it to `:grant`
  narrows revocation to the authorization grant behind the presented token
  (RFC 7009 §2.1): the refresh-token family its `jti` resolves to, plus that
  grant's `Session` when one is linked. A stateless access token resolves to no
  stored artifact and therefore revokes nothing under `:grant` (still `200`,
  per RFC 7009 §2.2) — present the refresh token. An unrecognised value logs a
  warning and falls back to `:account`. `ServiceSession`s remain untouched
  under both settings. The `OAUTH_TOKEN_REVOKED` event payload gains a
  `refresh_tokens_revoked` count alongside `sessions_revoked` (additive).

- **`Session.authenticate_by_token`** / **`Session#authenticate_token`**.
  `Session.by_token` matches only the SHA256 `lookup_hash` — an index key, not
  a credential — so every consumer hand-rolled the mandatory BCrypt verify
  against `token_digest` (and the `BCrypt::Errors::InvalidHash` rescue). The
  new entry point does the lookup and a constant-time digest comparison
  (`ActiveSupport::SecurityUtils.secure_compare`), honours the current scope
  (`Session.api_compatible.active.authenticate_by_token(token)`) and returns
  `nil` rather than raising for blank, unknown, mismatched, or malformed-digest
  tokens.

### Fixed

- `CHANGELOG.md` is now included in the published gem. The gemspec's file glob
  omitted it, so every release to date shipped without one even though the file
  has always existed in the repo — the only gem in the `standard_*` family
  missing it. No code change; `lib/`, `app/`, `config/`, and `db/` are unaffected.

## [0.29.1] - 2026-07-16

### Fixed

- **Signing in during an OAuth flow returned a 500 when `use_inertia` is on.**
  With `config.use_inertia = true`, the WebEngine's auth pages are Inertia
  components, so their form submits are Inertia XHRs. The three
  post-authentication redirects — passwordless OTP verify, password login, and
  signup — used a plain `redirect_to` to send the user on to whatever was
  stashed in `session[:return_to_after_authenticating]`. When that destination
  is a *non*-Inertia controller (the ApiEngine's `/api/authorize` in an OAuth
  round-trip), the Inertia client follows the redirect with the `X-Inertia`
  header still attached, and `inertia_rails`' middleware raises
  `NoMethodError: undefined method 'inertia_configuration'` — a 500 that broke
  MCP/OAuth sign-in outright.

  The root asymmetry: `inertia_rails` mixes its controller module in via
  `on_load(:action_controller_base)`, so `Web::BaseController`
  (`ActionController::Base`) gets `inertia_configuration` while
  `Api::BaseController` (`ActionController::API`) never does.

  All three sites now route through a shared `redirect_after_authentication`
  helper on `Web::BaseController`, which uses the existing
  `InertiaSupport#redirect_with_inertia` — already used for social login and
  signup — to emit a 409 + `X-Inertia-Location` so the browser performs a real
  page visit. Note this is keyed on the *request* being Inertia, not on the
  destination being cross-origin: the destination in the OAuth case is
  same-origin, so an external-only check would not have fixed it.

  The flash notice is now written before redirecting so it survives the
  Inertia branch (which cannot carry `redirect_to`'s `notice:` option).

- **Post-auth redirects to allow-listed deep links raised
  `UnsafeRedirectError`.** `safe_destination?` admits configured non-HTTP
  schemes (e.g. `myapp://`), but `redirect_to` rejects them without
  `allow_other_host:`. Now passed conditionally — mirroring
  `ProvidersController` — so Rails' same-origin backstop still applies to
  everything else. `safe_destination?` itself is unchanged.

## [0.29.0] - 2026-07-15

### Fixed

- **A rate-limited GET no longer drives an unbounded redirect loop.** The shared
  rate-limit handler bounced every tripped action to `request.path`. That is
  safe for a POST/PATCH (its sibling GET is a different action), but v0.28.0
  shipped the first rate-limited GETs — the email/phone verification-code
  *confirm* `#show` actions — so a tripped GET redirected to *itself*: the
  browser followed the redirect, re-incremented the counter, and got redirected
  again, an unbounded loop the victim's browser drives that also permanently
  resets the window. The handler now renders a terminal `429 Too Many Requests`
  on GET/HEAD (no redirect), and keeps the existing same-path redirect for
  non-GET web actions. API responses are unchanged.
- **The `Retry-After` header now reflects the tripped limit's real window.** It
  was hardcoded to 15 minutes, which was 4x too short for every 1-hour limit
  (`verification_start_per_ip`, `password_reset_start_per_ip`, `signup_per_ip`,
  `api_passwordless_start_per_ip`, `dynamic_registration_per_ip`). Each
  `rate_limit` declaration's `within:` is now threaded to the handler (captured
  in the per-limit `with:` closure the instant that limit trips, since
  `ActionController::TooManyRequests` carries no window and a controller may
  declare several limits with different windows), so `Retry-After` matches the
  window that actually fired. A hand-rolled `raise` that bypasses the macro
  falls back to 15 minutes.
- **Blank per-target rate-limit keys no longer collapse into one shared bucket.**
  Five per-target limiters interpolated a param that can be blank, yielding a
  stable key like `"reset-password:"` — a single global bucket (Rails'
  `.compact` does not drop a non-nil empty string), so blank-target spam from
  one source throttled every legitimate user. Affected: web login (by email),
  API passwordless start (by target), email/phone verification start (by
  target), and password-reset start (by email). Each now falls the key back to
  the remote IP when the target is blank, keeping blank spam bounded per-IP
  without poisoning real targets' buckets — mirroring the existing per-audience
  token limiter's "only count well-formed values" shape.

### Added

- **Mechanism-agnostic login rate-limit config: `rate_limits.login_per_ip`
  (default 20) and `rate_limits.login_per_email` (default 5).** The login
  `#create` action branches password OR passwordless, so on a passwordless app
  the existing `password_login_per_*` fields actually govern the OTP-send limit
  — a misnomer that led four consumer apps to write false config comments. The
  new names describe the action, not a mechanism. When unset they inherit the
  deprecated `password_login_*` values, so existing behaviour is unchanged; when
  set they win.

### Deprecated

- **`rate_limits.password_login_per_ip` / `rate_limits.password_login_per_email`
  are deprecated in favour of `login_per_ip` / `login_per_email`.** They remain
  fully honoured (the config schema rejects unknown fields at boot, so a host
  still setting the old names keeps working); the login controller reads the new
  alias and falls back to the deprecated field when the alias is left at its
  default. Follows the `max_attempts` → `max_attempts_per_challenge` alias
  precedent.

## [0.28.0] - 2026-07-12

### Added

- **Rate limiting on the last unprotected auth surfaces.** The web
  password-reset request (`reset_password/start`), password signup, and the
  email/phone code-*confirmation* endpoints now carry Rails-native
  `rate_limit`s, closing email-flooding, account-enumeration,
  account-creation-spam, and distributed code-guessing gaps. New config keys:
  `rate_limits.password_reset_start_per_ip` (10/hr),
  `rate_limits.password_reset_start_per_target` (3/15min), and
  `rate_limits.signup_per_ip` (10/hr); the confirm endpoints reuse
  `otp_verify_per_ip`. All use the existing `RateLimitStore` + centralized 429
  handler.
- **The `passwordless.retry_delay` OTP-resend cooldown is now enforced.**
  Previously the setting existed but did nothing. A resend for the same target
  within the window (default 30s) is rejected with an `InvalidRequestError`;
  the already-issued code stays valid. Set `retry_delay = 0` to disable.

## [0.27.0] - 2026-07-03

### Added

- **Loopback redirect URIs match on any port for public PKCE clients (RFC 8252
  §7.3).** Native apps receive the authorization response on an ephemeral
  local listener whose port cannot be known at registration time. When a
  public client with `require_pkce` presents a redirect URI whose scheme is
  `http` and whose host is a loopback literal (`127.0.0.1`, `::1`, or
  `localhost`), and a registered redirect URI is likewise a loopback URI, the
  comparison now ignores the port — host and path must still match exactly, so
  `127.0.0.1` and `localhost` do not cross-match (RFC 8252 §8.3 recommends the
  IP literals over `localhost`). Confidential clients and non-loopback URIs
  keep strict scheme+host+port+path matching. Registration-time validation is
  unchanged. Token exchange is unaffected: the redirect URI presented at the
  token endpoint is still compared byte-for-byte against the value stored when
  the code was issued.

## [0.26.4] - 2026-06-22

### Fixed

- **WebEngine controller redirects no longer drop the mount prefix on non-root
  mounts.** Isolated-engine `_path` helpers are mount-relative, and
  `redirect_to` / `redirect_with_inertia` (unlike `form_with` / `url_for` view
  URL generation) do not prepend the mount's `SCRIPT_NAME`. So when the engine
  was mounted at a non-root path (e.g. `mount StandardId::WebEngine => "/auth"`),
  redirects produced prefix-less paths that 404'd — most visibly `POST
  /auth/login` redirecting to `/login_verify` instead of `/auth/login_verify`,
  breaking passwordless login. Form actions were never affected. All affected
  redirects (`login` → `login_verify`; `login_verify` / reset-password →
  `login`; session revoke → `sessions`; account update → `account`; and the
  `after_sign_in` denial bounce) now prepend `request.script_name` via a new
  `engine_path` helper (a no-op for root mounts). Regression test added to
  `spec/integration/multi_mount_spec.rb`.

## [0.26.3] - 2026-06-15

### Fixed

- **Unauthenticated access to a protected web page no longer 500s.** The web
  authentication guard (`require_browser_session!`) raises
  `NotAuthenticatedError` / `InvalidSessionError` (for missing / expired /
  revoked sessions) rather than redirecting. The API base controller rescued
  these, but the web base controller did not — so an unauthenticated request to
  a protected web page (e.g. `/sessions`) surfaced as a 500 instead of bouncing
  to login. The web base controller now rescues both and redirects to the login
  page, preserving the original destination.

## [0.26.2] - 2026-06-15

### Security

- **OTP codes and password-reset tokens no longer leak into the logs.** The
  built-in mailers (`PasswordlessMailer`, `PasswordResetMailer`) pass the OTP
  code / reset URL as mailer params, which `deliver_later` serializes as the
  delivery job's arguments — and ActiveJob's log subscriber prints job arguments
  in plaintext on enqueue/perform (e.g. `params: {email:…, otp_code: "03158369"}`).
  StandardId's mailers now deliver via `StandardId::SecureMailDeliveryJob`
  (`ActionMailer::MailDeliveryJob` with `log_arguments = false`), so the
  arguments are kept out of the log stream. Delivery behaviour is unchanged.

## [0.26.1] - 2026-06-15

### Fixed

- **Passwordless `login_verify` OTP input now respects
  `config.passwordless.code_length`.** The built-in ERB verification-code field
  hardcoded `maxlength: 6`, so apps configuring a longer code (e.g.
  `code_length = 8`) rendered a field that truncated input to 6 characters —
  users could not enter the full code. The input now derives `maxlength` from
  `StandardId::Passwordless.otp_code_length` (the same clamped 4..10 value the
  OTP generator uses), exposed to views via a new
  `StandardId::ApplicationHelper#otp_code_length` helper, so the form and the
  generated code stay in sync end-to-end.
- **WebEngine rate-limit responses no longer 500 on hosts without a root
  route.** When a web auth action (login, login_verify, email/phone verification
  start) hit its rate limit, the handler redirected to
  `request.referer || main_app.root_path`. That raised — and returned a 500
  error page instead of the intended graceful response — for any host app that
  doesn't define a `root` route (e.g. an API/control-plane that only mounts the
  engine), and also for cross-origin `Referer` headers (Rails' open-redirect
  guard). The handler now redirects back to the rate-limited form's own path
  (`request.path`), which is always a valid same-origin GET. The ApiEngine
  responses (JSON `429`) are unchanged.
- **OAuth/OIDC metadata no longer advertises a `jwks_uri` under symmetric
  signing.** With the default HS256 (and HS384/HS512) there are no public keys
  to publish, so the JWKS endpoint deliberately returns 404 — but the
  authorization-server and openid-configuration documents advertised `jwks_uri`
  unconditionally, pointing clients at a dead URL. `jwks_uri` is now emitted only
  when signing is asymmetric (RS*/ES*). RFC 8414 makes it optional; HS-signed
  tokens are verified with the shared secret, not JWKS.
- **Sign-out / unauthenticated requests no longer leave a non-HttpOnly
  `session_token` cookie.** `clear_session!` assigned
  `cookies.encrypted[:session_token] = nil`, which wrote a fresh encrypted blob
  through the cookie jar's default options (no `HttpOnly`) on every
  unauthenticated request. It now uses `cookies.delete(:session_token)` to remove
  the cookie cleanly. The token-bearing sign-in write was already `httponly: true`
  and is unchanged, so this is a hygiene/consistency fix, not a token exposure.

## [0.26.0] - 2026-06-15

### Added

- **`config.passwordless.production_env_detector`** — an optional callable that
  decides whether the current deploy counts as "production" for the bypass-code
  guard. When `nil` (default) the gem falls back to `Rails.env.production?`, so
  existing consumers are unchanged. Apps that distinguish a physical deploy
  environment from `RAILS_ENV` (e.g. a staging box still running
  `RAILS_ENV=production`) can supply `-> { AppEnv.production? }` to permit a
  `bypass_code` on staging while it stays refused on real production. The guard
  in `Passwordless::VerificationService` (which also backs `Otp.verify`) now
  defers to this detector instead of checking `Rails.env.production?` directly.

## [0.25.0] - 2026-06-13

### Changed

- **Browser session cookie now persists across browser restarts.** The
  encrypted `session_token` cookie is written with an explicit `expires` tied
  to the `BrowserSession#expires_at` (previously a bare session cookie that was
  cleared on full browser close, logging users out well before their session
  actually expired). The cookie is also hardened with `httponly: true`,
  `same_site: :lax`, and `secure` following `request.ssl?`. Combined with a
  host-configured `session.browser_session_lifetime`, this lets a "remember me
  for N days" session survive closing and reopening the browser. Applies to
  both the sign-in and remember-token re-auth paths.

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
