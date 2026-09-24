---
name: start
description: "Start working on GitHub Issues in rarebit-one/standard_id. Use when the user says 'start working on', 'pick up issue', 'work on #42', 'work on standard_id-42', 'start #42', '/start', or wants to begin development on a planned issue. Handles context gathering, branch creation, and in-progress signaling."
---

# Start Skill

Begin working on issues from **rarebit-one/standard_id** (GitHub Issues) with proper setup: gather context, create branches, signal in-progress, and track progress.

> **Planning system:** This gem's planning lives in **its own GitHub Issues** (`rarebit-one/standard_id`). Because code and issues live in the **same repo**, a PR can auto-close its issue with a `Closes #NN` keyword in the PR body.

## Prerequisites

This skill uses the `gh` CLI against `rarebit-one/standard_id`. If `gh` is unavailable or unauthenticated, the skill will warn and offer to proceed with git-only setup (branch/worktree creation without the in-progress signal). Check with `gh auth status` if calls fail.

## Scope

This skill sets up local development for issues. It does **NOT**:
- Merge PRs to main (merging is a human decision)
- Delete branches or worktrees automatically
- Close issues directly (a merged PR with `Closes #NN` auto-closes them)

## Usage

```
/start <issue-numbers...>        # Start specific issues (e.g., /start 42 43, /start standard_id-42, /start #42)
/start --mine                    # Show my assigned open issues
/start --backlog                 # Show open, unassigned issues
```

Accepted identifier forms: `42`, `#42`, `standard_id-42`, or a full issue URL. All normalize to the issue number.

## Workflow

### 1. Parse Input and Fetch Issues

**If specific issue numbers provided:**

Normalize each identifier to a plain issue number, then fetch with `gh`:

```bash
gh api repos/rarebit-one/standard_id/issues/<n> \
  --jq '{number, title, state, labels: [.labels[].name], assignees: [.assignees[].login], milestone: .milestone.title, body}'

# Comments often carry decisions and clarifications — read them too
gh api repos/rarebit-one/standard_id/issues/<n>/comments \
  --jq '.[] | {user: .user.login, created_at, body}'
```

The title, body, labels, and comments are the context for the work.

**If `--mine` flag:**

```bash
gh issue list -R rarebit-one/standard_id --assignee @me --state open --limit 10
```

**If `--backlog` flag (optionally with `--label <name>`):**

```bash
gh issue list -R rarebit-one/standard_id --state open --search "no:assignee" --limit 10
```

> "Backlog" here means open + unassigned. If the repo adopts a `backlog` label or triage milestone, prefer `--label backlog` to avoid surfacing untriaged issues.

Present the issues and let the user select which to work on.

### 2. Pre-Work Checks

Before starting, verify:

**Check for blockers:**

GitHub Issues has no native blocking relations — scan the issue body and comments for "blocked by", "depends on", or `#NN` references, and check the state of any referenced issues. This scan is **heuristic**: a bare `#NN` mention may be incidental (e.g. "see discussion in #40"), so read the surrounding context before raising a blocker warning.

```bash
gh api repos/rarebit-one/standard_id/issues/<referenced-n> --jq '{number, title, state}'
```

If blocked:
```
⚠️  #42 appears blocked by:
  - #40: "Set up middleware" (open)

Options:
1. Start anyway (work may be blocked)
2. Start the blocking issue instead
3. Cancel
```

**Check issue readiness:**
- Has description/acceptance criteria?
- Part of a milestone?

If missing context:
```
⚠️  #42 may need more context:
  - No acceptance criteria defined

Proceed anyway? [Y/n]
```

### 3. Signal In-Progress

**Skip this step if `--no-comment` flag is provided.**

Assign the issue to yourself and post a short comment (there is no status field to flip via the issues API):

```bash
gh issue edit <n> -R rarebit-one/standard_id --add-assignee @me

gh api repos/rarebit-one/standard_id/issues/<n>/comments \
  -f body="🚀 Started working on this.

Branch: \`<n>/<short-slug>\`

Planned approach:
- [brief approach notes]"
```

> **Optional label:** if the repo uses an `in progress` (or similar) label, add it with `gh issue edit <n> -R rarebit-one/standard_id --add-label "in progress"`. Skip if the repo has no such label.

**Error handling for the in-progress signal:**

