# CLAUDE.md

## Worktree-First Workflow (Mandatory)

**All code changes MUST happen in an isolated worktree.** Do not modify files in the main checkout. Before writing any code, create a worktree:

```bash
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@@')
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
git fetch origin "$DEFAULT_BRANCH"
git worktree add .worktrees/<name> -b <branch-name> "origin/$DEFAULT_BRANCH"
```

Then work inside `.worktrees/<name>/` for the rest of the session.

**Naming:** Use the Linear issue identifier if available (e.g., `.worktrees/<identifier>`), a task slug (e.g., `.worktrees/fix-auth-timeout`), or today's date (e.g., `.worktrees/2026-04-01`) as fallback.

**The only exceptions** — you may skip worktree creation when:
1. The user explicitly says to skip it (e.g., "no worktree", "just edit here", `--stay`)
2. The task is read-only (research, investigation, code review with no edits)
3. You are already inside a worktree (check: `git rev-parse --git-dir` returns a path under `.git/worktrees/`)
4. You are running in a CI/automated context (GitHub Actions, etc.) where the checkout is already isolated

**Why this matters:** Working directly on the main checkout causes cross-contamination between sessions — uncommitted changes, wrong branches, and dirty state leak into unrelated work. Worktrees eliminate this entirely.

See the `/worktree` and `/start` skills for full conventions and flags.
