# StandardId

A comprehensive authentication engine for Rails applications, built on the security primitives introduced in Rails 7/8. StandardId provides a complete, secure-by-default solution for identity management, reducing boilerplate and eliminating common security pitfalls.

## Features

### 🔐 Complete Authentication System
- **Web Authentication**: Cookie-based sessions with CSRF protection
- **API Authentication**: JWT-based tokens for API access
- **Dual Engine Architecture**: Separate web (`/`) and API (`/api`) endpoints
- **Session Management**: Browser sessions, device sessions, and service sessions with STI

### 🚀 OAuth 2.0 & OpenID Connect
- **Authorization Code Flow**: Standard OAuth flow with PKCE support
- **Implicit Flow**: For single-page applications
- **Client Credentials Flow**: For service-to-service authentication
- **Password Flow**: Direct username/password authentication
- **Refresh Token Flow**: Automatic token renewal
- **Social Login**: Google OAuth and Apple Sign In integration

### 📱 Passwordless Authentication
- **Email OTP**: Send one-time passwords via email
- **SMS OTP**: Send one-time passwords via SMS
- **Configurable Delivery**: Host app controls message delivery
- **10-minute Expiry**: Secure time-limited codes

### 🏢 Multi-Tenant Support
- **Client Management**: OAuth clients with secret rotation
- **Polymorphic Ownership**: Clients can belong to accounts, organizations, etc.
- **Scope Management**: Fine-grained permission control
- **Redirect URI Validation**: Secure callback handling

### 🔑 Advanced Security
- **PKCE Support**: Proof Key for Code Exchange
- **JWT Tokens**: Stateless authentication with configurable expiry
- **Secret Rotation**: Client secret management with audit trail
- **Remember Me**: Extended session support
- **Account Lockout**: Protection against brute force attacks

### ⚡ Frontend Framework Support
- **Inertia.js Integration**: Optional support for React, Vue, or Svelte frontends
- **Conditional Rendering**: Automatically switches between ERB and Inertia based on configuration
- **External Redirects**: Proper handling of OAuth redirects in SPA contexts

## Installation

Add this line to your application's Gemfile:

```ruby
gem "standard_id"
```

And then execute:
```bash
$ bundle install
```

## Quick Start

### 1. Generate Configuration

```bash
rails generate standard_id:install
```

### 2. Configure Your Account Model

```ruby
# config/initializers/standard_id.rb
StandardId.configure do |config|
  config.account_class_name = "User" # or "Account"
  config.issuer = "https://your-app.com"
  config.login_url = "/login"
end
```

### 3. Mount the Engines

```ruby
# config/routes.rb
Rails.application.routes.draw do
  mount StandardId::WebEngine, at: "/", as: :standard_id_web

  namespace :api do
    mount StandardId::ApiEngine, at: "/", as: :standard_id_api
  end
end
```

### 4. Include Authentication in Controllers

```ruby
# For web controllers
class ApplicationController < ActionController::Base
  include StandardId::WebAuthentication
end

# For API controllers
class ApiController < ActionController::API
  include StandardId::ApiAuthentication
end
```

## Configuration

### Basic Configuration

```ruby
StandardId.configure do |config|
  # Required: Your account model
  config.account_class_name = "User"

  # OAuth issuer for ID tokens
  config.issuer = "https://your-app.com"

  # Login URL for redirects
  config.login_url = "/login"

  # Custom layout for web views
  config.web_layout = "application"

  # Inertia.js support (see Inertia.js Integration section below)
  # config.use_inertia = true
  # config.inertia_component_namespace = "auth"

  # Session lifetimes
  # config.session.browser_session_lifetime = 86400      # 24 hours (web sessions)
  # config.session.browser_session_remember_me_lifetime = 2_592_000 # 30 days (remember me cookies)
  # config.session.device_session_lifetime = 2_592_000   # 30 days (API device sessions)
  # config.session.service_session_lifetime = 7_776_000  # 90 days (service-to-service sessions)

  # Passwordless delivery callbacks
  # config.passwordless_email_sender = ->(email, code) { UserMailer.send_code(email, code).deliver_now }
  # config.passwordless_sms_sender   = ->(phone, code) { SmsService.send_code(phone, code) }

  # Subset configuration
  # config.password.minimum_length = 12
  # config.password.require_special_chars = true
  # config.passwordless.code_ttl = 600
  # config.oauth.default_token_lifetime = 3600
  # config.oauth.refresh_token_lifetime = 2_592_000
  # config.oauth.token_lifetimes = {
  #   password: 8.hours.to_i,
  #   implicit: 15.minutes.to_i
  # }
end
```

