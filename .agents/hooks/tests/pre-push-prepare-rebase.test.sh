#!/bin/bash
# Test harness for the rebase step of hooks/pre-push-prepare.sh: whatever goes
# wrong, the checkout being pushed must end up exactly where it started — on its
# branch (never detached), at its original commit, with no rebase in progress —
# and the hook must exit non-zero with a reason. Only an allowed push (exit 0)
# moves the branch.
#
# Scenarios: a clean rebase; a conflict; a signing failure; a signed rebase; the
# harness killing the hook mid-rebase (SIGTERM and SIGKILL); a blocked push
# (commit count, `gh pr create`); a branch with merge commits; a rebase already
# in progress; an untracked file in the way; the repo's own post-checkout hook.
#
# Builds throwaway repos with an isolated git config, so the developer's global
# config (commit signing in particular) never applies.
#
# Usage: hooks/tests/pre-push-prepare-rebase.test.sh
set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/pre-push-prepare.sh"
[[ -x "$HOOK" ]] || { echo "hook not executable: $HOOK" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required to run these tests" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ppp-rebase-test.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
TMP="$(cd "$TMP" && pwd -P)" || exit 1
[[ -d "$TMP" && "$(basename "$TMP")" == ppp-rebase-test.* ]] || { echo "refusing: unexpected TMP '$TMP'" >&2; exit 1; }
kill_signers() { [[ -f "$TMP/signer.pids" ]] && xargs kill 2>/dev/null < "$TMP/signer.pids"; rm -f "$TMP/signer.pids"; }
trap 'kill_signers; rm -rf -- "$TMP"' EXIT
printf '[user]\n\tname = Test\n\temail = test@example.com\n\tsigningkey = TESTKEY\n[init]\n\tdefaultBranch = main\n' > "$TMP/gitconfig"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
# The hook may be a copy vendored into a consumer repo (.agents/hooks/), which
# acts only on that repo's pushes; these cases push throwaway repos, so run an
# unscoped copy of the same bytes from outside any hooks directory.
mkdir -p "$TMP/estate-hooks" && cp -p "$HOOK" "$TMP/estate-hooks/pre-push-prepare.sh" || { echo "copying the hook failed" >&2; exit 1; }
HOOK="$TMP/estate-hooks/pre-push-prepare.sh"
# the hook's scratch worktrees land here, so leftovers are visible to the tests
SCRATCH_TMP="$TMP/scratch"
mkdir -p "$SCRATCH_TMP"

# fake gpg programs: git runs `<program> --status-fd=2 -bsau <key>` with the
# payload on stdin and wants SIG_CREATED on fd 2 and a signature on stdout
cat > "$TMP/signer-ok" <<'EOF'
#!/bin/sh
cat >/dev/null
echo '[GNUPG:] SIG_CREATED D 1 8 00 0 TESTKEY' >&2
printf -- '-----BEGIN PGP SIGNATURE-----\n\nZmFrZQ==\n-----END PGP SIGNATURE-----\n'
EOF
cat > "$TMP/signer-fail" <<'EOF'
#!/bin/sh
cat >/dev/null
echo 'gpg: signing failed: No pinentry' >&2
exit 2
EOF
# a signer that hangs, like one waiting on an unattended approval prompt
cat > "$TMP/signer-slow" <<EOF
#!/bin/sh
echo \$\$ >> "$TMP/signer.pids"
exec sleep 30
EOF
chmod +x "$TMP"/signer-*

g() { git -c core.hooksPath=/dev/null "$@"; }

N=0
# fresh: a bare origin, a main checkout ($MAIN) and a linked worktree ($WT) on
# branch `feature`, one commit ahead of a main that has since moved on (no conflict).
fresh() {
  N=$((N + 1))
  local o="$TMP/r$N-origin.git"
  MAIN="$TMP/r$N"; WT="$TMP/r$N-wt"
  g init -q --bare "$o"
  g clone -q "$o" "$MAIN" 2>/dev/null
  (cd "$MAIN" && printf 'one\ntwo\nthree\n' > f.txt && g add f.txt && g commit -qm base && g push -q origin main)
  g -C "$MAIN" remote set-head origin main >/dev/null
  g -C "$MAIN" worktree add -q "$WT" -b feature
  (cd "$WT" && echo feature > feat.txt && g add feat.txt && g commit -qm feat)
  advance_main "upstream.txt" "upstream"
}
advance_main() { # advance_main <file> <content>: a new commit on origin/main
  (cd "$MAIN" && echo "$2" > "$1" && g add "$1" && g commit -qm "main: $1" && g push -q origin main)
}

PASS=0; FAIL=0; OUT=""; CODE=0
run() { # run <command> [timeout-args…]: the hook, with the payload cwd = $WT
  local cmd="$1" payload
  shift
  payload=$(jq -n --arg c "$cmd" --arg d "$WT" '{tool_name:"Bash", tool_input:{command:$c}, cwd:$d}')
  OUT=$(cd "$TMP" && printf '%s' "$payload" \
    | env -u CI -u GITHUB_ACTIONS -u ALLOW_MULTIPLE_COMMITS -u SKIP_PRE_PUSH_PREPARE TMPDIR="$SCRATCH_TMP" \
      ${1:+timeout "$@"} "$HOOK" 2>"$TMP/err")
  CODE=$?
}
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; sed 's/^/         | /' "$TMP/err"; }
expect() { # expect <label> <want-exit> [stderr-substring] [stdout-substring]
  if [[ "$CODE" != "$2" ]]; then bad "$1" "exit $CODE, wanted $2"; return; fi
  if [[ -n "${3:-}" ]] && ! grep -qF -- "$3" "$TMP/err"; then bad "$1" "stderr lacks: $3"; return; fi
  if [[ -n "${4:-}" && "$OUT" != *"$4"* ]]; then bad "$1" "stdout lacks: $4"; return; fi
  ok "$1"
}
scratch_left() { # the number of scratch worktrees still registered or on disk
  local reg disk
  reg=$(g -C "$WT" worktree list --porcelain | grep -c "^worktree $SCRATCH_TMP/pre-push-prepare\." || true)
  disk=$(find "$SCRATCH_TMP" -mindepth 1 -maxdepth 1 -name 'pre-push-prepare.*' | wc -l | tr -d ' ')
  echo $((reg + disk))
}
# untouched <label> <sha>: $WT is on `feature` at <sha>, nothing in progress,
# no scratch worktree left behind
untouched() {
  local gd sym head
  gd=$(g -C "$WT" rev-parse --absolute-git-dir)
  sym=$(g -C "$WT" symbolic-ref -q HEAD || echo DETACHED)
  head=$(g -C "$WT" rev-parse HEAD)
  if [[ "$sym" != refs/heads/feature ]]; then bad "$1" "HEAD is $sym"
  elif [[ "$head" != "$2" ]]; then bad "$1" "HEAD moved: $head (was $2)"
  elif [[ -e "$gd/rebase-merge" || -e "$gd/rebase-apply" ]]; then bad "$1" "a rebase is in progress"
  elif [[ "$(scratch_left)" != 0 ]]; then bad "$1" "scratch worktree left behind"
  else ok "$1"; fi
}
on_main() { # on_main <label>: $WT is on `feature`, rebased onto origin/main
  local sym
  sym=$(g -C "$WT" symbolic-ref -q HEAD || echo DETACHED)
  if [[ "$sym" == refs/heads/feature ]] && g -C "$WT" merge-base --is-ancestor origin/main HEAD \
      && [[ "$(scratch_left)" == 0 && -z "$(g -C "$WT" status --porcelain)" ]]; then
    ok "$1"
  else
    bad "$1" "HEAD=$sym; rebased=$(g -C "$WT" merge-base --is-ancestor origin/main HEAD && echo yes || echo no); scratch=$(scratch_left)"
  fi
}

