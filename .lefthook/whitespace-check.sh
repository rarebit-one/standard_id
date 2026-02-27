#!/bin/bash
# Check for whitespace errors across all commits being pushed.
#
# Uses the same upstream detection logic as verify-signatures.sh
# to determine the base commit range.

set -eo pipefail

UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null) || UPSTREAM="origin/main"
MERGE_BASE=$(git merge-base "$UPSTREAM" HEAD 2>/dev/null) || {
  echo "Failed to find merge-base with $UPSTREAM" >&2
  exit 1
}

exec git --no-pager log --check "$MERGE_BASE..HEAD"