`default_token_lifetime` is applied to every OAuth grant unless you override it in `oauth.token_lifetimes`. Keys map to OAuth grant types (for example `:password`, `:client_credentials`, `:refresh_token`) and should return durations in seconds. Non-token endpoint flows such as the implicit flow can be customized with their symbol key (e.g. `:implicit`). Refresh tokens can be tuned separately through `oauth.refresh_token_lifetime`.

### Custom Token Claims

You can add additional JWT claims for any token issued through the OAuth token endpoint by mapping scopes to claim names and providing callbacks to resolve each claim. Scopes listed in `oauth.scope_claims` are evaluated against the requested token scopes; when a scope matches, every claim listed for that scope is resolved via the callable defined in `oauth.claim_resolvers`.

```ruby
StandardId.configure do |config|
  config.oauth.scope_claims = {
    profile: %i[email display_name]
  }

  config.oauth.claim_resolvers = {
    email: ->(account:) { account.email },
    display_name: ->(account:, client:) {
      "#{account.name} for #{client.client_id}"
    }
  }
end
```

Resolvers receive keyword arguments with the context containing `client`, `account`, and `request`, so you can reference only what you need. This lets you, for example, pull organization info off the client application or decorate claims with account attributes.

### Social Login Setup

```ruby
StandardId.configure do |config|
  # Google OAuth
  config.social.google_client_id = ENV["GOOGLE_CLIENT_ID"]
  config.social.google_client_secret = ENV["GOOGLE_CLIENT_SECRET"]

  # Apple Sign In
  config.social.apple_mobile_client_id = ENV["APPLE_MOBILE_CLIENT_ID"]
  config.social.apple_client_id = ENV["APPLE_CLIENT_ID"]
  config.social.apple_private_key = ENV["APPLE_PRIVATE_KEY"]
  config.social.apple_key_id = ENV["APPLE_KEY_ID"]
  config.social.apple_team_id = ENV["APPLE_TEAM_ID"]
  config.social.allowed_redirect_url_prefixes = ["sidekicklabs://"]

  # Optional: adjust which attributes are persisted during social signup
  config.social.social_account_attributes = ->(social_info:, provider:) {
    {
      email: social_info[:email],
      name: social_info[:name] || social_info[:given_name]
    }
  }

  # Optional: run a callback whenever a social login completes
  config.social.social_callback = ->(social_info:, provider:, tokens:, account:) {
    AuditLog.social_login(
      provider: provider,
      email: social_info[:email],
      tokens: tokens,
      account_id: account.id,
    )
  }
end
```

`social_info` is an indifferent-access hash containing at least `email`, `name`, and `provider_id`.

### Inertia.js Integration