echo "pre-push-prepare.sh: rebase failure paths"

# --- a clean rebase is applied to the branch, and only then -------------------
fresh
run "git push origin feature"
expect "behind origin/main: rebased, lease injected" 0 "" "git push --force-with-lease origin feature"
on_main "  the branch (not a detached HEAD) holds the rebased commit; no scratch left"

# an explicit --force-with-lease: rebased and allowed, command left as typed
fresh
run "git push --force-with-lease origin feature"
expect "explicit --force-with-lease: allowed unchanged" 0
[[ -z "$OUT" ]] && ok "  no updatedInput emitted" || bad "  no updatedInput emitted" "stdout: $OUT"
on_main "  and the branch was rebased"

# --- a conflict leaves the checkout alone ------------------------------------
fresh
(cd "$WT" && printf 'one\nFEATURE\nthree\n' > f.txt && g commit -qam "feat: f" && g reset -q --soft HEAD~2 && g commit -qm feat)
(cd "$MAIN" && printf 'one\nMAIN\nthree\n' > f.txt && g commit -qam "main: f" && g push -q origin main)
BEFORE=$(g -C "$WT" rev-parse HEAD)
run "git push origin feature"
expect "conflict: blocked, names the file" 2 "f.txt"
untouched "  conflict: still on feature at the original commit, no rebase in progress" "$BEFORE"

