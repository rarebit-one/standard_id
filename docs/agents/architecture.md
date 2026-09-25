# Architecture

Moved verbatim from `AGENTS.md` in the P3 trim, with one corrected line (the configuration DSL is `StandardId::ConfigSchema`, not StandardConfig).

## Project Structure

```
standard_id/
├── app/
│   ├── controllers/standard_id/
│   │   ├── api/              # API controllers (JWT-based)
│   │   └── web/              # Web controllers (cookie-based)
│   ├── forms/                # Form objects (SignupForm, ResetPasswordForm)
│   ├── models/standard_id/   # ActiveRecord models (STI-based)
│   └── views/                # ERB templates
├── lib/standard_id/
│   ├── api/                  # API auth (guards, managers)
│   ├── web/                  # Web auth (guards, managers)
│   ├── oauth/                # OAuth 2.0 flows
│   ├── passwordless/         # OTP strategies
│   ├── providers/            # Social provider base class
│   ├── events/               # Event system
│   ├── config/schema.rb      # Configuration DSL
│   └── errors.rb             # Custom exceptions
├── config/routes/
│   ├── web.rb                # Web engine routes
│   └── api.rb                # API engine routes
├── db/migrate/               # Database migrations
└── spec/
    ├── dummy/                # Test Rails app
    ├── models/               # Model specs
    ├── requests/             # Integration specs
    └── support/              # Test helpers
```

## Key Patterns

### STI (Single Table Inheritance)

**Sessions** (`standard_id_sessions` table):
- `StandardId::Session` (base)
  - `StandardId::BrowserSession` - web sessions (cookies)
  - `StandardId::DeviceSession` - mobile/API (JWT)
  - `StandardId::ServiceSession` - M2M (JWT)

**Identifiers** (`standard_id_identifiers` table):
- `StandardId::Identifier` (base)
  - `StandardId::EmailIdentifier`
  - `StandardId::PhoneNumberIdentifier`
  - `StandardId::UsernameIdentifier`

### Delegated Type (Credentials)

```ruby
# StandardId::Credential wraps:
- StandardId::PasswordCredential  # User passwords
- StandardId::ClientSecretCredential  # OAuth client secrets
```

### Two Rails Engines

| Engine | Mount Point | Auth Method | Namespace |
|--------|-------------|-------------|-----------|
| WebEngine | `/` | Cookies | `StandardId::Web::*` |
| ApiEngine | `/api` | JWT Bearer | `StandardId::Api::*` |

### Event System

Uses `ActiveSupport::Notifications`. Events defined in `lib/standard_id/events/definitions.rb`:

```ruby
# Publishing
StandardId::Events.publish(:authentication_succeeded, account: user)

# Subscribing
StandardId::Events.subscribe(:authentication_succeeded) do |event|
  Rails.logger.info("Login: #{event[:account].email}")
end
```

### Configuration

Defined in `lib/standard_id/config/schema.rb` using `StandardId::ConfigSchema` (`lib/standard_id/config_schema.rb`):

```ruby
StandardId.config.account_class_name      # "User"
StandardId.config.oauth.default_token_lifetime  # 3600
StandardId.config.session.browser_session_lifetime  # 24.hours
```

## Database Tables

| Table | Purpose |
|-------|---------|
| `standard_id_identifiers` | Email/phone/username (STI) |
| `standard_id_credentials` | Credential wrapper (delegated_type) |
| `standard_id_password_credentials` | Bcrypt password storage |
| `standard_id_client_secret_credentials` | OAuth client secrets |
| `standard_id_sessions` | Auth sessions (STI) |
| `standard_id_client_applications` | OAuth clients |
| `standard_id_authorization_codes` | OAuth auth codes |
| `standard_id_code_challenges` | OTP codes |

## Key Files

| File | Purpose |
|------|---------|
| `lib/standard_id/engine.rb` | Main engine initialization |
| `lib/standard_id/errors.rb` | All custom exceptions |
| `lib/standard_id/events.rb` | Event publishing system |
| `lib/standard_id/jwt_service.rb` | JWT encoding/decoding |
| `lib/standard_id/config/schema.rb` | Configuration definitions |
| `app/controllers/concerns/standard_id/web_authentication.rb` | Web auth mixin |
| `app/controllers/concerns/standard_id/api_authentication.rb` | API auth mixin |
