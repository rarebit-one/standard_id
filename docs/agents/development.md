# Development and testing

Moved verbatim from `AGENTS.md` in the P3 trim. `AGENTS.md` keeps a condensed command list.

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

### Local Dev

`bin/dev` boots the dummy app under `spec/dummy` — it provisions the SQLite DB on first run,
then runs `spec/dummy/Procfile.dev` (web + tailwindcss watcher) via overmind/hivemind/foreman.

## Testing

- **No FactoryBot in gem specs** — the gem's own specs use inline model creation. The published `StandardId::Testing` module ships FactoryBot factories for host-app convenience, but they are not used in the gem's test suite.
- **Dummy app** at `spec/dummy/` - complete Rails app for integration tests
- **PostgreSQL leg**: `DATABASE_URL=postgres://.../standard_id_test bundle exec rspec` runs the suite on PG
  (CI job `test (postgres)`). `spec/rails_helper.rb` drops and rebuilds the schema from the migrations
  (the database name must contain `test`); migration specs include `MigrationSpecSupport`, which runs
  them outside the transaction there because PG refuses `CONCURRENTLY` inside one.
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