# --- signing ------------------------------------------------------------------
fresh
g -C "$WT" config commit.gpgsign true
g -C "$WT" config gpg.program "$TMP/signer-fail"
BEFORE=$(g -C "$WT" rev-parse HEAD)
run "git push origin feature"
expect "signing fails mid-rebase: blocked with git's reason" 2 "signing failed"
untouched "  signing failure: checkout untouched" "$BEFORE"

g -C "$WT" config gpg.program "$TMP/signer-ok"
run "git push origin feature"
expect "signing works: rebased" 0 "" "--force-with-lease"
if g -C "$WT" cat-file commit HEAD | grep -q '^gpgsig '; then ok "  the rebased commit is signed"; else bad "  the rebased commit is signed"; fi

# signing enabled only for this branch (includeIf onbranch:): the detached
# scratch worktree does not match it, so the hook carries it over (Codex on #75)
fresh
printf '[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = %s\n[user]\n\temail = branch@example.com\n' "$TMP/signer-ok" > "$TMP/onbranch.inc"
g -C "$WT" config 'includeIf.onbranch:feature.path' "$TMP/onbranch.inc"
run "git push origin feature"
expect "signing via includeIf onbranch: rebased" 0 "" "--force-with-lease"
if g -C "$WT" cat-file commit HEAD | grep -q '^gpgsig '; then ok "  the rebased commit is still signed"; else bad "  the rebased commit is still signed"; fi
if g -C "$WT" log -1 --format=%ce | grep -qx branch@example.com; then ok "  with the branch's committer identity"; else bad "  with the branch's committer identity" "got $(g -C "$WT" log -1 --format=%ce)"; fi

# --- the harness kills the hook mid-rebase ------------------------------------
# (in place, this left the checkout detached in .git/rebase-merge)
fresh
g -C "$WT" config commit.gpgsign true
g -C "$WT" config gpg.program "$TMP/signer-slow"
BEFORE=$(g -C "$WT" rev-parse HEAD)
START=$SECONDS
run "git push origin feature" -s TERM 3
ELAPSED=$((SECONDS - START))
if [[ "$CODE" != 0 && "$ELAPSED" -lt 15 ]]; then ok "SIGTERM mid-rebase: the hook exits promptly (${ELAPSED}s)"; else bad "SIGTERM mid-rebase: the hook exits promptly" "exit $CODE after ${ELAPSED}s"; fi
untouched "  SIGTERM: checkout untouched, scratch worktree removed" "$BEFORE"
kill_signers

run "git push origin feature" -s KILL 3
if [[ "$CODE" != 0 ]]; then ok "SIGKILL mid-rebase: killed"; else bad "SIGKILL mid-rebase: killed" "exit $CODE"; fi
kill_signers
SYM=$(g -C "$WT" symbolic-ref -q HEAD || echo DETACHED)
GD=$(g -C "$WT" rev-parse --absolute-git-dir)
if [[ "$SYM" == refs/heads/feature && "$(g -C "$WT" rev-parse HEAD)" == "$BEFORE" && ! -e "$GD/rebase-merge" ]]; then
  ok "  SIGKILL: checkout untouched (only the scratch worktree is orphaned)"
else
  bad "  SIGKILL: checkout untouched" "HEAD=$SYM"
