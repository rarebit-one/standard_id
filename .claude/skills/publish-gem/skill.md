---
name: publish-gem
description: "Publish a Ruby gem to RubyGems.org. Use when the user says 'publish gem', 'push gem', 'release gem', or '/publish-gem'. Builds the gem, shows a summary, and pushes to RubyGems with OTP."
---

# Publish Gem Skill

Build and publish a Ruby gem to RubyGems.org.

## Scope

This skill handles the gem publishing workflow. It does **NOT**:
- Bump version numbers (the user decides the version)
- Create PRs or merge branches
- Manage GitHub releases (use `gh release create` separately if needed)

## Usage

```
/publish-gem <OTP>        # Build and publish with MFA one-time password
/publish-gem --dry-run    # Build and verify only, do not push
```

The OTP code is required for MFA-enabled RubyGems accounts. If omitted, the skill will ask for it before pushing.

## Workflow

### 1. Verify Context

Confirm we're in a gem project:

```bash
# Must be on main branch
git branch --show-current

# Must have a .gemspec file
ls *.gemspec

# Must have a clean working tree
git status --porcelain
```

**Blockers:**
- Not on `main` branch — warn and ask confirmation before proceeding
- No `.gemspec` found — stop, not a gem project
- Dirty working tree — warn, the build may include uncommitted changes

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
# Check if this version is already published
gem search -r <gem_name> -v <version>

# Verify gem credentials exist
test -f ~/.gem/credentials && echo "Credentials found" || echo "No credentials — run: gem signin"
```

**Blockers:**
- Version already published — stop, cannot overwrite
- No credentials file — stop, user needs to run `gem signin` first

### 4. Build the Gem

```bash
gem build <name>.gemspec
```

Verify the `.gem` file was created and show its size.

### 5. Publish Summary

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

### 6. Push to RubyGems

```bash
gem push <name>-<version>.gem --otp <OTP>
```

If the OTP was not provided as an argument, ask the user for it now.

### 7. Post-Publish Cleanup

```bash
# Remove the built .gem file
rm <name>-<version>.gem

# Create a git tag for the release
git tag -s v<version> -m "Release v<version>"
git push origin v<version>
```

### 8. Output

Report:
1. RubyGems URL: `https://rubygems.org/gems/<name>`
2. Git tag created: `v<version>`
3. Remind: allow a few minutes for the gem to appear on RubyGems

## Error Handling

| Error | Solution |
|-------|----------|
| `gem push` fails with 401 | Credentials expired — run `gem signin` |
| `gem push` fails with 403 | No push permission — check gem ownership |
| OTP rejected | Code expired — ask for a new OTP |
| `gem build` fails | Fix gemspec errors and retry |
| Tag already exists | Version was previously tagged — skip tagging |
| Tag push fails | Likely a permissions issue — report and continue |
