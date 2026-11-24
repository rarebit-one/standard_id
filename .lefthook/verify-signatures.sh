#!/bin/bash
# Verify all commits to be pushed have valid signatures (GPG or SSH).
#
# Checks every commit between the remote tracking branch and HEAD that is not
# already on the remote's default branch.
# Exits non-zero if any unsigned or badly-signed commits are found.
#
# Accepted signature statuses: G (good), U (good but untrusted key)
# Rejected: N (none), B (bad), E (can't check), X (expired), Y (expired key), R (revoked)

set -eo pipefail

source "$(dirname "$0")/lib/git-upstream.sh"

# Commits already on the remote's default branch are not introduced by this push.
# After a rebase onto main they fall inside MERGE_BASE..HEAD, and GitHub's
# web-flow signature on squash merges shows as E (can't check) locally.
DEFAULT_BRANCH=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || DEFAULT_BRANCH="origin/main"
EXCLUDE=()
if git rev-parse --verify --quiet "$DEFAULT_BRANCH" >/dev/null; then
  EXCLUDE=(--not "$DEFAULT_BRANCH")
fi

COMMITS=$(git log "$MERGE_BASE..HEAD" "${EXCLUDE[@]}" --format="%H" 2>/dev/null) || {
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
  # Accept G (good) and U (good but untrusted key). U is allowed because developers
  # may use locally-generated keys not yet in the team's trust store. The goal is to
  # ensure all commits are signed, not to verify signer identity.
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
  echo "To fix:" >&2
  echo "  Single commit:    git commit --amend --no-edit -S" >&2
  echo "  Multiple commits: git rebase --exec 'git commit --amend --no-edit -S' $UPSTREAM" >&2
  exit 1
fi

echo "All commits are signed"
