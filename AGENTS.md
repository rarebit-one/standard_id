# AGENTS.md - AI Agent Guide for StandardId

StandardId is a secure-by-default authentication engine for Rails 8 providing OAuth 2.0, passwordless auth, JWT tokens, and social login with a plugin architecture.

## Public API

- Two engines, both `isolate_namespace StandardId`: `lib/standard_id/web_engine.rb`
  (cookies, `StandardId::Web::*`) and `lib/standard_id/api_engine.rb` (JWT bearer,
  `StandardId::Api::*`). Routes: `config/routes/web.rb`, `config/routes/api.rb`.
- Host mixins: `app/controllers/concerns/standard_id/web_authentication.rb` and
  `app/controllers/concerns/standard_id/api_authentication.rb`.
- Configuration: `StandardId.config`, schema in `lib/standard_id/config/schema.rb`.
- Events: `StandardId::Events.publish` / `.subscribe` over `ActiveSupport::Notifications`;
  names in `lib/standard_id/events/definitions.rb`.
- Provider plugins: subclass `lib/standard_id/providers/base.rb` and register with
  `StandardId::ProviderRegistry.register`.
- Errors: `lib/standard_id/errors.rb`. JWTs: `lib/standard_id/jwt_service.rb`.

## Commands

```bash
bundle exec rspec
bundle exec rubocop -A
bundle exec rake app:db:setup      # uses the spec/dummy app
bundle exec rake app:db:migrate
bin/dev                            # boots spec/dummy (web + tailwindcss watcher)
```

`bin/dev` boots the dummy app under `spec/dummy` — it provisions the SQLite DB on first run,
then runs `spec/dummy/Procfile.dev` (web + tailwindcss watcher) via overmind/hivemind/foreman.

## Invariants

- Tokens stored as bcrypt digests or SHA256 hashes - never plaintext
- PKCE required for public OAuth clients
- Redirect URIs validated against whitelist
- All security events published for audit trail
- Session expiry enforced on every request
- Account locking/status changes revoke all sessions
- Sessions and identifiers are STI (`standard_id_sessions`, `standard_id_identifiers`);
  credentials are a `delegated_type`. New kinds are subclasses, not new tables.
- New OAuth flows declare `expect_params` / `permit_params` (see
  `lib/standard_id/oauth/base_request_flow.rb`) and emit events via `StandardId::Events.publish`.

## Footguns

- **Test changes against the consuming apps**, not only this suite: five apps
  mount the engine (see Consumers), and the provider plugins reach into
  `StandardId::ProviderRegistry` and `config_schema` internals.
- **No FactoryBot in gem specs** — the gem's own specs use inline model creation. The published `StandardId::Testing` module ships FactoryBot factories for host-app convenience, but they are not used in the gem's test suite.
- Removed settings raise `StandardId::ConfigurationError` with a hint; upgrade
  notes live in `docs/MIGRATION_GUIDE.md`.
- Pre-push lefthook (`lefthook.yml`) runs rubocop, brakeman and `rspec --fail-fast`.

## Workspace rules

- **Worktrees only.** Edit in `.worktrees/<name>/`, never in the main checkout.
  `.agents/hooks.toml` registers `enforce-worktree` (Edit/Write/NotebookEdit);
  scripts are in `.agents/hooks/`. There are no opt-outs; CI checkouts are the
  only exception. Bash writes into the main checkout (`sed -i`, `tee`, redirects,
  `cp`/`mv`) are not hook-guarded yet: `enforce-worktree-bash` is not registered
  until rarebit-one/standard_id#351 merges, so for Bash this rule is
  instruction-enforced.

```bash
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@@')
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
git fetch origin "$DEFAULT_BRANCH"
git worktree add .worktrees/<name> -b <branch-name> "origin/$DEFAULT_BRANCH"
```

Then work inside `.worktrees/<name>/` for the rest of the session.

**Naming:** Use a task slug (e.g., `.worktrees/fix-auth-timeout`) or today's date (e.g., `.worktrees/2026-04-01`).

**Why this matters:** Working directly on the main checkout causes cross-contamination between sessions — uncommitted changes, wrong branches, and dirty state leak into unrelated work. Worktrees eliminate this entirely.

- **Signed commits only.** `enforce-signed-commits` adds `-S` to `git commit`; if
  signing fails, stop and report it, and never pass `--no-gpg-sign`.

See the `/worktree` and `/start` skills for full conventions and flags.

## Where to look

- `docs/agents/architecture.md`: layout, STI and delegated types, engines, events, config, tables, key files.
- `docs/agents/workflows.md`: adding an OAuth flow, a social provider, a controller action.
- `docs/agents/development.md`: the full command reference and test setup.
- `docs/agents/security.md`: the security notes.
- `docs/OPERATIONS.md`: scheduled cleanup jobs and rake tasks.
- `docs/MIGRATION_GUIDE.md`: per-version upgrade steps.
- `README.md`: host-facing configuration, the event list, and "Writing a Provider Plugin".

## Consumers

`standard_id` is consumed by these apps in the rarebit-one workspace:

- `fundbright-web`
- `luminality-web`
- `nutripod-web`
- `sidekick-web`
- `jumpdrive-web` (the control-plane app, formerly `workspace-os`; its `Gemfile`/`Gemfile.lock` live under `control-plane/`, **not** the repo root — a `*/Gemfile` glob misses it, which is how an audit can drop this consumer without noticing. Its local checkout is `~/Workspace/rarebit-one/jumpdrive-web` — the directory rename is done; the old `workspace-os` dir was retired 2026-07-14.)

Note that the provider plugins have a narrower consumer set than the engine itself: `standard_id-apple` and `standard_id-google` are consumed only by `luminality-web` and `sidekick-web`.

Three consumers live in sibling workspaces — `fundbright-web` in `~/Workspace/fundbright/`, `luminality-web` in `~/Workspace/luminality/`, `sidekick-web` in `~/Workspace/sidekick-labs/` — so don't assume every consumer sits beside this repo.

After publishing a new version via `/publish-gem`, roll it out with the workspace-level `/rollout-gem standard_id [<version>]` skill (defined at the rarebit-one workspace root, one directory above this repo). The canonical consumer matrix — including version constraints and any non-rubygems sources — lives in that skill's `SKILL.md`; the list here is a summary so version pins don't drift between two files.
