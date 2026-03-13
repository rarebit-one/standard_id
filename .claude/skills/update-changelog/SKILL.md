---
name: update-changelog
description: "Add or update a CHANGELOG.md entry. Use when the user says 'update changelog', 'add changelog entry', or '/update-changelog'. Generates entries from git history following Keep a Changelog format."
---

# Update Changelog Skill

Add or update entries in CHANGELOG.md following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

## Usage

```
/update-changelog                    # Add entry for current version
/update-changelog <version>          # Add entry for a specific version
/update-changelog --backfill         # Backfill all missing versions from git history
```

If both `<version>` and `--backfill` are passed, ignore the version and run a full backfill.

## Workflow

### 1. Determine Target Version

If no version is specified, read the current version from the gemspec or version file:

```bash
ruby -e "spec = Gem::Specification.load(Dir['*.gemspec'].first); puts spec.version"
```

### 2. Find Version Boundaries

Identify the commits that belong to this version by finding when `version.rb` was changed:

```bash
# Find all commits that added or modified version.rb
git log --diff-filter=AM --format="%h %s" -- lib/*/version.rb
```

Use `--diff-filter=AM` (not just `M`) to include the initial commit that created `version.rb`.

For each version-changing commit, extract the version string to map commits to version ranges:

```bash
# For each commit hash, extract the version
git show <hash>:lib/<gem>/version.rb | sed -n 's/.*VERSION = "\(.*\)"/\1/p'
```

### 3. Gather Changes

Get the commits between the previous version bump and the current one:

```bash
git log <previous_bump>..<current_bump> --format="%s"
```

### 4. Categorize Changes

Group commits into Keep a Changelog categories based on commit message prefixes:

| Prefix | Category |
|--------|----------|
| `feat:` | **Added** |
| `fix:` | **Fixed** |
| `refactor:`, `chore:` (with functional changes) | **Changed** |
| `BREAKING:` or `!:` | **Changed** (note breaking) |
| `deprecate:` | **Deprecated** |
| Removal of features | **Removed** |

Skip commits that are purely internal:
- Dependency bumps (`chore(deps):`)
- CI/workflow changes
- Documentation-only changes (unless significant like a new guide)
- Merge commits

Use judgement: a `chore:` that adds thread-safety or extracts providers into plugins IS meaningful and should be included. A `chore:` that bumps a test dependency is not.

### 5. Write the Entry

#### If CHANGELOG.md exists

Insert the new version entry after the `# Changelog` header and any preamble. If an `[Unreleased]` section exists, insert the new version entry below it. Use the Edit tool to insert — do not rewrite the whole file.

When writing a versioned entry for changes that were previously listed under `[Unreleased]`, move those items into the new version section and leave `[Unreleased]` empty (but keep the heading).

#### If CHANGELOG.md does not exist

Create the file with the standard header and an `[Unreleased]` section:

```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [<version>] - <date>

### Added
- ...
```

#### Entry format

```markdown
## [<version>] - <YYYY-MM-DD>

### Added
- Feature description (PR #N)

### Fixed
- Bug fix description

### Changed
- Change description
```

Rules:
- Use the date the version was tagged or released, not today's date (unless it is being released today)
- Write human-readable descriptions, not raw commit messages
- Consolidate related commits into single bullet points
- Include PR numbers where available for traceability
- Omit empty categories (don't include `### Fixed` if there are no fixes)

### 6. Backfill Mode

When `--backfill` is passed:

1. Find all version-changing commits in history (using `--diff-filter=AM` to include the initial version)
2. For each version that has no CHANGELOG.md entry, generate one
3. Write all entries in reverse chronological order (newest first)
4. Include an empty `[Unreleased]` section at the top

This is useful for projects that didn't maintain a changelog from the start.

## Output

Report:
- Which version(s) were added/updated
- Remind the user to review and adjust the entries before committing