If assigning or commenting fails (auth error, permission issue, etc.):

```
⚠️  Could not signal in-progress on #42:
  Error: <error message>

Options:
1. Continue anyway (set up branch, work locally)
2. Retry
3. Cancel

Note: You can manually assign/comment on the issue later.
```

On a **401**, retry the `gh` call once before surfacing the error — transient token issues are common. The workflow should not block on GitHub failures — local development can proceed.

### 4. Set Up Worktree

**Always create a worktree** to isolate this work from any other state in the repo. This prevents changes from different sessions bleeding into unrelated PRs. Any uncommitted changes on the current branch are left untouched.

```bash
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@@')
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
git fetch origin "$DEFAULT_BRANCH"
git worktree add .worktrees/<identifier> -b <branch-name> "origin/$DEFAULT_BRANCH"
```

**`--no-worktree` flag:** If the user explicitly passes `--no-worktree`, check the current state:
- On the default branch with a clean working tree → fall back to a simple branch:
  ```bash
  DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@@')
  DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
  git fetch origin "$DEFAULT_BRANCH"
  git checkout -b <branch-name> "origin/$DEFAULT_BRANCH"
  ```
- Otherwise → **stop and report why**:
  _"Cannot skip worktree: working tree has uncommitted changes (or is on a feature branch). Stash or commit your changes first, switch to the default branch, then re-run with `--no-worktree`."_

> **Note:** The previous version of this skill offered stash and branch-switch workflows. Those paths have been removed in favor of always using worktrees. If you prefer to stash instead, run `git stash push -m "WIP"` manually before `/start`.

See `/worktree` skill for full worktree conventions.

**Branch name format:**

Derive the branch name from the issue number plus a short slug of the issue title:

```
<n>/<short-slug>
```

Examples:
- `42/add-feature-name`
- `57/fix-auth-timeout`

Keep the slug short: 2–5 kebab-case words derived from the issue title. The `{number}/{slug}` shape lets `/ship` auto-detect the issue number.

**For multiple issues in one PR, use the primary issue's branch:**
- Primary = lowest issue number, or the one the others depend on, or first listed

**Worktree naming:** `.worktrees/<identifier>` (e.g., `.worktrees/42`)

### 5. Display Issue Context

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Starting Work: #42
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📋 Issue: <title>
🔗 https://github.com/rarebit-one/standard_id/issues/42

📝 Description:
[Full issue body]

✅ Acceptance Criteria:
- [ ] ...

🏷️  Labels: ...
🎯 Milestone: ...

💬 Key comments:
- [decisions/clarifications pulled from the issue comments]

🔗 Referenced Issues:
- Depends on: #40 "..."

🌿 Branch: 42/<short-slug>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### 6. Create Initial Todo List

Based on the issue description, create a todo list to track progress.

## Flags Reference

| Flag | Description |
|------|-------------|
| `--mine` | List my assigned open issues in rarebit-one/standard_id |
| `--backlog` | List open, unassigned issues |
| `--no-worktree` | Skip worktree if on the default branch + clean; stops with error otherwise |
| `--no-comment` | Skip the in-progress assign + comment |
| `--label <name>` | Filter issue lists by label |

## Error Handling

| Error | Solution |
|-------|----------|
| `gh` returns 401 | Retry once (transient token issue); if it persists, check `gh auth status` and ask the user |
| `gh` unavailable / no repo access | Warn and offer to proceed with just git setup (user supplies issue context) |
| Issue not found | Verify the number; confirm the repo is `rarebit-one/standard_id` |
| Issue already has an assignee | Ask if user wants to continue anyway |
| Issue is closed | Warn and suggest reopening or selecting a different issue |
| In-progress signal fails | Offer to continue with local setup, retry, or cancel |
| Branch already exists | Offer to checkout existing or create with suffix |
| Worktree already exists | Offer to use existing worktree or create with suffix |
| No origin remote | Warn but continue with local branch creation |
| Blocking issues referenced and still open | Display blockers, offer options |

## Integration with Other Skills

- After completing work, create a PR with `gh pr create` (or `/ship`); the PR body can say `Closes #NN` to auto-close the issue on merge (same-repo). Use `/publish-gem` when ready to release.
- The `<n>/<slug>` branch naming convention ensures the issue number can be auto-detected from the branch.
