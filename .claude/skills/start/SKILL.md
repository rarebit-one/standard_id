---
name: start
description: "Start working on Linear issues. Use when the user says 'start working on', 'pick up issue', 'work on RAR-123', or wants to begin development on Linear issues. Handles status updates, branch creation, and context gathering."
---

# Start Skill

Begin working on Linear issues with proper setup: update status, create branches, gather context, and track progress.

## Scope

This skill sets up local development for Linear issues. It does **NOT**:
- Merge PRs to main (merging is a human decision)
- Delete branches or worktrees automatically
- Close or complete Linear issues

## Usage

```
/start <issue-identifiers...>   # Start specific issues (e.g., /start RAR-123 RAR-124)
/start --mine                    # Show my assigned issues ready to start
/start --backlog                 # Show backlog issues for a team
```

## Workflow

> **Note:** MCP tool calls shown below use pseudocode syntax for readability.
> Actual invocation uses Claude's tool use API with the `mcp__linear__*` tools.

### 1. Parse Input and Fetch Issues

**If specific identifiers provided:**

Fetch each issue using Linear MCP:

```
mcp__linear__get_issue(id: "RAR-123", includeRelations: true)
```

**If `--mine` flag:**

```
mcp__linear__list_issues(assignee: "me", state: "Todo", limit: 10)
```

**If `--backlog` flag (with optional `--team` and `--project` filters):**

```
mcp__linear__list_issues(
  team: "<from --team flag, default: Rarebit>",
  project: "<from --project flag, if provided>",
  state: "Backlog",
  limit: 10
)
```

Present the issues and let the user select which to work on.

### 2. Pre-Work Checks

Before starting, verify:

**Check for blockers:**

```
# From get_issue with includeRelations: true
# Look at the blocking/blockedBy relations
```

If blocked:
```
Warning: RAR-123 is blocked by:
  - RAR-120: "Set up middleware" (In Progress)

Options:
1. Start anyway (work may be blocked)
2. Start the blocking issue instead
3. Cancel
```

**Check issue readiness:**
- Has description/acceptance criteria?
- Has assigned estimate?

If missing context, warn but allow proceeding.

### 3. Update Issue Status

**Skip this step if `--no-status` flag is provided.**

Update each issue to "In Progress":

```
mcp__linear__save_issue(
  id: "<issue-uuid>",
  stateId: "<in-progress-state-id>"
)
```

The workflow should not block on Linear failures — local development can proceed.

### 4. Set Up Git Branch

First, assess the current git state:

```bash
CURRENT_BRANCH=$(git branch --show-current)
git status --porcelain
```

**Decision tree:**

```
On main, clean       → fetch latest, create branch (simple path)
On main, dirty       → ask: stash, commit, or worktree
On feature, clean    → ask: switch or worktree
On feature, dirty    → recommend worktree (preserves current work)
```

**Simple path (on main, clean):**

```bash
git fetch origin main
git checkout -b <branch-name> origin/main
```

**Worktree path (dirty state or --worktree flag):**

```bash
git fetch origin main
git worktree add .worktrees/rar-123 -b <branch-name> origin/main
```

See `/worktree` skill for full worktree conventions.

**Branch name format:**

Use Linear's `gitBranchName` field if available, or generate:
`{identifier}/{short-description}` (e.g., `rar-123/add-feature-name`)

**Worktree naming:** `.worktrees/<identifier>` (e.g., `.worktrees/rar-123`)

### 5. Display Issue Context

```
Starting: RAR-123
Issue: <title>
URL: https://linear.app/...

Description:
<full description>

Acceptance Criteria:
- [ ] ...

Branch: <branch-name>
```

### 6. Create Initial Todo List

Based on the issue description, create a todo list to track progress.

## Flags Reference

| Flag | Description |
|------|-------------|
| `--mine` | List my assigned issues in Todo state |
| `--backlog` | List team backlog issues |
| `--worktree` | Always create a worktree (skip decision tree) |
| `--no-status` | Skip status update (just create branch) |
| `--no-comment` | Skip posting start comment |
| `--team <name>` | Filter by team (default: Rarebit) |
| `--project <name>` | Filter by project |

## Error Handling

| Error | Solution |
|-------|----------|
| Linear MCP unavailable | Warn and offer to proceed with just git setup |
| Issue not found | Verify identifier, check team access |
| Issue already in progress | Ask if user wants to continue anyway |
| Issue is done/canceled | Warn and suggest reopening or selecting different issue |
| Status update fails | Offer to continue with local setup, retry, or cancel |
| Branch already exists | Offer to checkout existing or create with suffix |
| Worktree already exists | Offer to use existing worktree or create with suffix |

## Integration with Other Skills

- After completing work, create a PR with `gh pr create` or use `/publish-gem` when ready to release
- The branch naming convention ensures the Linear issue can be auto-detected from the branch
