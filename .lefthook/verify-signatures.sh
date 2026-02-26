#!/bin/bash
# Verify all commits to be pushed have valid signatures (GPG or SSH).
#
# Checks every commit between the remote tracking branch and HEAD.
# Exits non-zero if any unsigned or badly-signed commits are found.
#
# Accepted signature statuses: G (good), U (good but untrusted key)
# Rejected: N (none), B (bad), E (can't check), X (expired), Y (expired key), R (revoked)

set -e

MERGE_BASE=$(git merge-base origin/main HEAD 2>/dev/null) || {
  echo "Failed to find merge-base with origin/main" >&2
  exit 1
}

COMMITS=$(git log "$MERGE_BASE..HEAD" --format="%H" 2>/dev/null) || {
  echo "Failed to list commits between merge-base and HEAD" >&2
  exit 1
}

if [[ -z "$COMMITS" ]]; then
  echo "No new commits to verify"
  exit 0
fi

UNSIGNED_COMMITS=()
while IFS= read -r commit; do
  SIG_STATUS=$(git log --format="%G?" -1 "$commit" 2>/dev/null || echo "N")
  if [[ "$SIG_STATUS" != "G" && "$SIG_STATUS" != "U" ]]; then
    SHORT_HASH=$(git rev-parse --short "$commit")
    SUBJECT=$(git log --format="%s" -1 "$commit")
    UNSIGNED_COMMITS+=("  $SHORT_HASH ($SIG_STATUS): $SUBJECT")
  fi
done <<< "$COMMITS"

if [[ ${#UNSIGNED_COMMITS[@]} -gt 0 ]]; then
  echo "Unsigned commits detected:" >&2
  for line in "${UNSIGNED_COMMITS[@]}"; do
    echo "$line" >&2
  done
  echo "" >&2
  echo "To fix, amend with signature: git commit --amend --no-edit -S" >&2
  exit 1
fi

echo "All commits are signed"
