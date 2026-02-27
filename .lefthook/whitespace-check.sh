#!/bin/bash
# Check for whitespace errors across all commits being pushed.

set -eo pipefail

source "$(dirname "$0")/lib/git-upstream.sh"

exec git --no-pager log --check "$MERGE_BASE..HEAD"
