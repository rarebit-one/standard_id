# StandardId Migration Guide

This guide helps you migrate between StandardId versions.

## Table of Contents

- [Built-in step-up e-mail (unreleased)](#built-in-step-up-e-mail-unreleased)
- [Minted vs accepted audiences (unreleased, opt-in)](#minted-vs-accepted-audiences-unreleased-opt-in)
- [Upgrading to 0.62: what to do](#upgrading-to-062-what-to-do)
- [Step-up authentication (0.62, opt-in)](#step-up-authentication-062-opt-in)
- [Password pepper (0.62, opt-in)](#password-pepper-062-opt-in)
- [Reading the OTP code in delivery subscribers (0.62)](#reading-the-otp-code-in-delivery-subscribers-062)
- [One-time codes stored as digests; secret_key_base rotation (0.60)](#one-time-codes-stored-as-digests-secret_key_base-rotation-060)
- [E-mail domains must have a registered TLD (0.59)](#e-mail-domains-must-have-a-registered-tld-059)
- [Provider tokens leave SOCIAL_AUTH_COMPLETED (0.58)](#provider-tokens-leave-social_auth_completed-058)
- [Adopting the email + password API (0.55)](#adopting-the-email--password-api-055)
- [0.42 to 0.43: deprecated settings removed](#042-to-043-deprecated-settings-removed)
- [Adopting mount-aware discovery documents (0.33.0)](#adopting-mount-aware-discovery-documents-0330)
- [v0.1.x to v0.2.0](#v01x-to-v020)
- [v0.1.6 to v0.1.7](#v016-to-v017)

---

## Built-in step-up e-mail (unreleased)

Nothing to do unless you use step-up with built-in delivery
(`c.step_up.delivery = :built_in`, the default, and
`c.passwordless.delivery = :built_in`). In 0.62 the step-up code went out as
the generic `PasswordlessMailer#verification_email` ("Your verification
code"). It now goes out as `PasswordlessMailer#step_up_email` ("Confirm it's
you"), which says the user is confirming a sensitive action while already
signed in, when the code expires, and what to do if it wasn't them.

- If you had customised `standard_id.passwordless_mailer.verification_email.*`
  or its templates with step-up in mind, move that copy to
  `standard_id.passwordless_mailer.step_up_email.*` (keys `subject`,
  `greeting`, `intro`, `expiry`, `warning`, `footer`) or to
  `app/views/standard_id/passwordless_mailer/step_up_email.{html,text}.erb`.
- With `c.step_up.delivery = :custom` nothing changes: the engine sends
  nothing, and your `PASSWORDLESS_CODE_GENERATED` subscriber gets the realm
  (`c.step_up.realm`, default `"step_up"`) in the payload as before.

---

## Minted vs accepted audiences (unreleased, opt-in)

Nothing to do unless you want it. `c.oauth.allowed_audiences` keeps doing both
of its jobs (the audiences you may mint tokens for, and the audiences your API
accepts) until you set one of the two new settings:

- `c.oauth.mintable_audiences`: checked by every `/oauth/token` grant,
  `StandardId::TokenMinter` and the API step-up re-mint.
- `c.oauth.accepted_audiences`: what `Api::TokenManager` decodes bearers
  against; also what the production boot warning checks.

Each is `nil` (unset) by default and then falls back to `allowed_audiences`.
Set one and it replaces `allowed_audiences` for that side only. An identity
provider that mints per-service tokens should list the services as mintable
and keep accepted to its own API's audiences:

```ruby
# before: harness/inference tokens were also accepted on this app's API
c.oauth.allowed_audiences = %w[sidekick harness inference]

# after
c.oauth.allowed_audiences  = %w[sidekick]                    # or drop it
c.oauth.mintable_audiences = %w[sidekick harness inference]
c.oauth.accepted_audiences = %w[sidekick]
```

Check before you narrow `accepted_audiences`: a caller that sends a service
token to your own API (rather than to the service) gets `401` once that
audience is no longer accepted. An empty list you set explicitly means no
check on that side, like an empty `allowed_audiences`.

If you stubbed `StandardId.config.oauth.allowed_audiences` in specs, the stub
still works while the two new settings are unset. Engine code now reads the
effective lists through `StandardId::Oauth::Audiences.mintable` / `.accepted`.

---

## Upgrading to 0.62: what to do

**Required: install and run the one new migration**, even if you never turn
step-up on:

```bash
bin/rails standard_id:install:migrations
bin/rails db:migrate
```

`20261123000000_add_authenticated_at_to_standard_id_sessions` is the only
migration in 0.62. Strictly, the gem does not need it while
`c.step_up.enabled` is off: it checks for the column and writes neither
`authenticated_at` until it exists. But until it has run, the boot-time
migration check warns in development and test (and fails boot under
`c.missing_migrations = :raise`), and the `standard_id_migrations` health
check reports it as missing. Run it now, so that sign-ins start stamping
sessions and turning step-up on later needs no second deploy.

**Nothing else is required.** The rest of 0.62 is either opt-in or applies
by itself:

| Change | What you do |
| --- | --- |
| Step-up authentication | Opt-in. Off until `c.step_up.enabled = true`; see [below](#step-up-authentication-062-opt-in). |
| Password pepper | Opt-in. Off until `c.password.pepper` is set; see [below](#password-pepper-062-opt-in). |
| OTP code handoff (`Passwordless.issued_code`) | Nothing while `c.events.publish_records` is on (the default); see [below](#reading-the-otp-code-in-delivery-subscribers-062) before turning it off. |
| Re-keying session and registration access tokens used under a previous `secret_key_base` | Nothing. Automatic whenever `c.previous_secret_key_bases` is set; a no-op otherwise. |
| HS256/384/512 JWTs verified under `c.previous_secret_key_bases` | Nothing. Automatic whenever `c.previous_secret_key_bases` is set; a no-op otherwise. |

---

## Step-up authentication (0.62, opt-in)

One additive migration (see [above](#upgrading-to-062-what-to-do): install
and run it even if step-up stays off), then nothing changes until you set
`c.step_up.enabled = true` and call `require_recent_authentication!`.

```bash
bin/rails standard_id:install:migrations
bin/rails db:migrate
```

`20261123000000_add_authenticated_at_to_standard_id_sessions` adds a nullable
`authenticated_at` to `standard_id_sessions` and `standard_id_refresh_tokens`
(metadata-only on PostgreSQL). Until it has run, the gem writes neither
column. Once it has, interactive sign-ins stamp the session, and token grants
stamp their refresh tokens. That is one extra `UPDATE` per web sign-in and no
change to anything a client sees.

What changes only once you enable it:

- `/step_up` (web) and `POST /step_up`, `/step_up/verify` (API) are drawn.
  They 404 otherwise.
- Access tokens gain the OIDC `auth_time` claim. A `custom_claims` or
  `TokenMinter` `claims:` value named `auth_time` no longer reaches the token
  at all; pass `TokenMinter.mint(authenticated_at:)` instead.
- Sessions and refresh tokens from before the migration carry no time, so
  their holders step up once before a guarded action. So does any
  remember-me session, by design.
- **Implicit-flow tokens (`response_type=token`) carry no `auth_time`, so
  they must step up before every guarded action**, however recently the user
  signed in. This is deliberate. If a client still uses the implicit flow,
  move it to the authorization code flow with PKCE, whose tokens carry the
  browser session's sign-in time.
- **Refreshed access tokens keep the original sign-in's `auth_time`**; a
  refresh never makes a token more recent. An API step-up returns one access
  token with `auth_time` set to now and no refresh token. That token counts
  as recent for `within:` after the step-up, and never past its own expiry
  (about one access-token lifetime, `oauth.token_lifetimes[:step_up]`, else
  the default), whichever ends first. After the client refreshes, it holds
  the old sign-in time again and steps up again for the next guarded action
  outside `within:` of that sign-in.

Host code that wraps or replaces `StandardId::Oauth::OauthSessionPersistence.persist!`
should accept its new `authenticated_at:` keyword. The testing helper `create_browser_session` now stamps
`authenticated_at: Time.current`; pass `authenticated_at: nil` (or an older
time) to exercise the step-up path.

---

## Password pepper (0.62, opt-in)

Nothing changes unless you set `c.password.pepper`. With no pepper, digests,
verification and the timing of failed logins are exactly as before. A
`credential.password.rehashed` subscriber gets one new payload key,
`pepper_changed` (always `false` without a pepper).

To turn it on:

1. Generate a pepper (`SecureRandom.hex(32)`) and store it in your
   credentials next to `secret_key_base`, backed up the same way. **Losing it
   forces every password hashed under it to be reset.**
2. Set `c.password.pepper = Rails.application.credentials.password_pepper`
   and deploy. Nobody is locked out: existing digests still verify, and each
   user's next password login re-hashes under the pepper. That re-hash voids
   the user's other remember-me cookies and unused reset links, as a bcrypt
   cost change does. It needs `c.password.rehash_on_login`, which is on by
   default.
3. Leave `c.password.accept_unpeppered_passwords` on until no unpeppered
   digest can be left (see README, "Password pepper").

To rotate, move the old value into `c.password.previous_peppers` and set the
new one; keep the old value listed until everyone who might still sign in
with it has, or has been made to reset.

If you check a current password through `has_secure_password`'s
`password_challenge`, switch to `password_credential.authenticate(password)`:
the built-in challenge does not know about the pepper.

---

## Reading the OTP code in delivery subscribers (0.62)

No action is needed while `c.events.publish_records` is on (the default):
`event[:code_challenge].code` keeps working. Before turning it off, change
every `PASSWORDLESS_CODE_GENERATED` subscriber that reads the code to
`StandardId::Passwordless.issued_code(event)`:

```ruby
code = StandardId::Passwordless.issued_code(event)
```

With records off the payload has no `code_challenge`, and since 0.60 the
database holds only a digest, so before 0.62 there was no way left to
reach the code. `issued_code` hands it over out of band, only while the event
is being published, so it never enters the payload that audit and logging
subscribers serialise. Call it inside the subscriber and pass the string on: it
returns `nil` in a job that received the payload. The built-in mailer
(`passwordless.delivery = :built_in`) and `StandardId::Testing::OtpHelpers` use
it already, so both now work with records off.

---

## One-time codes stored as digests; secret_key_base rotation (0.60)

Passwordless and `StandardId::Otp` codes were stored in plaintext in
`standard_id_code_challenges.code`, so anyone who could read the table could
sign in with any active code. Challenges now store only `code_digest`, an
HMAC-SHA256 of the code keyed on `secret_key_base`.

**1. Install and run the migration.**

```bash
bin/rails standard_id:install:migrations
bin/rails db:migrate
```

`20261122000000_add_code_digest_to_standard_id_code_challenges` adds the
nullable `code_digest` column and drops `NOT NULL` from `code`. Both are
metadata-only on PostgreSQL, so it is safe on a busy table. Until it has run,
the gem keeps writing the plaintext column exactly as before, so deploying the
gem first breaks nothing (the boot-time missing-migration check reports it).

**2. Codes already sent keep working.** A challenge issued before the
migration has only the plaintext `code`, and is verified against it until it
expires (`passwordless.code_ttl`, 10 minutes by default). Two edges of a
rolling deploy: a code issued by an upgraded process and submitted to a
not-yet-upgraded one is refused as invalid (the user asks for a new code), and
the same is true of every code issued after the upgrade if you roll the gem
back. Rolling the migration back fails while digest-only rows exist; delete
them first (none is older than `code_ttl` if you are rolling back promptly).

**3. Read the raw code where it is issued, not from the database.**
`CodeChallenge#code` returns the raw code only on the record the engine just
created, which is the one in `PASSWORDLESS_CODE_GENERATED`'s `code_challenge:`
and behind `Otp.issue(delivery: :manual).code`. A challenge loaded from the
database returns `nil` (or, for a pre-migration row, its plaintext code). So:

- A delivery subscriber that reads `event[:code_challenge].code` and passes the
  **string** on (to a mailer, an SMS job) is unaffected.
- One that passes the **record** to a background job and reads `.code` there
  must pass the code string instead.
- Specs that read `StandardId::CodeChallenge.last.code` (or
  `.where(target:).last.code`) get `nil`. Capture the code as it is issued:
  `capture_otp_code(email) { post "/login", ... }` from
  `StandardId::Testing::OtpHelpers` (README, "Reading one-time codes in
  specs"). Challenges you create with `CodeChallenge.create!(code: "123456")`
  or the `:standard_id_code_challenge` factory still verify with that code.

`CodeChallenge#as_json` / `serializable_hash` no longer include `code` or
`code_digest`, so a subscriber that serialises the whole record stops writing
the code to audit rows and logs.

**4. Dropping the plaintext column.** A later release removes the `code`
column and the plaintext fallback, in a migration that is only safe once every
process runs this version (or later) and `code_ttl` has passed. Until then the
column holds only pre-migration codes, which expire within minutes and are
deleted by `CleanupExpiredCodeChallengesJob` (expired codes are kept 7 days).
To clear them sooner, once every process is upgraded and `code_ttl` has
passed:

```ruby
StandardId::CodeChallenge.where.not(code: nil).update_all(code: nil)
```

### Rotating secret_key_base without signing everyone out (opt-in)

Session tokens, the new code digests, authorization codes and RFC 7592
registration access tokens are all keyed on `secret_key_base`, so rotating it
used to invalidate every one of them. List the old secret in
`c.previous_secret_key_bases` and they are still accepted, while everything
new is written under the current secret:

```ruby
c.previous_secret_key_bases = [Rails.application.credentials.old_secret_key_base]
```

From 0.62 a session or registration access token used under
the old secret is re-keyed to the current one, so the entry is needed only
until the credentials you want to keep have been used once; before that, keep
it until the longest session lifetime you issue has passed. Rails'
own derived secrets (encrypted cookies, including the web session cookie, and
message verifiers) need Rails' rotations as well: see README, "Rotating
`secret_key_base`". HS256/384/512-signed JWTs are covered from 0.62; earlier versions do not verify them under previous secrets. Nothing
changes unless you set it.

### Password re-hashing and the password-changed notice

The other changes in 0.60 need no action by default; check them if they
apply to you.

- **Passwords are re-hashed on login when the bcrypt cost changed** (on by
  default). Nothing happens while every digest is at the cost
  `has_secure_password` uses. Once you change `BCrypt::Engine.cost`, each
  user's first successful password login rewrites their digest, which signs
  out their remember-me cookies on other browsers and voids unused
  password-reset links. Turn it off with `c.password.rehash_on_login = false`.
  Subscribe to `credential.password.rehashed` to observe it.
- **`credential.password.changed` is now published**, after commit, whenever
  a password is changed or reset. A subscriber you wrote for it starts firing.
  Its payload carries `reason` (`:password_reset` or `:changed`); the
  documented `changed_by` field, which was never sent, is gone.
- **The built-in "your password was changed" email is opt-in.**
  `c.password.changed_notice_delivery` defaults to `:custom`, which sends
  nothing. If you already send your own notice (for example from a
  `credential.password.reset_completed` subscriber), leave it at `:custom`, or
  the owner gets two emails. Otherwise, `:built_in` sends
  `StandardId::AccountNoticeMailer#password_changed` on every password change
  and reset.

---

## E-mail domains must have a registered TLD (0.59)

A passwordless code request on an `email` connection, and a new or edited
`StandardId::EmailIdentifier`, now fail when the address's domain does not end
in an ICANN-registered TLD or an allowed special-use one
(`StandardId::EmailDomain.allowed?`). Real addresses are unaffected; check your
test suite and seeds:

- **Special-use TLDs still pass.** `.test`, `.example`, `.invalid`,
  `.localhost` and `.local` are accepted by default
  (`c.email.allowed_special_use_tlds`), so `user@example.test` fixtures and
  synthetic accounts such as `agent+1@agents.app.invalid` keep working. Other
  TLDs outside the Public Suffix List (`.lan`, `.internal`, `.corp`) are
  rejected: add them to that list or use a real TLD.
- **Rows already stored are not re-checked** (the validation runs only when
  the value changes), so existing accounts keep signing in.
- **Your own e-mail validator** (a Truemail wrapper, a
  `passwordless.username_validator`) can call
  `StandardId::EmailDomain.allowed?(email)` so sign-up forms and the code
  flow agree. The gem's check runs before `username_validator`.

---

## Provider tokens leave SOCIAL_AUTH_COMPLETED (0.58)

`SOCIAL_AUTH_COMPLETED` no longer carries `tokens:` (the provider's access,
refresh and id tokens). An audit subscriber that copied the whole payload was
storing the id_token. Check your subscribers for `event[:tokens]`:

- None read it: nothing to do.
- One needs the tokens to call the provider: read `provider_tokens:` in
  `c.social.before_mint` / `before_account` instead (API callback), or set
  `c.events.publish_provider_tokens = true` and make sure the payload that
  subscriber sees is not also written to an audit log.

Audit rows written before the upgrade are unchanged.

---

## Adopting the email + password API (0.55)

0.55 adds an opt-in email + password API (`c.email_password`; see the README's
"Email + password API"). Nothing changes until you set
`c.email_password.enabled = true`. If your app hand-rolled the same flow, move
onto it like this:

1. **Run the migration.** `bin/rails standard_id:install:migrations && bin/rails
   db:migrate` adds `standard_id_identifiers.signup_source`. The API's sign-up
   sets it to `"email_password"`; a reset runs `after_email_verified` only for
   such sign-ups, and the purge job deletes only those. Sign-ups your own flow
   left pending have none, so backfill the ones that should count as API
   sign-ups (say, unverified email identifiers with a password credential and a
   code in your verification realm) to `"email_password"`.
2. **Map your hooks.** Rate-limit network key → `client_key`; extra password
   checks (e.g. breached passwords) → `password_validator`; profile
   provisioning after verification → `after_email_verified`; "this account is
   real" for the purge job → `account_in_use`; `require_name` /
   `name_max_length` for the name rules.
3. **Keep your error envelope**, if clients depend on it, with
   `error_renderer`, mapping the `EmailPasswordError` codes onto your own.
4. **Keep or change the paths.** The routes are `POST /auth/...` under the API
   engine's mount. Delete your own routes and controllers once clients call
   these. Unlike a plain Rails controller, the engine requires
   `Content-Type: application/json`.
5. **Replace your purge job** with `StandardId::PurgeUnverifiedEmailSignupsJob`
   in your scheduler, and call
   `StandardId::EmailPassword.discard_pending_credentials!` from your
   `social.account.linked` subscriber if you link social sign-ins by email.
6. **Expect these differences:**
   - The sign-up code goes out as `PasswordlessMailer#verification_email` (set
     `code_delivery = :custom` to send your own).
   - `login_method_policy` sees `flow: :api_email_password`.
   - The pending sign-up's name is kept in the code challenge's
     `metadata["name"]`.
   - The daily caps count under new keys in `c.cache_store`, so counts from your
     own implementation do not carry over (each starts at zero on deploy).
   - Nothing emails the user when a reset completes. Subscribe to
     `credential.password.reset_completed` to send a "password changed" notice,
     or (0.60+) set `c.password.changed_notice_delivery = :built_in` to
     have the engine send one.

---

## 0.42 to 0.43: deprecated settings removed

Everything 0.42 deprecated is gone. If your app booted under 0.42 without a
`StandardId` deprecation warning, **there is nothing to change**. Assigning a
removed setting now raises `StandardId::ConfigurationError` at boot, naming the
replacement:

| Removed | Use instead |
|---|---|
| `c.passwordless_email_sender`, `c.passwordless_sms_sender` | A `StandardId::Events::PASSWORDLESS_CODE_GENERATED` subscriber (skip when `event[:skip_sender]`) with `c.passwordless.delivery = :custom` — see [v0.1.6 to v0.1.7](#v016-to-v017) |
| `c.passwordless.enabled` | `c.web.passwordless_login` (it had no effect since 0.8) |
| `c.oauth.client_id`, `c.oauth.client_secret` | Nothing — never read. Clients are `ClientApplication` / `ClientSecretCredential` records |
| `c.rate_limits.password_login_per_ip`, `password_login_per_email` | `c.rate_limits.login_per_ip`, `login_per_email` |
| Scope config `profile_type: "X"` | `profile_types: ["X"]` (the singular key raises at boot instead of being ignored — ignoring it would drop the scope's profile requirement) |
| `Providers::Base.setup` hook (a provider defining `setup` had it called with a warning) | Do the work in the plugin's Railtie; `setup` is no longer called |
| `StandardId::ScopeConfig::DEPRECATOR`, `StandardId::ProviderRegistry::DEPRECATOR` | `StandardId.deprecator` |

**`StandardId::Otp.issue(delivery: :custom)`** no longer calls a sender callback.
It publishes `PASSWORDLESS_CODE_GENERATED` with `delivery: :custom` in the
payload and the engine's built-in mailer stays out of it, so your subscriber
delivers the code even where `c.passwordless.delivery` is `:built_in`. Nothing
is sent unless you subscribe.

**WebEngine `verify_email` / `verify_phone` start actions** now issue their code
through `Otp.issue` (realm `"verification"`), so it is delivered by the same
subscriber (or the built-in mailer under `delivery: :built_in`). They used to
call the sender callbacks directly and sent nothing without them.

---

## Adopting mount-aware discovery documents (0.33.0)

**Nothing here is required to upgrade.** The default document is byte-identical
to 0.32.0's. This is how to *delete* a hand-rolled replacement controller.

### The defect

`Oauth::DiscoveryDocument` derived every endpoint from the issuer:

```ruby
base = issuer.to_s.chomp("/")   # 0.32.0
```

If you mount `ApiEngine` under a prefix your issuer does not carry — `/api`,
`/api/v1` — the document advertised `<issuer>/oauth/token` while the endpoint
actually lived at `<origin>/api/oauth/token`. Every advertised endpoint 404'd.
Both documents were affected; the OIDC one had the identical bug.

Separately, the gem could only route `.well-known/*` *inside* its mount, while
RFC 8615 clients probe the **origin root** — which is outside any engine mount,
so the gem could not draw those routes at all.

### 1. Point endpoints at the mount

```ruby
# config/initializers/standard_id.rb
c.oauth.discovery_endpoint_base = :request
```

`:request` resolves to `request.base_url` + the mount path. Inside the mount the
mount path comes from `SCRIPT_NAME`, so it is exact rather than detected.

`issuer` is untouched by this and stays exactly `config.issuer`. That is
deliberate: RFC 8414 §2 makes it a stable security identifier clients match
byte-for-byte against both their discovery URL and the `iss` claim.

Other forms:

| value | meaning |
|---|---|
| `nil` (default) | the issuer — 0.32.0 behaviour |
| `:request` | `request.base_url` + detected mount path |
| `"https://…"` | verbatim |
| `->(request:) { … }` | for a proxy that rewrites `base_url`, or an app mounting `ApiEngine` more than once (e.g. under host constraints) where no single detected path is right |

### 2. Serve the documents at the origin root

```ruby
# config/routes.rb — BEFORE your engine mounts
Rails.application.routes.draw do
  standard_id_well_known_routes at: "/api/v1"

  scope "/api/:api_version", constraints: { api_version: /v\d+/ } do
    mount StandardId::ApiEngine, at: "/", as: :standard_id_api
  end
end
```

For each metadata document this draws **both**:

```
/.well-known/oauth-authorization-server
/.well-known/oauth-authorization-server/api/v1     <- RFC 8414 §3.1
```

**The second is not redundant, and dropping it breaks real clients.** RFC 8414
§3.1 inserts the well-known segment *before* a path-carrying issuer's path rather
than appending to it, and that is the URL Claude Code actually requests in
production. Without it the client 404s, falls back to issuer-relative defaults —
hitting the engine's own `/authorize` instead of a host audience shim — and every
subsequent authenticated request 401s. The failure surfaces a long way from its
cause, which is why the route is drawn for you.

Keeping your own metadata controller but want the gem's JWKS at the root?

```ruby
standard_id_well_known_routes at: "/api/v1", only: :jwks
```

`only:`/`except:` take `:oauth_authorization_server`, `:openid_configuration`,
`:jwks`. `extra_paths:` adds further path-inserted suffixes; `path_inserted:
false` draws only the bare root forms (this reintroduces the failure above, so it
is for apps that route those themselves).

### 3. Supply what cannot be derived

```ruby
c.oauth.discovery_metadata_overrides = {
  # A host-owned shim that injects the audience before handing off to the
  # engine's /authorize. The gem cannot guess this, and it is why every
  # consuming app hand-rolled a controller in the first place.
  authorization_endpoint: ->(ctx) { "#{ctx[:origin]}/oauth/authorize" },
  registration_endpoint:  ->(ctx) { "#{ctx[:origin]}/oauth/register" },
  jwks_uri:               ->(ctx) { "#{ctx[:origin]}/.well-known/jwks.json" },

  # Deliberately narrower than everything the server can mint.
  scopes_supported: %w[mcp mcp:read],
  grant_types_supported: %w[authorization_code refresh_token],

  # MUST mirror your dynamic-registration policy. Advertising client_secret_*
  # while DCR only accepts public clients makes spec-following clients register
  # in a way DCR then rejects — this was a real production failure.
  token_endpoint_auth_methods_supported: %w[none],

  # nil REMOVES a member rather than emitting null.
  userinfo_endpoint: nil
}
```

Callables receive `{ origin:, endpoint_base:, issuer:, request: }`, where
`origin` is scheme+host+port with no path. Static values are used as-is.

**Setting `issuer` raises `StandardId::ConfigurationError`.** Use
`discovery_endpoint_base` to move where the endpoints live.

### 4. Delete the local controller

Once the document matches, remove your `WellKnown::AuthorizationServerMetadataController`
(or equivalent) and its routes. Diff the two documents first — the gem's includes
members a hand-rolled one may have omitted (`code_challenge_methods_supported`,
`subject_types_supported`, `id_token_signing_alg_values_supported`), which is a
gain, not a regression.

---

## v0.1.x to v0.2.0

### Social Login Providers Extracted to Separate Gems

Apple and Google OAuth providers have been extracted from the core `standard_id` gem into separate gems. This allows for more flexible versioning and reduces the core gem's dependencies.

#### Required Changes

Add the provider gems you need to your `Gemfile`:

```ruby
# Apple Sign In (optional - only if you use Apple OAuth)
gem "standard_id-apple", "~> 0.1.1"

# Google Sign In (optional - only if you use Google OAuth)
gem "standard_id-google", "~> 0.1.1"
```

Then run:

```bash
bundle install
```

#### Configuration

**No configuration changes required.** Your existing social provider configuration continues to work exactly as before:

```ruby
StandardId.configure do |config|
  # Apple configuration (if using standard_id-apple gem)
  config.social.apple_client_id = ENV["APPLE_CLIENT_ID"]
  config.social.apple_team_id = ENV["APPLE_TEAM_ID"]
  config.social.apple_key_id = ENV["APPLE_KEY_ID"]
  config.social.apple_private_key = ENV["APPLE_PRIVATE_KEY"]

  # Google configuration (if using standard_id-google gem)
  config.social.google_client_id = ENV["GOOGLE_CLIENT_ID"]
  config.social.google_client_secret = ENV["GOOGLE_CLIENT_SECRET"]
end
```

#### Migration Steps

1. Add the provider gems to your `Gemfile` (see above)
2. Run `bundle install`
3. No code changes needed - existing configuration and routes continue to work

---

## v0.1.6 to v0.1.7

### Passwordless Code Delivery

The `passwordless_email_sender` and `passwordless_sms_sender` configuration options were deprecated here and **removed in 0.43** (assigning them now raises `StandardId::ConfigurationError`). Migrate to event-based subscriptions, and set `c.passwordless.delivery = :custom` so the engine's built-in mailer stays out of the way.

**Before (removed in 0.43):**

```ruby
StandardId.configure do |config|
  config.passwordless_email_sender = ->(email, code) {
    UserMailer.send_code(email, code).deliver_now
  }

  config.passwordless_sms_sender = ->(phone, code) {
    SmsService.send_code(phone, code)
  }
end
```

**After (recommended):**

```ruby
# config/initializers/standard_id_events.rb
StandardId::Events.subscribe(StandardId::Events::PASSWORDLESS_CODE_GENERATED) do |event|
  next if event[:skip_sender] # Otp.issue(delivery: :manual) — the caller delivers
  case event[:channel]
  when "email"
    UserMailer.send_code(event[:identifier], StandardId::Passwordless.issued_code(event)).deliver_now
  when "sms"
    SmsService.send_code(event[:identifier], StandardId::Passwordless.issued_code(event))
  end
end
```

#### Event Payload

| Field | Type | Description |
|-------|------|-------------|
| `channel` | `String` | `"email"` or `"sms"` |
| `identifier` | `String` | The email address or phone number |
| `code_challenge` | `CodeChallenge` | The challenge record (left out under `events.publish_records = false`); read the OTP with `StandardId::Passwordless.issued_code(event)` |
| `expires_at` | `Time` | When the code expires |
| `realm` | `String` | The OTP realm (`"authentication"` for sign-in) |
| `skip_sender` | `Boolean` | `true` for `Otp.issue(delivery: :manual)` — don't deliver |
| `delivery` | `Symbol, nil` | The `Otp.issue` delivery mode (`:built_in` / `:custom` / `:manual`); `nil` when not issued through `Otp.issue` |

#### Migration Steps

1. Create `config/initializers/standard_id_events.rb`
2. Add the event subscription (see example above)
3. Remove `passwordless_email_sender` and `passwordless_sms_sender` from your configuration
4. Test that OTP codes are still being delivered

For more details on the event system, see the [Event System](../README.md#event-system) section in the README.
