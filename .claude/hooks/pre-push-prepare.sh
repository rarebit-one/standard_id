#!/bin/bash
# Pre-push prepare hook for Claude Code
#
# Runs on PreToolUse event for Bash commands containing "git push" or "gh pr create"
# Keeps feature branches up-to-date and encourages single-commit PRs.
#
# What it does:
#   1. Fetches latest target branch and rebases current branch onto it
#   2. If rebase changes history, injects --force-with-lease into git push
#   3. Checks commit count and blocks if >1 commit (prompts user to squash)
#
# Exit codes:
#   0 - Allow (optionally with modified command)
#   2 - Block (rebase conflict or multiple commits)
#
# To skip entirely:
#   SKIP_PRE_PUSH_PREPARE=1 git push ...
#
# To allow multiple commits:
#   ALLOW_MULTIPLE_COMMITS=1 git push ...

set -e

# Require jq for JSON parsing
if ! command -v jq &>/dev/null; then
  echo "❌ pre-push-prepare hook requires 'jq'. Install it and retry." >&2
  exit 0
fi

# Read tool input from stdin
INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

# Detect command type
IS_GIT_PUSH=false
IS_GH_PR_CREATE=false

if [[ "$COMMAND" =~ (^|[[:space:]\&\;\|])git[[:space:]]+push([[:space:]]|$) ]]; then
  IS_GIT_PUSH=true
elif [[ "$COMMAND" =~ (^|[[:space:]\&\;\|])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$) ]]; then
  IS_GH_PR_CREATE=true
fi

if [[ "$IS_GIT_PUSH" == "false" && "$IS_GH_PR_CREATE" == "false" ]]; then
  exit 0
fi

# Allow skipping the entire hook
# Note: env var check works when exported in the shell session.
# The inline prefix form (SKIP_PRE_PUSH_PREPARE=1 git push) is matched via $COMMAND
# since inline env vars only apply to the subprocess, not the hook process.
if [[ "${SKIP_PRE_PUSH_PREPARE:-}" == "1" ]] || [[ "$COMMAND" == SKIP_PRE_PUSH_PREPARE=1* ]]; then
  echo "⏭️  Pre-push prepare hook skipped (SKIP_PRE_PUSH_PREPARE=1)" >&2
  exit 0
fi

# Skip in CI environments
if [[ "${CI:-}" == "true" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  exit 0
fi

# Get current branch (skip if detached HEAD). `|| true` absorbs the non-zero
# exit from git symbolic-ref when HEAD is detached so `set -e` doesn't bail
# before the -z guard fires.
CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || true)
if [[ -z "$CURRENT_BRANCH" ]]; then
  exit 0
fi

# Determine default branch
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}

# Don't rebase if on the default branch
if [[ "$CURRENT_BRANCH" == "$DEFAULT_BRANCH" ]]; then
  exit 0
fi

# --- Step 1: Fetch and Rebase ---

REBASE_HAPPENED=false

echo "🔄 Fetching latest $DEFAULT_BRANCH..." >&2
if git fetch origin "$DEFAULT_BRANCH" --quiet 2>/dev/null; then
  HEAD_BEFORE=$(git rev-parse HEAD)
  MERGE_BASE=$(git merge-base HEAD "origin/$DEFAULT_BRANCH" 2>/dev/null || true)
  REMOTE_TIP=$(git rev-parse "origin/$DEFAULT_BRANCH" 2>/dev/null || true)

  if [[ -z "$REMOTE_TIP" ]]; then
    echo "⚠️  Could not resolve origin/$DEFAULT_BRANCH, skipping rebase" >&2
  elif [[ -n "$MERGE_BASE" && "$MERGE_BASE" != "$REMOTE_TIP" ]]; then
    echo "🔄 Rebasing onto origin/$DEFAULT_BRANCH..." >&2
    if git rebase --quiet "origin/$DEFAULT_BRANCH" >&2; then
      HEAD_AFTER=$(git rev-parse HEAD)
      if [[ "$HEAD_BEFORE" != "$HEAD_AFTER" ]]; then
        REBASE_HAPPENED=true
        echo "✅ Rebased successfully onto origin/$DEFAULT_BRANCH" >&2
      fi
    else
      git rebase --abort 2>/dev/null || true
      echo "❌ Rebase failed due to conflicts. Resolve manually before pushing." >&2
      exit 2
    fi
  fi
else
  echo "⚠️  Could not fetch origin/$DEFAULT_BRANCH (network?), skipping rebase" >&2
fi

# --- Step 2: Commit Count Check ---

COMMIT_COUNT=$(git rev-list --count "origin/$DEFAULT_BRANCH..HEAD" 2>/dev/null || echo "0")

if [[ "$COMMIT_COUNT" -gt 1 ]]; then
  if [[ "${ALLOW_MULTIPLE_COMMITS:-}" != "1" ]] && [[ ! "$COMMAND" == ALLOW_MULTIPLE_COMMITS=1* ]]; then
    echo "" >&2
    echo "📊 Branch '$CURRENT_BRANCH' has $COMMIT_COUNT commits ahead of $DEFAULT_BRANCH:" >&2
    git log --oneline "origin/$DEFAULT_BRANCH..HEAD" >&2
    echo "" >&2
    echo "Consider squashing into a single commit before pushing." >&2
    echo "To proceed with multiple commits: ALLOW_MULTIPLE_COMMITS=1 git push ..." >&2
    exit 2
  fi
fi

# --- Step 3: Handle Rebase Side-Effects ---

if [[ "$REBASE_HAPPENED" == "true" ]]; then
  if [[ "$IS_GIT_PUSH" == "true" ]]; then
    # Inject --force-with-lease if not already present
    if [[ ! "$COMMAND" =~ --force-with-lease ]] && [[ ! "$COMMAND" =~ --force ]]; then
      MODIFIED_COMMAND=$(printf '%s' "$COMMAND" | sed -E 's/(git[[:space:]]+push)/\1 --force-with-lease/')
      echo "🔄 Injecting --force-with-lease (rebase changed history)" >&2
      jq -n --arg cmd "$MODIFIED_COMMAND" '{
        "hookSpecificOutput": {
          "hookEventName": "PreToolUse",
          "updatedInput": {
            "command": $cmd
          }
        }
      }'
      exit 0
    fi
  fi

  if [[ "$IS_GH_PR_CREATE" == "true" ]]; then
    echo "🔄 Force-pushing rebased branch before PR creation..." >&2
    if ! git push --force-with-lease origin "$CURRENT_BRANCH" >&2; then
      echo "❌ Force push failed after rebase. Cannot create PR." >&2
      exit 2
    fi
    echo "✅ Branch pushed, proceeding with PR creation" >&2
  fi
fi

exit 0
