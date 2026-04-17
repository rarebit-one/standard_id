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
| `standard_id:cleanup:code_challenges` | Deletes expired or used PKCE code challenges |

Each task honours `GRACE_DAYS` (default `7`) — rows are only deleted once they have been expired for that many days. Consumed authorization codes and used code challenges use a separate 1-day grace window (not env-configurable for now).

```bash
bundle exec rake standard_id:cleanup:all
GRACE_DAYS=14 bundle exec rake standard_id:cleanup:sessions
```

The tasks call `perform_now` on the underlying jobs, so they run synchronously inside the rake process. If you'd rather enqueue them, call the job classes directly: `StandardId::CleanupExpiredSessionsJob.perform_later`.

### Scheduling

Pick whatever your app already uses — running cleanup nightly is usually enough.

**SolidQueue recurring tasks** (`config/recurring.yml`):

```yaml
production:
  standard_id_cleanup_sessions:
    class: StandardId::CleanupExpiredSessionsJob
    schedule: every day at 3am
  standard_id_cleanup_refresh_tokens:
    class: StandardId::CleanupExpiredRefreshTokensJob
    schedule: every day at 3:15am
  standard_id_cleanup_authorization_codes:
    class: StandardId::CleanupExpiredAuthorizationCodesJob
    schedule: every day at 3:30am
  standard_id_cleanup_code_challenges:
    class: StandardId::CleanupExpiredCodeChallengesJob
    schedule: every day at 3:45am
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
