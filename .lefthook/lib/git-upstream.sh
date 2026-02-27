#!/bin/bash
# Shared upstream detection logic for lefthook scripts.
#
# Sets UPSTREAM and MERGE_BASE variables.
# Source this file from other scripts:
#   source "$(dirname "$0")/lib/git-upstream.sh"

UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null) || UPSTREAM="origin/main"

MERGE_BASE=$(git merge-base "$UPSTREAM" HEAD 2>/dev/null) || {
  echo "Failed to find merge-base with $UPSTREAM" >&2
  exit 1
}
