---
name: publish-gem
description: "Publish a Ruby gem to RubyGems.org. Use when the user says 'publish gem', 'push gem', 'release gem', or '/publish-gem'. Handles version bump, changelog, build, push, tagging, and GitHub release."
---

# Publish Gem Skill

Build and publish a Ruby gem to RubyGems.org.

## Usage

```
/publish-gem <OTP>        # Build and publish with MFA one-time password
/publish-gem --dry-run    # Build and verify only, do not push
```

The OTP code is required for MFA-enabled RubyGems accounts. If omitted, the skill will ask for it before pushing.

> **Security note:** Passing OTP on the command line exposes it in shell history and process listings. For interactive sessions, you can omit the OTP and let `gem push` prompt for it. The `--otp` flag is a convenience for scripted workflows where the code is ephemeral.

## Workflow

### 1. Verify Context

Confirm we're in a gem project:

```bash
# Check current branch
git branch --show-current

# Must have a .gemspec file
ls *.gemspec
```

**Blockers:**
- No `.gemspec` found — stop, not a gem project
- Multiple `.gemspec` files found — ask the user which one to build

**Branch handling:**
- If not on `main`, switch automatically: `git checkout main` (publishing from non-main is almost never intentional). If the user explicitly requested publishing from a non-main branch, warn and ask for confirmation before switching.
- After switching (or if already on `main`), always sync with remote:
  ```bash
  git pull --rebase origin main
  ```
- If the rebase fails due to conflicts, stop and ask the user to resolve them before proceeding
- After syncing, verify the working tree is clean (`git status --porcelain`). Warn if dirty — the build may include uncommitted changes.
- Clean up any stale `.gem` files in the working directory before proceeding:
  ```bash
  rm -f *.gem
  ```

### 2. Extract Gem Metadata

Read the gemspec to extract key details:

```bash
# Get gem name and version
ruby -e "spec = Gem::Specification.load(Dir['*.gemspec'].first); puts \"#{spec.name} #{spec.version}\""
```

Also read and display:
- Current version from the gemspec
- CHANGELOG.md entry for this version (if exists)
- `spec.files` count to verify packaging

### 3. Pre-Publish Checks (Remote Registry)

```bash
# Check if this version is already published on RubyGems.org
gem info -r <gem_name> -v <version>

# Verify gem credentials exist (location varies by Ruby version)
# Ruby < 4.0 uses ~/.gem/credentials, Ruby >= 4.0 uses ~/.local/share/gem/credentials
test -f "$(ruby -e "puts Gem.configuration.credentials_path")" && echo "Credentials found" || echo "No credentials — run: gem signin"

# Check if CHANGELOG.md exists when gemspec references it
ruby -e "spec = Gem::Specification.load(Dir['*.gemspec'].first); puts spec.metadata['changelog_uri']"
test -f CHANGELOG.md && echo "CHANGELOG.md found" || echo "CHANGELOG.md missing"
```

**Blockers:**
- Version already published — ask the user what version to bump to (suggest next patch/minor/major). If the user declines, abort the publish.
- No credentials file found (checked via `Gem.configuration.credentials_path`) — stop, user needs to run `gem signin` first

**Warnings:**
- Gemspec `changelog_uri` is set but `CHANGELOG.md` does not exist locally — warn the user and suggest running `/update-changelog` or creating one before publishing. This will result in a broken link on RubyGems.org.

### 4. Version Bump (if needed)

When the current version is already published, or the user requests a bump:

1. Update `lib/<gem_name>/version.rb` with the new version
2. Run `bundle install` to sync `Gemfile.lock`
3. **Do not commit yet** — the version bump is committed only after `gem push` succeeds (see Step 8)

**Critical:** Always run `bundle install` after changing the version to keep `Gemfile.lock` in sync. Skipping this causes CI failures.

### 5. Build the Gem

```bash
gem build <name>.gemspec
```

Verify the `.gem` file was created and show its size.

### 6. Publish Summary

Present a summary before pushing:

```
## Gem Publish Summary

Name:     standard_audit
Version:  0.1.0
File:     standard_audit-0.1.0.gem (12 KB)
Registry: https://rubygems.org

Changelog:
  <first few lines of the version's CHANGELOG entry>
```

If `--dry-run` was passed, stop here and clean up the `.gem` file.

### 7. Push to RubyGems

```bash
gem push <name>-<version>.gem --otp <OTP>
```

If the OTP was not provided as an argument, ask the user for it now.

If `gem push` fails, revert the version bump and Gemfile.lock changes (`git checkout -- lib/<gem_name>/version.rb Gemfile.lock CHANGELOG.md`), report the error, and stop. Do not proceed to tagging or releasing.

### 8. Post-Publish

Only proceed here after `gem push` has succeeded.

#### 8a. Clean up the built gem file

Remove the `.gem` file immediately after a successful push to avoid it showing up as an uncommitted change in later git operations:

```bash
rm <name>-<version>.gem
```

#### 8b. Commit and push the version bump

Commit the version bump, changelog, and lockfile:

```bash
git add lib/<gem_name>/version.rb Gemfile.lock CHANGELOG.md
git commit -m "chore: Bump version to <version>"
```

The `main` branch is protected and requires PRs. Create a PR directly (do not attempt `git push origin main`):

```bash
git checkout -b chore/bump-v<version>
git push -u origin chore/bump-v<version>
gh pr create --title "chore: Bump version to <version>" --body "..."
```

#### 8c. Tag the release

Do **not** tag yet. Since `main` is protected, the version bump goes through a PR. A squash merge creates a new commit on `main`, so a pre-merge tag would point to an orphaned commit not in `main`'s history.

Tell the user to let you know when the PR is merged. When confirmed, perform these steps automatically:

```bash
# Sync main — use reset to avoid divergent branch issues from squash merge
git checkout main
git fetch origin main
git reset --hard origin/main

# Tag the merged commit
git tag -a v<version> -m "Release v<version>"
git push origin v<version>

# Clean up the bump branch locally
# -D needed because squash merge doesn't preserve individual commits in main's history
git branch -D chore/bump-v<version>
# Remote branch may already be deleted by GitHub's auto-delete setting — ignore errors
git push origin --delete chore/bump-v<version> 2>/dev/null || true
```

> **Note:** The `release.yml` GitHub Actions workflow automatically creates a GitHub Release with notes extracted from CHANGELOG.md when the tag is pushed. No manual `gh release create` is needed.

### 9. Output

Report:
1. RubyGems URL: `https://rubygems.org/gems/<name>`
2. Git tag created: `v<version>`
3. GitHub Release: created automatically by the `release.yml` workflow from CHANGELOG.md — link: `https://github.com/<owner>/<repo>/releases/tag/v<version>`
4. Remind: allow a few minutes for the gem to appear on RubyGems and for the GitHub Release to be created

## Error Handling

| Error | Solution |
|-------|----------|
| `gem push` fails with 401 | Credentials expired — run `gem signin` |
| `gem push` fails with 403 | No push permission — check gem ownership |
| `gem push` fails (any reason) | Revert uncommitted version bump (`git checkout -- lib/*/version.rb Gemfile.lock CHANGELOG.md`), report error, stop |
| OTP rejected | Code expired — ask for a new OTP |
| `gem build` fails | Fix gemspec errors and retry |
| Tag already exists | Version was previously tagged — skip tagging |
| Tag signing fails | If `git tag -s` is preferred, ensure GPG is configured; fall back to `git tag -a` |
| Tag push fails | Likely a permissions issue — report and continue |
| Remote branch already deleted | GitHub auto-deleted it — ignore the error, branch cleanup is done |
| User declines version bump | Abort the publish |
