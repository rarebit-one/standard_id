# Operations

## Scheduled Maintenance

StandardId records (sessions, refresh tokens, authorization codes, code challenges) accumulate over time and should be pruned periodically. The engine ships cleanup jobs and thin rake wrappers so any scheduler can drive them.

### Rake Tasks

| Task | What it does |
|------|--------------|
| `standard_id:cleanup:all` | Runs every cleanup task below |
| `standard_id:cleanup:sessions` | Deletes expired browser/device/service sessions |
| `standard_id:cleanup:refresh_tokens` | Deletes expired or revoked OAuth refresh tokens |
| `standard_id:cleanup:authorization_codes` | Deletes expired or consumed OAuth authorization codes |
| `standard_id:cleanup:code_challenges` | Deletes expired or used OTP code challenges |

Each task honours `GRACE_DAYS` (default `7`) — rows are only deleted once they have been expired for that many days. Consumed authorization codes and used code challenges use a separate 1-day grace window (not env-configurable for now).

```bash
bundle exec rake standard_id:cleanup:all
GRACE_DAYS=14 bundle exec rake standard_id:cleanup:sessions
```

The tasks call `perform_now` on the underlying jobs, so they run synchronously inside the rake process. If you'd rather enqueue them, call the job classes directly: `StandardId::CleanupExpiredSessionsJob.perform_later`.

### Scheduling

Pick whatever your app already uses. Schedule **all four** jobs; hourly (staggered off minute 0) keeps each `DELETE` small, while nightly is enough for small apps — the grace windows, not the cadence, bound retention.

**SolidQueue recurring tasks** (`config/recurring.yml`) — `rails g standard_id:install` writes this for you when the file exists:

```yaml
production:
  standard_id_cleanup_expired_sessions:
    class: StandardId::CleanupExpiredSessionsJob
    schedule: every hour at minute 6
  standard_id_cleanup_expired_refresh_tokens:
    class: StandardId::CleanupExpiredRefreshTokensJob
    schedule: every hour at minute 3
  standard_id_cleanup_expired_authorization_codes:
    class: StandardId::CleanupExpiredAuthorizationCodesJob
    schedule: every hour at minute 9
  standard_id_cleanup_expired_code_challenges:
    class: StandardId::CleanupExpiredCodeChallengesJob
    schedule: every hour at minute 13
```

**sidekiq-cron** (`config/schedule.yml`):

```yaml
standard_id_cleanup_sessions:
  cron: "0 3 * * *"
  class: "StandardId::CleanupExpiredSessionsJob"
standard_id_cleanup_refresh_tokens:
  cron: "15 3 * * *"
  class: "StandardId::CleanupExpiredRefreshTokensJob"
standard_id_cleanup_authorization_codes:
  cron: "30 3 * * *"
  class: "StandardId::CleanupExpiredAuthorizationCodesJob"
standard_id_cleanup_code_challenges:
  cron: "45 3 * * *"
  class: "StandardId::CleanupExpiredCodeChallengesJob"
```

**whenever** (`config/schedule.rb`):

```ruby
every 1.day, at: "3:00 am" do
  rake "standard_id:cleanup:all"
end
```

**System cron** (if you prefer):

```cron
0 3 * * * cd /path/to/app && bundle exec rake standard_id:cleanup:all RAILS_ENV=production
```

### Unverified email + password sign-ups

With `c.email_password.enabled`, schedule `StandardId::PurgeUnverifiedEmailSignupsJob` too (it is not part of `CleanupAllJob`, and is a no-op while the feature is off). Daily is plenty:

```yaml
production:
  standard_id_purge_unverified_email_signups:
    class: StandardId::PurgeUnverifiedEmailSignupsJob
    schedule: every day at 4:20am
```

It removes sign-ups made through the email + password API (an unverified email identifier with a password credential and a code issued in `c.email_password.verification_realm`) left unverified for `c.email_password.unverified_purge_after` seconds (3 days): the password credential, the email identifier and, when nothing else is left on it, the account. It skips an account at any sign of use (a verified or provider identifier, a session, a refresh token, `c.email_password.account_in_use` returning true, a row that still references it) and any address that asked for a code within `c.email_password.purge_recent_code_window` (24 hours). It never touches other unverified password sign-ups, such as the web sign-up form's. A sign-up is only found while its code challenge exists, and `CleanupExpiredCodeChallengesJob` drops unused challenges 7 days after they expire, so keep `unverified_purge_after` under that; a longer window just purges nothing. It returns `{ purged_count:, skipped_count: }`.
