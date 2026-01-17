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

### 5. Action Cable Authentication

- Include in Your Connection Class
```ruby
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    include StandardId::CableAuthentication
  end
end
```

- Access Current Account in Channels
```ruby
class ChatChannel < ApplicationCable::Channel
  def subscribed
    stream_for current_account
  end
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
end
```

`social_info` is an indifferent-access hash containing at least `email`, `name`, and `provider_id`.

To handle social login completion (e.g., for analytics or audit logging), subscribe to the `SOCIAL_AUTH_COMPLETED` event:

```ruby
# config/initializers/standard_id_events.rb
StandardId::Events.subscribe(StandardId::Events::SOCIAL_AUTH_COMPLETED) do |event|
  Analytics.track_social_login(
    provider: event[:provider],
    account_id: event[:account].id,
    tokens: event[:tokens]
  )
end
```

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

### Passwordless Code Delivery

Subscribe to the `PASSWORDLESS_CODE_GENERATED` event to deliver OTP codes:

```ruby
# config/initializers/standard_id_events.rb
StandardId::Events.subscribe(StandardId::Events::PASSWORDLESS_CODE_GENERATED) do |event|
  case event[:channel]
  when "email"
    UserMailer.send_code(event[:identifier], event[:code_challenge].code).deliver_now
  when "sms"
    SmsService.send_code(event[:identifier], event[:code_challenge].code)
  end
end
```

Event payload includes:
- `channel` - `"email"` or `"sms"`
- `identifier` - The email address or phone number
- `code_challenge` - The code challenge object with `.code` method
- `expires_at` - When the code expires

> **Note**: If you're using the deprecated `passwordless_email_sender` or `passwordless_sms_sender` callbacks, see the [Migration Guide](docs/MIGRATION_GUIDE.md) for upgrade instructions.

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

### Available Events

Every StandardId event automatically carries tracing metadata (`event_id`, `timestamp`, and request-scoped fields like `request_id`, `ip_address`, `user_agent`, `current_account` when available). The table below lists the domain-specific payload fields and when each event fires.

