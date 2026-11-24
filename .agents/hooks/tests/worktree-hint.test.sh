#!/bin/bash
# Test harness for the "create a worktree first" hint printed by
# hooks/enforce-worktree.sh and hooks/enforce-worktree-bash.sh when they block.
#
# The hint must name a command that exists where the hook runs: the estate-wt
# launcher when one is on PATH, beside the hook (agent-estate, reached through
# symlinks) or in the repo, and otherwise a plain `git worktree add`
# (delivery-ops#1088: vendored copies named a missing .agents/bin/estate-wt).
#
# Also vendored into consumer repos (.agents/hooks/tests/, by estate-sync), where
# only some of the two hooks may be present and agent-estate's bin/estate-wt is
# not: cases for an absent hook or launcher are skipped there, never failed.
#
# Usage: hooks/tests/worktree-hint.test.sh
set -u

HOOKS="$(cd "$(dirname "$0")/.." && pwd)"
PRESENT=()
for h in enforce-worktree.sh enforce-worktree-bash.sh; do
  if [[ -x "$HOOKS/$h" ]]; then
    PRESENT+=("$h")
  elif [[ -e "$HOOKS/$h" ]]; then
    echo "hook not executable: $HOOKS/$h" >&2; exit 1
  fi
done
(( ${#PRESENT[@]} )) || { echo "neither enforce-worktree.sh nor enforce-worktree-bash.sh is in $HOOKS" >&2; exit 1; }
# agent-estate itself: the hooks sit beside bin/estate-wt, which they name
ESTATE_WT="$(cd "$HOOKS/.." && pwd -P)/bin/estate-wt"
[[ -x "$ESTATE_WT" ]] || ESTATE_WT=""
command -v jq >/dev/null 2>&1 || { echo "jq is required to run these tests" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wth-test.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
TMP="$(cd "$TMP" && pwd -P)" || exit 1
[[ -d "$TMP" && "$(basename "$TMP")" == wth-test.* ]] || { echo "refusing: unexpected TMP '$TMP'" >&2; exit 1; }
trap 'rm -rf -- "$TMP"' EXIT

# A PATH without any estate-wt on it, so the developer's own install can't
# decide the outcome.
CLEAN_PATH=""
IFS=: read -r -a _dirs <<< "$PATH"
for d in "${_dirs[@]}"; do
  [[ -n "$d" && ! -e "$d/estate-wt" ]] && CLEAN_PATH="${CLEAN_PATH:+$CLEAN_PATH:}$d"
done

GIT="git -c commit.gpgsign=false -c tag.gpgsign=false -c core.hooksPath=/dev/null -c init.defaultBranch=trunk"
(
  set -e
  $GIT init -q --bare "$TMP/origin.git"
  $GIT init -q "$TMP/seed"
  cd "$TMP/seed"
  $GIT config user.email test@example.com
  $GIT config user.name Test
  echo hello > file.txt
  $GIT add file.txt
  $GIT commit -qm init
  $GIT push -q "$TMP/origin.git" HEAD:trunk
  $GIT clone -q "$TMP/origin.git" "$TMP/repo"
  # A consumer repo vendors the hooks as plain files, with no launcher.
  mkdir -p "$TMP/repo/.agents/hooks"
  for h in "${PRESENT[@]}"; do cp "$HOOKS/$h" "$TMP/repo/.agents/hooks/"; done
) || { echo "fixture setup failed" >&2; exit 1; }
MAIN="$TMP/repo"
VENDORED="$MAIN/.agents/hooks"

PASS=0
FAIL=0
SKIP=0
OUT=""
CODE=0

# hint <hook path> <cwd> <payload json> [extra PATH dir]  -> CODE, OUT (stderr)
hint() {
  local hook="$1" cwd="$2" payload="$3" path="$CLEAN_PATH"
  [[ -n "${4:-}" ]] && path="$4:$path"
  OUT=$( cd "$cwd" && printf '%s' "$payload" | env -u CI -u GITHUB_ACTIONS PATH="$path" "$hook" 2>&1 >/dev/null )
  CODE=$?
}

# expect <label> <substring that must appear> [substring that must not]
expect() {
  local label="$1" want="$2" unwanted="${3:-}"
  if [[ "$CODE" == 2 && "$OUT" == *"$want"* && ( -z "$unwanted" || "$OUT" != *"$unwanted"* ) ]]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$label"; return 0
  fi
  FAIL=$((FAIL + 1))
  printf '  FAIL %s (exit %s)\n       wanted: %s\n' "$label" "$CODE" "$want"
  [[ -n "$unwanted" ]] && printf '       not:    %s\n' "$unwanted"
  printf '%s\n' "$OUT" | sed 's/^/         /'
}

# has <hook> — the hook is present here; otherwise counts a skip and returns 1
has() {
  [[ -x "$HOOKS/$1" ]] && return 0
  SKIP=$((SKIP + 1)); printf '  skip %s (%s is not vendored here)\n' "${2:-$1 cases}" "$1"; return 1
}

EDIT=$(jq -n --arg f "$MAIN/file.txt" '{tool_name:"Edit", tool_input:{file_path:$f}}')
BASH_CMD=$(jq -n '{tool_name:"Bash", tool_input:{command:"echo scribble > file.txt"}}')
PLAIN="git -C $MAIN worktree add .worktrees/<slug> -b <branch> origin/trunk"

echo "worktree hint"

# The cases below that use one hook to cover behaviour both share (PATH, repo
# launcher, default-branch fallback) take whichever is present here.
if [[ -x "$HOOKS/enforce-worktree.sh" ]]; then
  ANY_HOOK="$VENDORED/enforce-worktree.sh" ANY_PAYLOAD="$EDIT"
else
  ANY_HOOK="$VENDORED/enforce-worktree-bash.sh" ANY_PAYLOAD="$BASH_CMD"
fi
# the repo-launcher pair deliberately exercises both hooks when it can
if [[ -x "$HOOKS/enforce-worktree-bash.sh" ]]; then
  BASH_HOOK="$VENDORED/enforce-worktree-bash.sh" BASH_PAYLOAD="$BASH_CMD"
else
  BASH_HOOK="$ANY_HOOK" BASH_PAYLOAD="$ANY_PAYLOAD"
fi

if has enforce-worktree.sh "vendored enforce-worktree.sh, no launcher"; then
  hint "$VENDORED/enforce-worktree.sh" "$MAIN" "$EDIT"
  expect "vendored enforce-worktree.sh, no launcher: plain git worktree add" "$PLAIN" "estate-wt"
fi

if has enforce-worktree-bash.sh "vendored enforce-worktree-bash.sh, no launcher"; then
  hint "$VENDORED/enforce-worktree-bash.sh" "$MAIN" "$BASH_CMD"
  expect "vendored enforce-worktree-bash.sh, no launcher: plain git worktree add" "$PLAIN" "estate-wt"
fi

# agent-estate only: the canonical copy, reached directly or through a symlink,
# names the launcher beside it. A vendored test has no bin/estate-wt to name.
if [[ -z "$ESTATE_WT" ]]; then
  SKIP=$((SKIP + 2)); echo "  skip canonical/symlinked launcher cases (no bin/estate-wt beside these hooks: a vendored copy)"
else
  if has enforce-worktree.sh "canonical enforce-worktree.sh names agent-estate's launcher"; then
    hint "$HOOKS/enforce-worktree.sh" "$MAIN" "$EDIT"
    expect "canonical enforce-worktree.sh names agent-estate's launcher" "$ESTATE_WT -C $MAIN new <slug>"
  fi
  if has enforce-worktree-bash.sh "symlinked enforce-worktree-bash.sh resolves to agent-estate's launcher"; then
    ln -s "$HOOKS/enforce-worktree-bash.sh" "$TMP/linked-bash-hook.sh"
    hint "$TMP/linked-bash-hook.sh" "$MAIN" "$BASH_CMD"
    expect "symlinked enforce-worktree-bash.sh resolves to agent-estate's launcher" "$ESTATE_WT -C $MAIN new <slug>"
  fi
fi

mkdir -p "$TMP/onpath"
printf '#!/bin/sh\nexit 0\n' > "$TMP/onpath/estate-wt"; chmod +x "$TMP/onpath/estate-wt"
hint "$ANY_HOOK" "$MAIN" "$ANY_PAYLOAD" "$TMP/onpath"
expect "estate-wt on PATH is named bare" "     estate-wt -C $MAIN new <slug>"

mkdir -p "$MAIN/.agents/bin"
printf '#!/bin/sh\nexit 0\n' > "$MAIN/.agents/bin/estate-wt"
hint "$ANY_HOOK" "$MAIN" "$ANY_PAYLOAD"
expect "a launcher in the repo that is not executable is ignored" "$PLAIN"
chmod +x "$MAIN/.agents/bin/estate-wt"
hint "$BASH_HOOK" "$MAIN" "$BASH_PAYLOAD"
expect "a vendored .agents/bin/estate-wt is named" "$MAIN/.agents/bin/estate-wt -C $MAIN new <slug>"
rm -rf "$MAIN/.agents/bin"

git -C "$MAIN" remote set-head origin -d >/dev/null 2>&1
git -C "$MAIN" update-ref refs/remotes/origin/main refs/remotes/origin/trunk
hint "$ANY_HOOK" "$MAIN" "$ANY_PAYLOAD"
expect "no origin/HEAD: falls back to origin/main when it exists" "origin/main" "origin/<default>"
git -C "$MAIN" update-ref -d refs/remotes/origin/main
hint "$ANY_HOOK" "$MAIN" "$ANY_PAYLOAD"
expect "no origin/HEAD and no main/master: a placeholder, not a guess" "-b <branch> origin/<default>"

echo
echo "  $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" == "0" ]] || exit 1
exit 0
