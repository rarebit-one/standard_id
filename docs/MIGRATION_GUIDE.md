# StandardId Migration Guide

This guide helps you migrate between StandardId versions.

## Table of Contents

- [v0.1.x to v0.2.0](#v01x-to-v020)
- [v0.1.6 to v0.1.7](#v016-to-v017)

---

## v0.1.x to v0.2.0

### Social Login Providers Extracted to Separate Gems

Apple and Google OAuth providers have been extracted from the core `standard_id` gem into separate gems. This allows for more flexible versioning and reduces the core gem's dependencies.

#### Required Changes

Add the provider gems you need to your `Gemfile`:

```ruby
# Apple Sign In (optional - only if you use Apple OAuth)
gem "standard_id-apple", "~> 0.1.0"

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

The `passwordless_email_sender` and `passwordless_sms_sender` configuration options are deprecated and will be removed in v2.0. Please migrate to event-based subscriptions.

**Before (deprecated):**

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

#### Migration Steps

1. Create `config/initializers/standard_id_events.rb`
2. Add the event subscription (see example above)
3. Remove `passwordless_email_sender` and `passwordless_sms_sender` from your configuration
4. Test that OTP codes are still being delivered

For more details on the event system, see the [Event System](../README.md#event-system) section in the README.
