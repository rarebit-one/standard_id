#!/bin/bash
# Enforce signed commits hook for Claude Code
#
# Runs on PreToolUse event for Bash commands containing "git commit"
# Automatically injects the -S flag to ensure all commits are GPG/SSH signed
#
# What it does:
#   1. Detects git commit commands (but not git commit-msg, git commit-tree, etc.)
#   2. Verifies git signing is configured
#   3. Checks if -S or --gpg-sign is already present
#   4. If not, modifies the command to add -S flag
#   5. Returns updated command via JSON output
#
# Exit codes:
#   0 - Always (hook either modifies command or passes through unchanged)
#
# To skip this hook:
#   - Set SKIP_SIGNED_COMMITS_HOOK=1 environment variable
#   - Or include --no-gpg-sign in your command (explicit opt-out)
#
# Requirements:
#   - GPG or SSH signing must be configured in git
#   - Both methods require user.signingkey to be set
#   - For GPG: git config --get user.signingkey (returns GPG key ID)
#   - For SSH: git config --get gpg.format (returns 'ssh') AND
#              git config --get user.signingkey (returns path like ~/.ssh/id_ed25519.pub)
#
# Note: This hook modifies the command before execution using updatedInput.
#       It does NOT block unsigned commits - it automatically signs them.

set -e

# Require jq for JSON parsing — fail open (exit 0) if missing so Bash tool use
# isn't blocked by infra gaps. The hook simply won't auto-sign; commits still
# pass through to git, which has its own commit.gpgsign settings.
if ! command -v jq &>/dev/null; then
  echo "❌ enforce-signed-commits hook requires 'jq'. Install it and retry." >&2
  exit 0
fi

# Read tool input from stdin. The `|| exit 0` makes the "exit 0 always"
# contract honest even with set -e — if stdin is malformed (shouldn't happen
# in normal Claude Code operation but possible under manual invocation),
# we no-op instead of blocking the Bash tool.
INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""') || exit 0

# Only process "git commit" commands (with word boundaries)
# This matches: git commit, git commit -m, etc.
# But NOT: git commit-msg, git commit-tree, echo "git commit"
if [[ ! "$COMMAND" =~ (^|[[:space:]\&\;\|])git[[:space:]]+commit([[:space:]]|$) ]]; then
  exit 0
fi

# Allow explicit opt-out via environment variable
if [[ "${SKIP_SIGNED_COMMITS_HOOK:-}" == "1" ]]; then
  echo "⏭️  Signed commits hook skipped (SKIP_SIGNED_COMMITS_HOOK=1)" >&2
  exit 0
fi

# Skip in CI environments - CI may have different signing requirements
if [[ "${CI:-}" == "true" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  exit 0
fi

# Verify signing is configured before injecting -S
# Both GPG and SSH signing require user.signingkey to be set
if ! git config --get user.signingkey >/dev/null 2>&1; then
  echo "⚠️  Git signing not configured (user.signingkey not set). Skipping auto-sign." >&2
  echo "   For GPG: git config --global user.signingkey <key-id>" >&2
  echo "   For SSH: git config --global gpg.format ssh && git config --global user.signingkey ~/.ssh/id_ed25519.pub" >&2
  exit 0
fi

# Check for explicit opt-out (--no-gpg-sign)
# Use word boundaries to ensure we match the flag, not text in a message
if printf '%s' "$COMMAND" | grep -qE -- '(^|[[:space:]])--no-gpg-sign([[:space:]]|$)'; then
  echo "⚠️  Commit without signing (--no-gpg-sign detected)" >&2
  exit 0
fi

# Note: We intentionally don't check for existing -S/--gpg-sign flags.
# Reason: Detecting flags vs text in quoted strings is error-prone.
# Git handles duplicate -S flags gracefully (signs once), so it's safer
# to always inject -S than to risk missing an unsigned commit.

# Inject -S flag into the git commit command
# Handle various command patterns:
#   git commit -m "msg"        -> git commit -S -m "msg"
#   git commit --amend         -> git commit -S --amend
#   git commit                 -> git commit -S
#   git commit --fixup=HEAD    -> git commit -S --fixup=HEAD
#   git commit --squash=abc    -> git commit -S --squash=abc
#
# We insert -S right after "git commit" to ensure proper flag ordering
# Using printf for safer interpolation (avoids issues with special characters)
MODIFIED_COMMAND=$(printf '%s' "$COMMAND" | sed -E 's/(git[[:space:]]+commit)([[:space:]]|$)/\1 -S\2/')

echo "🔐 Auto-signing commit (added -S flag)" >&2

# Return JSON with updated command
# This tells Claude Code to use the modified command instead
jq -n \
  --arg cmd "$MODIFIED_COMMAND" \
  '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "updatedInput": {
        "command": $cmd
      }
    }
  }'

exit 0
