#!/bin/bash
# Enforce worktree-only file modifications for Claude Code
#
# Runs on PreToolUse for Edit, Write, and NotebookEdit tools.
# Blocks all file modifications in the main checkout — changes must
# happen inside a git worktree (.worktrees/<name>/).
#
# Exit codes:
#   0 — allow (in a worktree, CI, or non-git path)
#   2 — block (in main checkout)
#
# No interactive bypass — CI environments are the only exception. If the hook
# itself has a bug, a human must fix it manually (edit the file or remove from
# settings.json).
#
# Note: This hook covers Edit, Write, and NotebookEdit tools. Bash tool writes
# (echo/sed/tee/cp) are not intercepted — the CLAUDE.md instruction is the
# enforcement layer for those. Covering Bash reliably would require parsing
# arbitrary shell commands, which is brittle.

# Guard: jq required for JSON parsing
if ! command -v jq >/dev/null 2>&1; then
  echo "⚠️  enforce-worktree.sh: jq not found, hook disabled" >&2
  exit 0
fi

# Skip in CI environments
if [[ "${CI:-}" == "true" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  exit 0
fi

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""') || exit 0

# Extract file path based on tool (NotebookEdit uses notebook_path, not file_path)
case "$TOOL_NAME" in
  Edit|Write)
    FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""') || exit 0
    ;;
  NotebookEdit)
    FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.notebook_path // .tool_input.file_path // ""') || exit 0
    ;;
  *)
    exit 0
    ;;
esac

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# Find an existing directory to run git commands in
if [[ -d "$FILE_PATH" ]]; then
  CHECK_DIR="$FILE_PATH"
elif [[ -e "$FILE_PATH" ]]; then
  CHECK_DIR=$(dirname "$FILE_PATH")
else
  # File doesn't exist yet — walk up to find an existing directory
  CHECK_DIR=$(dirname "$FILE_PATH")
  while [[ ! -d "$CHECK_DIR" ]] && [[ "$CHECK_DIR" != "/" ]]; do
    CHECK_DIR=$(dirname "$CHECK_DIR")
  done
fi

if [[ ! -d "$CHECK_DIR" ]]; then
  exit 0
fi

# Check if we're inside a git repository at all
GIT_DIR=$(cd "$CHECK_DIR" && git rev-parse --git-dir 2>/dev/null) || exit 0

# Make relative paths absolute
if [[ "$GIT_DIR" != /* ]]; then
  GIT_DIR=$(cd "$CHECK_DIR" && cd "$GIT_DIR" && pwd) || exit 0
fi

# If git-dir contains /worktrees/, we're in a worktree — allow
if [[ "$GIT_DIR" == *".git/worktrees/"* ]]; then
  exit 0
fi

# We're in the main checkout — block
echo "❌ Blocked: Cannot modify files in the main checkout." >&2
echo "   Create a worktree first: /worktree or /start <issue>" >&2
echo "   File: $FILE_PATH" >&2
exit 2
