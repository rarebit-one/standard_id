# StandardId Migration Guide

This guide helps you migrate between StandardId versions.

## Table of Contents

- [0.42 to 0.43: deprecated settings removed](#042-to-043-deprecated-settings-removed)
- [Adopting mount-aware discovery documents (0.33.0)](#adopting-mount-aware-discovery-documents-0330)
- [v0.1.x to v0.2.0](#v01x-to-v020)
- [v0.1.6 to v0.1.7](#v016-to-v017)

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
    UserMailer.send_code(event[:identifier], event[:code_challenge].code).deliver_now
  when "sms"
    SmsService.send_code(event[:identifier], event[:code_challenge].code)
  end
end
```

#### Event Payload

| Field | Type | Description |
|-------|------|-------------|
| `channel` | `String` | `"email"` or `"sms"` |
| `identifier` | `String` | The email address or phone number |
| `code_challenge` | `CodeChallenge` | Object with `.code` method returning the OTP |
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
