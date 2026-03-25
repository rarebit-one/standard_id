---
name: publish-gem
description: "Publish a Ruby gem to RubyGems.org via CI. Use when the user says 'publish gem', 'push gem', 'release gem', or '/publish-gem'. Handles version bump, changelog, build verification, PR, tagging, and CI-driven publish."
---

# Publish Gem Skill

Prepare and publish a Ruby gem to RubyGems.org via GitHub Actions trusted publishing.

Publishing is done by CI (not locally) — pushing a version tag triggers the `release.yml` workflow which builds the gem, creates a GitHub Release, and pushes to RubyGems via OIDC. This skill handles everything up to and including the tag push.

## Usage

```
/publish-gem              # Full release flow
/publish-gem --dry-run    # Verify everything, stop before PR creation
```

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

### 3. Pre-Publish Checks

```bash
# Check if this version is already published on RubyGems.org
gem info -r <gem_name> -v <version>

# Check if CHANGELOG.md exists when gemspec references it
ruby -e "spec = Gem::Specification.load(Dir['*.gemspec'].first); puts spec.metadata['changelog_uri']"
test -f CHANGELOG.md && echo "CHANGELOG.md found" || echo "CHANGELOG.md missing"
```

**Blockers:**
- Version already published — ask the user what version to bump to (suggest next patch/minor/major). If the user declines, abort the publish.

**Warnings:**
- Gemspec `changelog_uri` is set but `CHANGELOG.md` does not exist locally — warn the user. This will result in a broken link on RubyGems.org.
- CHANGELOG.md has no entry for the version being published — warn the user. The `release.yml` workflow will fail if no changelog entry exists for the version.

### 4. Version Bump (if needed)

When the current version is already published, or the user requests a bump:

1. Update `lib/<gem_name>/version.rb` with the new version
2. Run `bundle install` to sync `Gemfile.lock`

**Critical:** Always run `bundle install` after changing the version to keep `Gemfile.lock` in sync. Skipping this causes CI failures.

### 5. Update CHANGELOG.md

If the `[Unreleased]` section in CHANGELOG.md has content:
1. Rename `[Unreleased]` to `[<version>] - <today's date>` (format: YYYY-MM-DD)
2. Add a new empty `[Unreleased]` section above it

If `[Unreleased]` is empty, warn the user and ask if they want to proceed without changelog entries for this version.

### 6. Run Tests

```bash
bundle exec rspec
```

**Blockers:**
- Tests fail — stop and ask the user to fix. Do not proceed with a failing test suite.

### 7. Build Verification

```bash
gem build <name>.gemspec
```

Verify the `.gem` file was created, show its size, then clean up:

```bash
rm <name>-<version>.gem
```

### 8. Release Summary

Present a summary before proceeding:

```
## Release Summary

Name:     <gem_name>
Version:  <version>
Files:    <file count> files in gem
Registry: https://rubygems.org (published by CI via trusted publisher)

Changelog:
  <first few lines of the version's CHANGELOG entry>

Next steps:
  1. Create version bump PR
  2. Merge PR (manual)
  3. Tag release → CI publishes to RubyGems + creates GitHub Release
```

If `--dry-run` was passed, stop here.

### 9. Create Version Bump PR

Commit the version bump, changelog, and lockfile on a branch and open a PR:

```bash
git checkout -b chore/release-v<version>
git add lib/<gem_name>/version.rb Gemfile.lock CHANGELOG.md
git commit -m "chore: Release v<version>"
git push -u origin chore/release-v<version>
gh pr create --title "chore: Release v<version>" --body "$(cat <<'EOF'
## Release v<version>

<changelog entry for this version>

After merging, Claude will tag `v<version>` which triggers CI to:
- Create a GitHub Release with changelog notes
- Build and publish the gem to RubyGems.org via trusted publisher
EOF
)"
```

Tell the user to review and merge the PR, then let you know when it's merged.

### 10. Tag the Release (after PR merge)

When the user confirms the PR is merged:

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
git branch -D chore/release-v<version>
# Remote branch may already be deleted by GitHub's auto-delete setting — ignore errors
git push origin --delete chore/release-v<version> 2>/dev/null || true
```

The tag push triggers `release.yml` which:
1. Verifies the tag version matches `version.rb`
2. Waits for CI to pass
3. Extracts changelog notes and creates a GitHub Release
4. Builds the gem and publishes to RubyGems.org via OIDC trusted publisher

### 11. Output

Report:
1. RubyGems URL: `https://rubygems.org/gems/<name>` (available after CI completes)
2. Git tag created: `v<version>`
3. GitHub Release + RubyGems publish: triggered by CI — link: `https://github.com/<owner>/<repo>/actions`
4. Remind: allow a few minutes for CI to complete, then the gem will appear on RubyGems and the GitHub Release will be created

## Error Handling

| Error | Solution |
|-------|----------|
| `gem build` fails | Fix gemspec errors and retry |
| Tests fail | Fix tests before proceeding |
| Tag already exists | Version was previously tagged — skip tagging |
| Tag push fails | Likely a permissions issue — report and continue |
| Remote branch already deleted | GitHub auto-deleted it — ignore the error |
| User declines version bump | Abort the publish |
| CI publish fails | Check the Actions tab — common causes: trusted publisher not configured on RubyGems.org, `rubygems` environment not set up in GitHub repo settings, or version mismatch between tag and version.rb |
