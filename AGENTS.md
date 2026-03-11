# AGENTS.md - AI Agent Guide for StandardId

StandardId is a secure-by-default authentication engine for Rails 7/8 providing OAuth 2.0, passwordless auth, JWT tokens, and social login with a plugin architecture.

## Quick Reference

```bash
# Run tests
bundle exec rspec

# Run specific test file
bundle exec rspec spec/models/standard_id/session_spec.rb

# Run linting
bundle exec rubocop

# Auto-fix lint issues
bundle exec rubocop -A

# Database setup (uses spec/dummy app)
bundle exec rake app:db:setup

# Run migrations
bundle exec rake app:db:migrate
```

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

Defined in `lib/standard_id/config/schema.rb` using StandardConfig:

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

## Common Workflows

### Adding an OAuth Flow

1. Create `lib/standard_id/oauth/my_flow.rb` inheriting from base flow
2. Define `expect_params` and `permit_params`
3. Implement authentication logic
4. Emit events via `StandardId::Events.publish`
5. Add tests in `spec/lib/oauth/`

### Adding a Social Provider

1. Create `lib/standard_id/providers/my_provider.rb` inheriting from `Base`
2. Implement: `provider_name`, `authorization_url`, `get_user_info`, `config_schema`
3. Register: `StandardId::ProviderRegistry.register(:my_provider, MyProvider)`
4. Add tests in `spec/lib/providers/`

### Adding Controller Actions

1. Add route in `config/routes/{web,api}.rb`
2. Create controller in `app/controllers/standard_id/{web,api}/`
3. Inherit from `StandardId::Web::BaseController` or `StandardId::Api::BaseController`
4. Emit events for audit trail

## Testing

- **No FactoryBot in gem specs** — the gem's own specs use inline model creation. The published `StandardId::Testing` module ships FactoryBot factories for host-app convenience, but they are not used in the gem's test suite.
- **Dummy app** at `spec/dummy/` - complete Rails app for integration tests
- **Request helpers** in `spec/support/request_helpers.rb`

```ruby
# Example test setup
account = Account.create!(email: "test@example.com")
identifier = StandardId::EmailIdentifier.create!(account: account, value: account.email)
credential = StandardId::PasswordCredential.create!(
  login: account.email,
  password: "password123",
  credential_attributes: { identifier: identifier }
)
```

## Security Notes

- Tokens stored as bcrypt digests or SHA256 hashes - never plaintext
- PKCE required for public OAuth clients
- Redirect URIs validated against whitelist
- All security events published for audit trail
- Session expiry enforced on every request
- Account locking/status changes revoke all sessions

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

## Dependencies

- **rails** ~> 8.0
- **bcrypt** ~> 3.1 (password hashing)
- **jwt** ~> 2.7 (token encoding)
- **concurrent-ruby** (thread-safe data structures)
- **standard_config** (configuration management)

Optional provider gems:
- **standard_id-google** ~> 0.1.1
- **standard_id-apple** ~> 0.1.1
