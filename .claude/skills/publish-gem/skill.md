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
- If not on `main`, offer to switch automatically: `git checkout main`
- After switching (or if already on `main`), always sync with remote:
  ```bash
  git pull --rebase origin main
  ```
- If the rebase fails due to conflicts, stop and ask the user to resolve them before proceeding
- After syncing, verify the working tree is clean (`git status --porcelain`). Warn if dirty — the build may include uncommitted changes.
- If the user explicitly wants to publish from a non-main branch, warn and proceed with confirmation

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

Try pushing to `main`:

```bash
git push origin main
```

If the push is rejected due to branch protection rules, create a PR instead:

```bash
git checkout -b chore/bump-v<version>
git push -u origin chore/bump-v<version>
gh pr create --title "chore: Bump version to <version>" --body "..."
```

#### 8c. Tag and release

**If pushed directly to `main`:** Tag the commit and push the tag immediately.

**If a PR was required (branch protection):** Do **not** tag yet. Inform the user that the tag should be created after the PR is merged, since a squash merge creates a new commit on `main` and a pre-merge tag would point to an orphaned commit not in `main`'s history. Provide the command to run after merge:

```bash
# Run after the version bump PR is merged:
git checkout main && git pull origin main
git tag -a v<version> -m "Release v<version>"
git push origin v<version>
gh release create v<version> --title "v<version>" --notes "<release notes>"
```

Skip steps 8c and 8d below, and include the above instructions in the final output (Step 9) instead.

```bash
# Create an annotated git tag for the release
git tag -a v<version> -m "Release v<version>"
git push origin v<version>
```

#### 8d. Create a GitHub Release

Always create a GitHub Release from the tag. Use the CHANGELOG.md entry for the release body if available, otherwise summarize from the git log:

```bash
gh release create v<version> --title "v<version>" --notes "<release notes>"
```

### 9. Output

Report:
1. RubyGems URL: `https://rubygems.org/gems/<name>`
2. Git tag created: `v<version>`
3. GitHub Release: `https://github.com/<owner>/<repo>/releases/tag/v<version>`
4. Remind: allow a few minutes for the gem to appear on RubyGems

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
| Push to main rejected | Branch is protected — create a PR instead |
| User declines version bump | Abort the publish |
