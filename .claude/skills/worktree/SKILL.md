---
name: worktree
description: "Create an isolated worktree for new work. Always creates a worktree by default to prevent cross-contamination between sessions. Use at the start of any session, or when the user says 'worktree', 'isolate', 'fresh start', or 'new worktree'."
---

# Worktree Skill

Creates an isolated worktree for new work. **Always creates a worktree by default** — this prevents changes from different work sessions bleeding into unrelated PRs.

## Why Worktree-by-Default

Every new piece of work gets its own worktree. This eliminates the most common source of cross-contamination: starting new work in a repo that has leftover state from a previous session (uncommitted changes, wrong branch, etc.). The only exception is when the user explicitly opts out.

> **Note:** The previous version of this skill offered a stash-based workflow. That path has been removed in favor of always using worktrees. If you prefer to stash instead, run `git stash push -m "WIP"` manually before invoking `/start` or `/worktree`.

## Why `.worktrees/`

Worktrees are created inside the repo at `.worktrees/<name>` (not under `.claude/worktrees/`). This ensures:
- Worktrees are accessible inside devcontainers (mounted at `/workspace/.worktrees/`)
- Consistent convention across all repos in the workspace
- The `.worktrees/` directory is gitignored in each repo

## Usage

```
/worktree                          # Create a worktree (always, regardless of state)
/worktree <name>                   # Create a named worktree directly
/worktree --no-worktree            # Skip worktree creation, work in current checkout
```

## Workflow

### Phase 1: Detect Current State

Gather the repo state (for reporting, not for deciding whether to create a worktree):

```bash
# Current branch
CURRENT_BRANCH=$(git branch --show-current)

# Default branch
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@@')
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}

# Uncommitted changes (staged + unstaged + untracked)
git status --porcelain
```

### Phase 2: Decision

**Default behavior:** Always create a worktree. Go straight to Phase 3 → Phase 4. Any uncommitted changes on the current branch are left untouched — the worktree is a separate checkout, so existing work is preserved exactly as-is.

**`--no-worktree` flag:** Skip worktree creation and stay in the current checkout. This is for when the user explicitly wants to continue work on the current branch (e.g., resuming a previous session). If dirty state is detected, inform the user what's there.

### Phase 3: Fetch Latest

Before creating a worktree, always fetch the latest default branch:

```bash
git fetch origin $DEFAULT_BRANCH
```

This ensures the worktree starts from the latest codebase.

### Phase 4: Create Worktree

**Naming convention:**

If a name is provided (e.g., from a Linear issue identifier):
```bash
git worktree add .worktrees/<name> -b <branch-name> origin/$DEFAULT_BRANCH
```

If no name is provided, generate one from context:
- If starting a Linear issue: use the issue identifier (e.g., `swe-123`)
- If the user described the task: use a short slug (e.g., `fix-auth-timeout`)
- Fallback: use today's date in `YYYY-MM-DD` format

**Ensure `.worktrees/` is gitignored:**

```bash
# Check if .worktrees is already in .gitignore
if ! grep -q '\.worktrees' .gitignore 2>/dev/null; then
  echo '.worktrees/' >> .gitignore
fi
```

### Phase 5: Report

After setup, display:

```
Worktree created at: .worktrees/<name>
Branch: <branch-name>
Based on: origin/main (fetched latest)

Previous state preserved:
  Branch: <original-branch>
  Changes: <summary of uncommitted changes left behind, if any>

Working directory: .worktrees/<name>
```

If `--no-worktree` was used:

```
Staying in current checkout: <branch>
  (fetched latest origin/main)
  <summary of uncommitted changes, if any>

To create a new branch:
  git checkout -b <branch-name> origin/main
```

## Integration with /start

The `/start` skill always creates a worktree as part of its workflow. Both skills follow the same conventions:
- Worktrees go in `.worktrees/`
- Always fetch latest before creating
- Naming follows the `<identifier>` convention (e.g., `.worktrees/swe-123`)

This `/worktree` skill can also be invoked independently when you want to isolate work without picking up a Linear issue.

## Error Handling

| Error | Solution |
|-------|----------|
| `.worktrees/<name>` already exists | Offer to reuse existing or create with suffix |
| Branch name already exists | Check out existing branch in the worktree instead of `-b` |
| No origin remote | Create worktree from local default branch HEAD |
| Fetch fails | Warn and create from local default branch HEAD |
| `.gitignore` is read-only | Warn the user to add `.worktrees/` manually |

## Safety Rules

1. **Never discard uncommitted changes** - the whole point is to preserve them
2. **Never force-checkout** over dirty state - always worktree instead
3. **Always fetch before creating** - worktrees should start from latest
4. **This skill only creates worktrees** - it does not remove or clean up stale ones