fi
# a later run sweeps an orphan once it is an hour old, never a fresh one
LEFT=$(find "$SCRATCH_TMP" -mindepth 1 -maxdepth 1 -name 'pre-push-prepare.*')
g -C "$WT" config gpg.program "$TMP/signer-ok"
if [[ -n "$LEFT" ]]; then
  touch -d '2 hours ago' "$LEFT"
  run "git push origin feature"
  expect "the next run succeeds" 0 "" "--force-with-lease"
  on_main "  and sweeps the hour-old orphaned scratch worktree"
else
  bad "SIGKILL left a scratch worktree to sweep" "none found"
fi

# --- blocked pushes do not move the branch ------------------------------------
fresh
(cd "$WT" && echo more >> feat.txt && g commit -qam "feat 2")
BEFORE=$(g -C "$WT" rev-parse HEAD)
run "git push origin feature"
expect "two commits, behind: blocked by the commit count" 2 "has 2 commits ahead"
untouched "  commit-count block: branch not rebased" "$BEFORE"
run "ALLOW_MULTIPLE_COMMITS=1 git push origin feature"
expect "ALLOW_MULTIPLE_COMMITS=1: rebased and allowed" 0 "" "--force-with-lease"

fresh
BEFORE=$(g -C "$WT" rev-parse HEAD)
run "gh pr create --fill"
expect "gh pr create while behind: blocked, asks for a push" 2 "git push --force-with-lease origin feature"
untouched "  gh pr create: branch not rebased" "$BEFORE"

# --- a branch that merged main in is not flattened into a rebase --------------
fresh
(cd "$WT" && g fetch -q origin && g merge -q --no-edit origin/main)
advance_main "later.txt" "later"
BEFORE=$(g -C "$WT" rev-parse HEAD)
run "ALLOW_MULTIPLE_COMMITS=1 git push origin feature"
expect "merge commits, behind: blocked instead of flattened" 2 "contains merge commits"
untouched "  merge commits: branch untouched" "$BEFORE"

# --- a rebase already in progress is the developer's, not the hook's ----------
fresh
(cd "$WT" && printf 'one\nFEATURE\nthree\n' > f.txt && g commit -qam "feat: f" && g reset -q --soft HEAD~2 && g commit -qm feat)
(cd "$MAIN" && printf 'one\nMAIN\nthree\n' > f.txt && g commit -qam "main: f" && g push -q origin main)
(cd "$WT" && g fetch -q origin && g rebase -q origin/main >/dev/null 2>&1)
GD=$(g -C "$WT" rev-parse --absolute-git-dir)
run "git push origin feature"
expect "rebase in progress: blocked, says how to recover" 2 "git rebase --abort"
if [[ -d "$GD/rebase-merge" ]]; then ok "  the developer's rebase is left in progress (not aborted)"; else bad "  the developer's rebase is left in progress"; fi
g -C "$WT" rebase --abort

# --- an untracked file in the way: the branch does not move --------------------
fresh
advance_main "new.txt" "from main"
echo "mine" > "$WT/new.txt"
BEFORE=$(g -C "$WT" rev-parse HEAD)
run "git push origin feature"
expect "untracked file the rebase would overwrite: blocked" 2 "new.txt"
if [[ "$(cat "$WT/new.txt")" == mine ]]; then ok "  the untracked file is intact"; else bad "  the untracked file is intact"; fi
rm -f "$WT/new.txt"
untouched "  untracked file: branch untouched" "$BEFORE"

# --- the repo's own post-checkout hook does not run in the scratch worktree ----
fresh
mkdir -p "$TMP/repo-hooks"
printf '#!/bin/sh\npwd >> "%s/post-checkout.ran"\n' "$TMP" > "$TMP/repo-hooks/post-checkout"
chmod +x "$TMP/repo-hooks/post-checkout"
g -C "$WT" config core.hooksPath "$TMP/repo-hooks"
run "git push origin feature"
expect "repo post-checkout hook: rebased, says how to run it" 0 "git hook run post-checkout" "--force-with-lease"
if [[ ! -e "$TMP/post-checkout.ran" ]]; then ok "  the hook did not run in the scratch worktree"; else bad "  the hook did not run in the scratch worktree" "ran in: $(cat "$TMP/post-checkout.ran")"; fi
g -C "$WT" config --unset core.hooksPath

echo
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" == "0" ]] || exit 1
exit 0
