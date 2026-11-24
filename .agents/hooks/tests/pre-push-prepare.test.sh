#!/bin/bash
# Test harness for hooks/pre-push-prepare.sh: it must act on the checkout being
# PUSHED (resolved from `git -C`, a preceding `cd`, or the payload's cwd), not on
# the hook's own cwd, and a copy vendored in one repo must leave other repos alone.
#
# Builds throwaway repos (a bare origin, a main checkout, a linked worktree, an
# unrelated repo) with an isolated git config, so the developer's global config
# (commit signing in particular) never applies.
#
# Usage: hooks/tests/pre-push-prepare.test.sh
set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/pre-push-prepare.sh"
[[ -x "$HOOK" ]] || { echo "hook not executable: $HOOK" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required to run these tests" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ppp-test.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
TMP="$(cd "$TMP" && pwd -P)" || exit 1
[[ -d "$TMP" && "$(basename "$TMP")" == ppp-test.* ]] || { echo "refusing: unexpected TMP '$TMP'" >&2; exit 1; }
trap 'rm -rf -- "$TMP"' EXIT
printf '[user]\n\tname = Test\n\temail = test@example.com\n[init]\n\tdefaultBranch = main\n' > "$TMP/gitconfig"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
# The hook may be a copy vendored into a consumer repo (.agents/hooks/), which
# acts only on that repo's pushes; these cases push throwaway repos, so run an
# unscoped copy of the same bytes from outside any hooks directory.
mkdir -p "$TMP/estate-hooks" && cp -p "$HOOK" "$TMP/estate-hooks/pre-push-prepare.sh" || { echo "copying the hook failed" >&2; exit 1; }
HOOK="$TMP/estate-hooks/pre-push-prepare.sh"

g() { git -c core.hooksPath=/dev/null "$@"; }
mkrepo() { # mkrepo <name> -> bare origin + main checkout at $TMP/<name>
  local n="$1"
  g init -q --bare "$TMP/$n-origin.git"
  g clone -q "$TMP/$n-origin.git" "$TMP/$n" 2>/dev/null
  (cd "$TMP/$n" && echo base > f.txt && g add f.txt && g commit -qm base && g push -q origin main)
  g -C "$TMP/$n" remote set-head origin main >/dev/null
}
commit_n() { # commit_n <dir> <n>
  local i; for ((i = 1; i <= $2; i++)); do (cd "$1" && echo "$i-$RANDOM" >> w.txt && g add w.txt && g commit -qm "c$i"); done
}

mkrepo repo
MAIN="$TMP/repo"
g -C "$MAIN" worktree add -q "$TMP/wt" -b feature
WT="$TMP/wt"
mkrepo other
OTHER="$TMP/other"
g -C "$OTHER" checkout -qb topic
NOGIT="$TMP/workspace-root"      # like ~/Workspace/<org>: not a git checkout
mkdir -p "$NOGIT"

PASS=0; FAIL=0; OUT=""; CODE=0
run() { # run <hook> <cwd> <command> [payload-cwd]
  local payload
  payload=$(jq -n --arg c "$3" --arg d "${4:-}" '{tool_name:"Bash", tool_input:{command:$c}} + (if $d == "" then {} else {cwd:$d} end)')
  OUT=$(cd "$2" && printf '%s' "$payload" | env -u CI -u GITHUB_ACTIONS -u ALLOW_MULTIPLE_COMMITS "$1" 2>"$TMP/err")
  CODE=$?
}
expect() { # expect <label> <want-exit> [stdout-substring]
  if [[ "$CODE" == "$2" && ( -z "${3:-}" || "$OUT" == *"$3"* ) ]]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL %s (exit %s, wanted %s)\n' "$1" "$CODE" "$2"
    sed 's/^/         /' "$TMP/err"
  fi
}

echo "pre-push-prepare.sh"

# two commits ahead on the worktree branch: the single-commit nudge must fire
commit_n "$WT" 2

run "$HOOK" "$NOGIT" "cd $WT && git push -u origin feature"
expect "cd <worktree> && git push, from a non-git cwd: acts on the worktree" 2

run "$HOOK" "$NOGIT" "git -C $WT push -u origin feature"
expect "git -C <worktree> push: acts on the worktree" 2

run "$HOOK" "$NOGIT" "git push -u origin feature" "$WT"
expect "bare git push, payload cwd = worktree: acts on the worktree" 2

run "$HOOK" "$NOGIT" "ALLOW_MULTIPLE_COMMITS=1 git -C $WT push"
expect "ALLOW_MULTIPLE_COMMITS=1 still lets it through" 0

run "$HOOK" "$NOGIT" "git status"
expect "not a push: untouched" 0

run "$HOOK" "$NOGIT" "cd $MAIN && git push"
expect "push from the default branch: untouched" 0

# one commit ahead, origin/main moved: the hook rebases THE WORKTREE and adds
# --force-with-lease; the main checkout is left alone
g -C "$WT" reset -q --hard main
commit_n "$WT" 1
(cd "$MAIN" && echo moved >> f.txt && g commit -qam moved && g push -q origin main)
g -C "$MAIN" reset -q --hard HEAD~1       # main checkout now BEHIND origin: it must not move
MAIN_HEAD=$(g -C "$MAIN" rev-parse HEAD)
run "$HOOK" "$NOGIT" "cd $WT && git push origin feature"
expect "rebases the pushed worktree and injects --force-with-lease" 0 "--force-with-lease"
if g -C "$WT" merge-base --is-ancestor origin/main HEAD && [[ "$(g -C "$MAIN" rev-parse HEAD)" == "$MAIN_HEAD" ]]; then
  PASS=$((PASS + 1)); echo "  ok   the worktree is on origin/main; the main checkout did not move"
else
  FAIL=$((FAIL + 1)); echo "  FAIL rebase landed on the wrong checkout"
fi

# git -C <worktree> push after a rebase also gets --force-with-lease (review finding)
g -C "$WT" reset -q --hard origin/main~1 2>/dev/null || g -C "$WT" reset -q --hard origin/main
commit_n "$WT" 1
(cd "$MAIN" && g pull -q --ff-only && echo again >> f.txt && g commit -qam again && g push -q origin main)
run "$HOOK" "$NOGIT" "git -C $WT push origin feature"
expect "git -C form: rebased and --force-with-lease injected after -C" 0 "git -C $WT push --force-with-lease"

# the lease goes into the push the resolver acted on, not an earlier echoed
# "git push" (agent-estate#23: the real push went out without one)
g -C "$WT" reset -q --hard origin/main~1
commit_n "$WT" 1
(cd "$MAIN" && g pull -q --ff-only && echo third >> f.txt && g commit -qam third && g push -q origin main)
run "$HOOK" "$NOGIT" "echo \"git push origin\"; cd $WT && git push origin feature"
GOT=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null)
WANT="echo \"git push origin\"; cd $WT && git push --force-with-lease origin feature"
if [[ "$CODE" == 0 && "$GOT" == "$WANT" ]]; then
  PASS=$((PASS + 1)); echo "  ok   --force-with-lease lands on the real push, not the echoed string"
else
  FAIL=$((FAIL + 1)); printf '  FAIL lease placement (exit %s)\n         want: %s\n         got:  %s\n' "$CODE" "$WANT" "$GOT"
  sed 's/^/         /' "$TMP/err"
fi

# scope: a copy vendored INSIDE repo acts on repo's checkouts, never on another repo
mkdir -p "$MAIN/.agents/hooks" && cp "$HOOK" "$MAIN/.agents/hooks/pre-push-prepare.sh"
commit_n "$OTHER" 2
run "$MAIN/.agents/hooks/pre-push-prepare.sh" "$NOGIT" "cd $OTHER && git push origin topic"
expect "vendored in repo: a push of ANOTHER repo is left alone" 0
g -C "$WT" reset -q --hard origin/main && commit_n "$WT" 2
run "$MAIN/.agents/hooks/pre-push-prepare.sh" "$NOGIT" "cd $WT && git push origin feature"
expect "vendored in repo: a push of its own worktree is checked" 2

echo
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" == "0" ]] || exit 1
exit 0