StandardId supports [Inertia.js](https://inertiajs.com/) for modern React, Vue, or Svelte frontends. When enabled, web controllers render Inertia components instead of ERB views.

#### Setup

1. Add the `inertia_rails` gem to your Gemfile:

```ruby
gem "inertia_rails"
```

2. Enable Inertia in your StandardId configuration:

```ruby
StandardId.configure do |config|
  config.use_inertia = true
  config.inertia_component_namespace = "auth" # Optional, defaults to "standard_id"
end
```

3. Create the corresponding frontend components. The component path follows the pattern:
   `{namespace}/{ControllerName}/{action}`

For example, with `inertia_component_namespace = "auth"`:
- Login page: `pages/auth/login/show.tsx`
- Signup page: `pages/auth/signup/show.tsx`

#### Example Component (React)

```tsx
// frontend/pages/auth/login/show.tsx
import { useForm } from '@inertiajs/react'

interface Props {
  redirect_uri: string
  connection: string | null
  flash: { notice?: string; alert?: string }
  social_providers: { google_enabled: boolean; apple_enabled: boolean }
}

export default function LoginShow({ redirect_uri, flash, social_providers }: Props) {
  const { data, setData, post, processing } = useForm({
    'login[email]': '',
    'login[password]': '',
    'login[remember_me]': false,
    redirect_uri,
  })

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault()
    post('/login')
  }

  const handleSocialLogin = (connection: string) => {
    post('/login', { data: { connection, redirect_uri } })
  }

  return (
    <div className="login-container">
      {flash.alert && <div className="alert alert-error">{flash.alert}</div>}
      {flash.notice && <div className="alert alert-success">{flash.notice}</div>}

      <form onSubmit={handleSubmit}>
        <div>
          <label htmlFor="email">Email</label>
          <input
            id="email"
            type="email"
            value={data['login[email]']}
            onChange={e => setData('login[email]', e.target.value)}
            required
          />
        </div>

        <div>
          <label htmlFor="password">Password</label>
          <input
            id="password"
            type="password"
            value={data['login[password]']}
            onChange={e => setData('login[password]', e.target.value)}
            required
          />
        </div>

        <div>
          <label>
            <input
              type="checkbox"
              checked={data['login[remember_me]'] as boolean}
              onChange={e => setData('login[remember_me]', e.target.checked)}
            />
            Remember me
          </label>
        </div>

        <button type="submit" disabled={processing}>
          {processing ? 'Signing in...' : 'Sign In'}
        </button>
      </form>

      {(social_providers.google_enabled || social_providers.apple_enabled) && (
        <div className="social-login">
          <p>Or continue with</p>
          {social_providers.google_enabled && (
            <button type="button" onClick={() => handleSocialLogin('google')}>
              Sign in with Google
            </button>
          )}
          {social_providers.apple_enabled && (
            <button type="button" onClick={() => handleSocialLogin('apple')}>
              Sign in with Apple
            </button>
          )}
        </div>
      )}
    </div>
  )
}
```

> **Note:** The `useForm` hook from `@inertiajs/react` automatically handles CSRF tokens. When you call `post()`, `put()`, `patch()`, or `delete()`, Inertia reads the CSRF token from the `<meta name="csrf-token">` tag in your layout and includes it in the request headers.

#### Props Passed to Components

Authentication pages receive the following props:

| Prop | Type | Description |
|------|------|-------------|
| `redirect_uri` | `string` | URL to redirect to after authentication |
| `connection` | `string \| null` | Social provider connection (if any) |
| `flash` | `{ notice?: string, alert?: string }` | Flash messages |
| `social_providers` | `{ google_enabled: boolean, apple_enabled: boolean }` | Available social providers |
| `errors` | `object` | Validation errors (on form submission failures) |

#### Using Authentication in Host App Controllers

You can use the `authenticate_account!` method in your own controllers to require authentication with Inertia-compatible redirects:

```ruby
class DashboardController < ApplicationController
  include StandardId::WebAuthentication

  before_action :authenticate_account!

  def show
    # Only authenticated users can access this
  end
end
```

This will redirect unauthenticated users to the login page using `inertia_location` for Inertia requests, ensuring proper SPA navigation.

### Passwordless Authentication

```ruby
StandardId.configure do |config|
  # Email delivery
  config.passwordless_email_sender = ->(email, code) {
    UserMailer.send_code(email, code).deliver_now
  }

  # SMS delivery
  config.passwordless_sms_sender = ->(phone, code) {
    SmsService.send_code(phone, code)
  }
end
```

## Event System

StandardId emits events throughout the authentication lifecycle using `ActiveSupport::Notifications`. This enables decoupled handling of cross-cutting concerns like logging, analytics, audit trails, and webhooks.

### Enabling Event Logging

Enable the built-in structured logging subscriber:

```ruby
StandardId.configure do |config|
  config.events.enable_logging = true
end
```

This outputs JSON-structured logs for all authentication events:

```json
{
  "subject": "standard_id.authentication.attempt.succeeded",
  "severity": "info",
  "duration": 50.25,
  "account_id": 123,
  "auth_method": "password",
  "ip_address": "192.168.1.1"
}
```

### Enabling Audit Logging

Enable the built-in audit log subscriber to persist high-signal security events to the `standard_id_audit_logs` table:

```ruby
StandardId.configure do |config|
  config.events.enable_audit_log = true

  # Optional: override the default event list (see DEFAULT_AUDIT_EVENTS for the full set)
  config.events.audit_events = [
    "authentication.attempt.succeeded",
    "authentication.attempt.failed",
    "session.created",
    "credential.password.changed"
  ]
end
```

When no custom list is provided, StandardId subscribes to `StandardId::Events::Subscribers::AuditLogSubscriber::DEFAULT_AUDIT_EVENTS`, which covers authentication attempts, session lifecycle, account status changes, credential changes, and other sensitive flows. Adding or removing event names in `audit_events` lets each host adjust the coverage without modifying the engine.

### Enabling Aggregated Metrics

Enable the built-in metrics subscriber to track authentication success/failure rates, session patterns, and other metrics using an efficient Postgres upsert pattern:

```ruby
StandardId.configure do |config|
  config.events.enable_metrics = true

  # Optional: set the time bucket granularity (default: :five_minutes)
  # Options: :one_minute, :five_minutes, :fifteen_minutes, :thirty_minutes, :one_hour
  config.events.metrics_bucket_size = :five_minutes
end
```

This creates aggregated metrics in the `standard_id_metrics` table. Instead of storing one row per event (which would explode storage), it increments counters per time bucket. For example, 1 million auth attempts per day results in only ~48 rows (success + failure × 24 hours).

#### Querying Metrics

```ruby
# Get authentication success rate for today
range = Time.current.beginning_of_day..Time.current.end_of_day
StandardId::Metric.success_rate(name: "auth.attempt", time_range: range)
# => 95.5 (percentage)

# Get total failed authentications this hour
StandardId::Metric.total_count(
  name: "auth.attempt",
  time_range: Time.current.beginning_of_hour..Time.current.end_of_hour,
  status: "failure"
)
# => 42

# Get average authentication latency
StandardId::Metric.average_duration(name: "auth.attempt", time_range: range)
# => 45.2 (milliseconds)

# Use scopes for quick queries
StandardId::Metric.for_metric("auth.attempt").today.successful.sum(:count)
StandardId::Metric.for_metric("session.created").this_hour.sum(:count)
```

#### Tracked Metrics

| Metric Name | Status Values | Description |
|-------------|---------------|-------------|
| `auth.attempt` | success, failure | Password authentication attempts |
| `auth.password` | success, failure | Password validation |
| `auth.otp` | success, failure | OTP validation |
| `session.created` | success | New sessions created |
| `session.revoked` | success | Sessions revoked |
| `session.expired` | success | Sessions expired |
| `account.created` | success | New accounts created |
| `account.locked` | success | Accounts locked |
| `oauth.token.issued` | success | OAuth tokens issued |
| `oauth.authorization` | success, failure | OAuth authorizations |
| `passwordless.code` | success, failure | Passwordless code verification |
| `social.auth` | success | Social login completions |

Additional dimensions (auth_method, provider, grant_type, error_code) are stored in the `dimensions` JSONB column for drill-down analysis.

### Available Events

| Category | Events |
|----------|--------|
| **Authentication** | `authentication.attempt.started`, `authentication.attempt.succeeded`, `authentication.attempt.failed`, `authentication.password.validated`, `authentication.password.failed`, `authentication.otp.validated`, `authentication.otp.failed` |
| **Session** | `session.creating`, `session.created`, `session.validating`, `session.validated`, `session.expired`, `session.revoked`, `session.refreshed` |
| **Account** | `account.creating`, `account.created`, `account.verified`, `account.status_changed`, `account.locked`, `account.unlocked` |
| **Identifier** | `identifier.created`, `identifier.verification.started`, `identifier.verification.succeeded`, `identifier.verification.failed`, `identifier.linked` |
| **OAuth** | `oauth.authorization.requested`, `oauth.authorization.granted`, `oauth.authorization.denied`, `oauth.token.issuing`, `oauth.token.issued`, `oauth.token.refreshed`, `oauth.code.consumed` |
| **Passwordless** | `passwordless.code.requested`, `passwordless.code.generated`, `passwordless.code.sent`, `passwordless.code.verified`, `passwordless.code.failed`, `passwordless.account.created` |
| **Social** | `social.auth.started`, `social.auth.callback_received`, `social.user_info.fetched`, `social.account.created`, `social.account.linked`, `social.auth.completed` |
| **Credential** | `credential.password.created`, `credential.password.reset_initiated`, `credential.password.reset_completed`, `credential.password.changed`, `credential.client_secret.created`, `credential.client_secret.rotated` |

### Subscribing to Events

#### Block-based (simple)

```ruby
# config/initializers/standard_id_events.rb
StandardId::Events.subscribe(StandardId::Events::AUTHENTICATION_SUCCEEDED) do |event|
  Analytics.track_login(
    account_id: event[:account].id,
    method: event[:auth_method],
    ip: event[:ip_address]
  )
end

# Subscribe to multiple events at once
StandardId::Events.subscribe(
  StandardId::Events::SESSION_CREATING,
  StandardId::Events::SESSION_VALIDATING,
  StandardId::Events::OAUTH_TOKEN_ISSUING
) do |event|
  # Handle all three events with the same block
  check_rate_limit(event[:account], event[:ip_address])
end

# Subscribe to events with pattern matching
StandardId::Events.subscribe(/social/) do |event|
  Rails.logger.info("Social event: #{event.name}")
end
```

#### Class-based (complex logic)

```ruby
# app/subscribers/audit_subscriber.rb
class AuditSubscriber < StandardId::Events::Subscribers::Base
  subscribe_to StandardId::Events::AUTHENTICATION_SUCCEEDED
  subscribe_to StandardId::Events::AUTHENTICATION_FAILED
  subscribe_to StandardId::Events::SESSION_REVOKED

  def call(event)
    AuditLog.create!(
      event_type: event.short_name,
      account_id: event[:account]&.id,
      ip_address: event[:ip_address],
      metadata: event.payload
    )
  end
end

# config/initializers/standard_id_events.rb
AuditSubscriber.attach
```

## Usage Examples

### Web Authentication

```erb
<!-- Login form -->
<%= form_with url: login_path, local: true do |f| %>
  <%= f.email_field :email, placeholder: "Email" %>
  <%= f.password_field :password, placeholder: "Password" %>
  <%= f.check_box :remember_me %>
  <%= f.label :remember_me, "Remember me" %>
  <%= f.submit "Sign In" %>
<% end %>
```

### OAuth Authorization

```ruby
# Redirect to authorization endpoint
redirect_to "/api/authorize?" + {
  response_type: "code",
  client_id: "your_client_id",
  redirect_uri: "https://your-app.com/callback",
  scope: "openid profile email",
  state: "random_state_value"
}.to_query
```

### Social Login

```ruby
# Google login
redirect_to "/api/authorize?" + {
  response_type: "code",
  client_id: "your_client_id",
  redirect_uri: "https://your-app.com/callback",
  connection: "google"
}.to_query

# Apple login
redirect_to "/api/authorize?" + {
  response_type: "code",
  client_id: "your_client_id",
  redirect_uri: "https://your-app.com/callback",
  connection: "apple"
}.to_query
```

### Passwordless Authentication

```ruby
# Start passwordless flow
POST /api/passwordless/start
{
  "connection": "email",
  "username": "user@example.com"
}

# Verify code
POST /api/passwordless/verify
{
  "connection": "email",
  "username": "user@example.com",
  "otp": "123456"
}
```

### API Authentication

```ruby
# In your API controllers
class Api::UsersController < ApiController
  before_action :authenticate_account!

  def show
    render json: current_account
  end
end
```

## Database Schema

StandardId creates the following tables:

- `standard_id_accounts` - User accounts
- `standard_id_identifiers` - Email/phone identifiers (STI)
- `standard_id_sessions` - Authentication sessions (STI)
- `standard_id_clients` - OAuth clients
- `standard_id_client_secret_credentials` - Client secrets
- `standard_id_password_credentials` - Password storage
- `standard_id_code_challenges` - OTP codes for authentication and verification

## API Endpoints

### Web Routes (mounted at `/`)
- `GET /login` - Login form
- `POST /login` - Process login
- `POST /logout` - Logout
- `GET /signup` - Signup form
- `POST /signup` - Process signup
- `GET /account` - Account management
- `GET /sessions` - Active sessions

### API Routes (mounted at `/api`)
- `GET /authorize` - OAuth authorization endpoint
- `POST /oauth/token` - Token exchange endpoint
- `GET /userinfo` - OpenID Connect userinfo
- `POST /passwordless/start` - Start passwordless flow
- `POST /passwordless/verify` - Verify OTP code
- `GET /oauth/callback/google` - Google OAuth callback
- `POST /oauth/callback/apple` - Apple Sign In callback

## Client Management

```ruby
# Create OAuth client
client = StandardId::ClientApplication.create!(
  owner: current_account,
  name: "My Application",
  redirect_uris: "https://app.com/callback",
  grant_types: ["authorization_code", "refresh_token"],
  response_types: ["code"],
  scopes: ["openid", "profile", "email"]
)

# Generate client secret
secret = client.create_client_secret!(name: "Production Secret")

# Rotate client secret
new_secret = client.rotate_client_secret!
```

## Schema DSL

Schema is declared using a routes-like DSL and can be extended by provider gems:

```ruby
# core gem (already provided)
require "standard_id/config/schema"

StandardConfig.schema.draw do
  scope :base do
    field :account_class_name, type: :string, default: "User"
  end

  scope :social do
    field :google_client_id, type: :string, default: nil
  end
end

# provider gem
require "standard_id/config/schema"

StandardConfig.schema.draw do
  scope :social do
    field :my_provider_client_id, type: :string, default: nil
  end
end
```

Notes:

- Multiple `schema.draw` calls are additive; the same scope can be extended in multiple files/gems.
- Redefining an existing field will emit a warning; last definition wins.

## Testing

StandardId includes comprehensive test coverage:

```bash
# Run all tests
bundle exec rspec

# Run specific test suites
bundle exec rspec spec/models/
bundle exec rspec spec/controllers/
```

## Security Considerations

- All passwords are hashed using bcrypt
- JWT tokens are signed and verified
- CSRF protection enabled for web requests
- Secure session management with proper expiry
- Client secrets are rotatable with audit trail
- PKCE support for public clients
- Rate limiting on authentication endpoints

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Write tests for your changes
4. Ensure all tests pass (`bin/rspec`)
5. Commit your changes (`git commit -am 'Add amazing feature'`)
6. Push to the branch (`git push origin feature/amazing-feature`)
7. Open a Pull Request

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