| Category | Event | Payload fields | When emitted |
|----------|-------|----------------|--------------|
| Authentication | `authentication.attempt.started` | `account_lookup`, `auth_method` | Before credential validation begins |
|  | `authentication.attempt.succeeded` | `account`, `auth_method`, `session_type` | After authentication succeeds |
|  | `authentication.attempt.failed` | `account_lookup`, `auth_method`, `error_code`, `error_message` | After authentication fails |
|  | `authentication.password.failed` | `account_lookup`, `error_code`, `error_message` | After password verification fails |
|  | `authentication.otp.failed` | `identifier`, `channel`, `error_code`, `error_message` | After OTP verification fails |
| Session | `session.creating` | `account`, `session_type`, `ip_address`, `user_agent` | Before a session record is created |
|  | `session.created` | `session`, `account`, `session_type`, `token_issued`, `ip_address`, `user_agent` | After session persistence completes |
|  | `session.validating` | `session` | Before validating an existing session |
|  | `session.validated` | `session`, `account` | After a session passes validation |
|  | `session.expired` | `session`, `account`, `expired_at` | When validation fails because the session expired |
|  | `session.revoked` | `session`, `account`, `reason` | After a session is explicitly revoked |
|  | `session.refreshed` | `session`, `account`, `old_expires_at`, `new_expires_at` | After a refresh operation extends a session |
| Account | `account.creating` | `account_params`, `auth_method` | Before an account record is created |
|  | `account.created` | `account`, `auth_method`, `source` (signup/passwordless/social) | After an account record is created |
|  | `account.verified` | `account`, `verified_via` (email/phone) | When an account is marked verified |
|  | `account.status_changed` | `account`, `old_status`, `new_status`, `changed_by` | When account status transitions (Issue #16) |
|  | `account.locked` | `account`, `lock_reason`, `locked_by` | When an account is administratively locked (Issue #17) |
|  | `account.unlocked` | `account`, `unlocked_by` | When an account lock is lifted (Issue #17) |
| Identifier | `identifier.created` | `identifier`, `account` | After an identifier record is created |
|  | `identifier.verification.started` | `identifier`, `channel` (email/sms), `code_sent` | After a verification code is issued |
|  | `identifier.verification.succeeded` | `identifier`, `account`, `verified_at` | After identifier verification succeeds |
|  | `identifier.verification.failed` | `identifier`, `error_code`, `attempts` | After identifier verification fails |
|  | `identifier.linked` | `identifier`, `account`, `source` (social/manual) | When an identifier is associated to an account |
| OAuth | `oauth.authorization.requested` | `client_id`, `account`, `scope`, `redirect_uri` | Before issuing an authorization code |
|  | `oauth.authorization.granted` | `authorization_code`, `client_id`, `account`, `scope` | After an authorization code is created |
|  | `oauth.authorization.denied` | `client_id`, `account`, `reason` | When a user denies authorization |
|  | `oauth.token.issuing` | `grant_type`, `client_id`, `account`, `scope` | Before generating access/refresh tokens |
|  | `oauth.token.issued` | `access_token_id`, `grant_type`, `client_id`, `account`, `expires_in` | After tokens are generated |
|  | `oauth.token.refreshed` | `old_token_id`, `new_token_id`, `client_id`, `account` | After a refresh token is redeemed |
|  | `oauth.code.consumed` | `authorization_code`, `client_id`, `account` | After an authorization code is exchanged |
| Passwordless | `passwordless.code.requested` | `identifier`, `channel` (email/sms) | Before generating an OTP |
|  | `passwordless.code.generated` | `code_challenge`, `identifier`, `channel`, `expires_at` | After an OTP is created |
|  | `passwordless.code.sent` | `identifier`, `channel`, `delivery_status` | After an OTP is delivered |
|  | `passwordless.code.verified` | `code_challenge`, `account`, `channel` | After OTP verification succeeds |
|  | `passwordless.code.failed` | `identifier`, `channel`, `attempts` | After OTP verification fails |
|  | `passwordless.account.created` | `account`, `channel`, `identifier` | When an account is created via passwordless flow |
| Social | `social.auth.started` | `provider`, `redirect_uri`, `state` | Before redirecting to a social provider |
|  | `social.auth.callback_received` | `provider`, `code`, `state` | After the provider redirects back |
|  | `social.user_info.fetched` | `provider`, `social_info`, `email` | After fetching user info from the provider |
|  | `social.account.created` | `account`, `provider`, `social_info` | When a social login creates a new account |
|  | `social.account.linked` | `account`, `provider`, `identifier` | When a social identity links to an existing account |
|  | `social.auth.completed` | `account`, `provider`, `tokens` | After social login completes |
| Credential | `credential.password.created` | `credential`, `account` | After a password credential is created |
|  | `credential.password.reset_initiated` | `credential`, `account`, `reset_token_expires_at` | After a password reset is initiated |
|  | `credential.password.reset_completed` | `credential`, `account` | After a password reset is confirmed |
|  | `credential.password.changed` | `credential`, `account`, `changed_by` | After a password is updated |
|  | `credential.client_secret.created` | `credential`, `client_id` | After a client secret is created |
|  | `credential.client_secret.rotated` | `credential`, `client_id`, `old_secret_revoked_at` | After a client secret rotation |

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
  subscribe_to StandardId::Events::SECURITY_EVENTS

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

## Account Status (Activation/Deactivation)

StandardId provides an optional `AccountStatus` concern for managing account activation and deactivation. This uses Rails enum with the event system to enforce status checks and handle side effects without modifying core authentication logic.

### Setup

1. Add a migration for the status column. For PostgreSQL (recommended), use a native enum type:

```ruby
# PostgreSQL with native enum (recommended)
class AddStatusToUsers < ActiveRecord::Migration[8.0]
  def up
    create_enum :account_status, %w[active inactive]

    add_column :users, :status, :enum, enum_type: :account_status, default: "active", null: false
    add_column :users, :activated_at, :datetime
    add_column :users, :deactivated_at, :datetime
  end

  def down
    remove_column :users, :status
    remove_column :users, :activated_at
    remove_column :users, :deactivated_at

    drop_enum :account_status
  end
end
```

For other databases (MySQL, SQLite), use a string column:

```ruby
# String column (MySQL, SQLite)
class AddStatusToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :status, :string, default: "active", null: false
    add_column :users, :activated_at, :datetime
    add_column :users, :deactivated_at, :datetime
    add_index :users, :status
  end
end
```

2. Include the concern in your account model:

```ruby
class User < ApplicationRecord
  include StandardId::AccountStatus
  # ...
end
```

The concern works with both PostgreSQL enum and string columns - Rails enum handles both transparently.

### Usage

```ruby
# Deactivate an account
user.deactivate!
# => Emits ACCOUNT_DEACTIVATED event
# => All active sessions are automatically revoked

# Reactivate an account
user.activate!
# => Emits ACCOUNT_ACTIVATED event
# => User can log in again

# Check status
user.active?    # => true/false
user.inactive?  # => true/false

# Query scopes
User.active     # => Users with status 'active'
User.inactive   # => Users with status 'inactive'
```

### Handling AccountDeactivatedError

When an inactive account attempts to authenticate, `StandardId::AccountDeactivatedError` is raised. You need to handle this error in your application controller:

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include StandardId::WebAuthentication

  rescue_from StandardId::AccountDeactivatedError, with: :handle_account_deactivated

  private

  def handle_account_deactivated
    # For web requests, redirect with a message
    redirect_to login_path, alert: "Your account has been deactivated. Please contact support."
  end
end
```

For API controllers:

```ruby
# app/controllers/api/base_controller.rb
class Api::BaseController < ActionController::API
  include StandardId::ApiAuthentication

  rescue_from StandardId::AccountDeactivatedError, with: :handle_account_deactivated

  private

  def handle_account_deactivated
    render json: {
      error: "account_deactivated",
      message: "Your account has been deactivated"
    }, status: :forbidden
  end
end
```

## Account Locking (Administrative Security)

StandardId provides an optional `AccountLocking` concern for administrative account locking. This is distinct from account deactivation - locking is for security enforcement by administrators, while deactivation is for lifecycle management.

### Key Differences from Account Deactivation

| Feature | Account Status | Account Locking |
|---------|---------------|-----------------|
| **Purpose** | Lifecycle management | Security enforcement |
| **Who Controls** | System/User | Admin/Staff only |
| **User Reversible** | Yes (future) | No |
| **Use Cases** | Inactivity, user choice | Policy violation, security incident, fraud |

An account can be in any combination:
- Active + Unlocked ✅ (normal operation)
- Active + Locked ⚠️ (admin locked for security)
- Inactive + Unlocked ⚠️ (deactivated but not locked)
- Inactive + Locked 🚫 (both restrictions apply)

### Setup

1. Add a migration for the locking columns:

```ruby
class AddLockingToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :locked, :boolean, default: false, null: false
    add_column :users, :locked_at, :datetime
    add_column :users, :lock_reason, :string
    add_column :users, :locked_by_id, :integer
    add_column :users, :locked_by_type, :string
    add_column :users, :unlocked_at, :datetime
    add_column :users, :unlocked_by_id, :integer
    add_column :users, :unlocked_by_type, :string

    add_index :users, :locked
    add_index :users, [:locked_by_type, :locked_by_id]
  end
end
```

2. Include the concern in your account model:

```ruby
class User < ApplicationRecord
  include StandardId::AccountLocking  # For admin locking
  include StandardId::AccountStatus   # Optional: for activation/deactivation
  # ...
end
```

### Usage

```ruby
# Lock an account (revokes all active sessions immediately)
user.lock!(reason: "Suspicious activity detected", locked_by: current_admin)
# => Emits ACCOUNT_LOCKED event
# => All active sessions (browser, device, service) are revoked

# Unlock an account (user must log in again)
user.unlock!(unlocked_by: current_admin)
# => Emits ACCOUNT_UNLOCKED event
# => User can log in again

# Check lock status
user.locked?    # => true/false
user.unlocked?  # => true/false

# Query scopes
User.locked     # => Users with locked = true
User.unlocked   # => Users with locked = false

# Combine with AccountStatus scopes
User.unlocked.active  # => Users who can log in
```

### Handling AccountLockedError

When a locked account attempts to authenticate, `StandardId::AccountLockedError` is raised. The error includes metadata about the lock:

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include StandardId::WebAuthentication

  rescue_from StandardId::AccountLockedError, with: :handle_account_locked

  private

  def handle_account_locked(error)
    # error.account     - The locked account
    # error.lock_reason - Why the account was locked
    # error.locked_at   - When the account was locked
    redirect_to login_path, alert: "Your account has been locked. Please contact support."
  end
end
```

For API controllers:

```ruby
# app/controllers/api/base_controller.rb
class Api::BaseController < ActionController::API
  include StandardId::ApiAuthentication

  rescue_from StandardId::AccountLockedError, with: :handle_account_locked

  private

  def handle_account_locked(error)
    render json: {
      error: "account_locked",
      message: "Your account has been locked. Please contact support.",
      locked_at: error.locked_at&.iso8601
      # Note: Consider not exposing lock_reason to end users for security
    }, status: :forbidden
  end
end
```

### Event Subscriptions

Both `AccountStatus` and `AccountLocking` subscribe to the same events (`OAUTH_TOKEN_ISSUING`, `SESSION_CREATING`, `SESSION_VALIDATING`). The lock check runs alongside the status check - authentication fails if either condition prevents access.

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
