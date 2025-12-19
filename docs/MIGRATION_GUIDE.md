# StandardId Migration Guide

This guide helps you migrate between StandardId versions.

## Table of Contents

- [v0.1.6 to v0.1.7](#v016-to-v017)

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
