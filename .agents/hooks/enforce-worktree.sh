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
# itself has a bug, a human must fix it manually (edit the file or remove
# from settings.json).
#
# Note: This hook covers Edit, Write, and NotebookEdit tools only. Bash tool
# writes that INTRODUCE content into a main checkout (rsync,
# bin/devcontainer-exec, git stash pop/apply, git apply, patch, sed -i, …) are
# covered only where the companion hook enforce-worktree-bash.sh is ALSO
# registered on the Bash matcher. Check the repo's settings.json (or
# .agents/hooks.toml): without it, Bash writes are instruction-enforced only.

# Guard: jq required for JSON parsing. jq is a setup prerequisite in this
# workspace; warn LOUDLY if it goes missing rather than disabling silently
# (a silently-disabled mandate is how main got scribbled on). Fail open — a
# missing common tool must not halt all edits.
if ! command -v jq >/dev/null 2>&1; then
  echo "⚠️  enforce-worktree.sh: jq not found — WORKTREE MANDATE DISABLED until jq is installed" >&2
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

# Print a worktree command that works here. Prefer the estate-wt launcher: on
# PATH, beside this hook (agent-estate, reached through symlinks), or in the
# repo. Repos that vendor this hook as a plain file usually have none of these
# (delivery-ops#1088), so fall back to plain `git worktree add`.
_worktree_hint() { # $1 repo top-level ("" when unknown), $2 verb ("edit" / "run it")
  local top="$1" src dir ewt="" c def=""
  if command -v estate-wt >/dev/null 2>&1; then
    ewt=estate-wt
  else
    src=${BASH_SOURCE[0]}
    while [ -L "$src" ]; do
      dir=$(cd -P "$(dirname "$src")" && pwd); src=$(readlink "$src")
      case $src in /*) ;; *) src=$dir/$src ;; esac
    done
    dir=$(cd -P "$(dirname "$src")/.." 2>/dev/null && pwd)
    for c in ${dir:+"$dir/bin/estate-wt"} ${top:+"$top/bin/estate-wt" "$top/.agents/bin/estate-wt"}; do
      if [ -f "$c" ] && [ -x "$c" ]; then ewt=$c; break; fi
    done
  fi
  echo "   Create a worktree first, then $2 there:" >&2
  if [ -n "$ewt" ]; then
    echo "     $ewt -C ${top:-<repo>} new <slug>     (prints the new worktree's path)" >&2
  else
    if [ -n "$top" ]; then
      def=$(git -C "$top" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
      def=${def#origin/}
      for c in main master; do
        [ -z "$def" ] && git -C "$top" rev-parse --verify --quiet "refs/remotes/origin/$c" >/dev/null && def=$c
      done
    fi
    echo "     git -C ${top:-<repo>} worktree add .worktrees/<slug> -b <branch> origin/${def:-<default>}" >&2
  fi
}

# We're in the main checkout — block
echo "❌ Blocked: Cannot modify files in the main checkout." >&2
TOP=$(cd "$CHECK_DIR" && git rev-parse --show-toplevel 2>/dev/null) || TOP=""
_worktree_hint "$TOP" edit
echo "   File: $FILE_PATH" >&2
exit 2
