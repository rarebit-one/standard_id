#!/bin/bash
# Test harness for hooks/enforce-worktree-bash.sh
#
# Builds a throwaway git repo with a main checkout + a linked worktree, then
# feeds the hook realistic PreToolUse payloads and asserts allow (exit 0) vs
# block (exit 2).
#
# Usage: hooks/tests/enforce-worktree-bash.test.sh
set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/enforce-worktree-bash.sh"
[[ -x "$HOOK" ]] || { echo "hook not executable: $HOOK" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "jq is required to run these tests" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ewb-test.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
# macOS /tmp is a symlink to /private/tmp; canonicalise so path comparisons hold.
TMP="$(cd "$TMP" && pwd -P)" || exit 1
# Cleanup may only ever remove the directory created above (see pre-push-prepare.test.sh).
[[ -d "$TMP" && "$(basename "$TMP")" == ewb-test.* ]] || { echo "refusing: unexpected TMP '$TMP'" >&2; exit 1; }
trap 'rm -rf -- "$TMP"' EXIT

MAIN="$TMP/repo"
mkdir -p "$MAIN"
# -c overrides keep the fixture independent of the developer's global git config
# (commit signing in particular — this is a throwaway repo, not a real commit).
GIT="git -c commit.gpgsign=false -c tag.gpgsign=false -c core.hooksPath=/dev/null"
(
  set -e
  cd "$MAIN"
  $GIT init -q .
  $GIT config user.email test@example.com
  $GIT config user.name Test
  echo hello > file.txt
  $GIT add file.txt
  $GIT commit -qm init
  $GIT worktree add -q "$TMP/wt" -b feature
) || { echo "fixture setup failed" >&2; exit 1; }
WT="$TMP/wt"
SCRATCH="$TMP/scratch"
mkdir -p "$SCRATCH"

PASS=0
FAIL=0

# run <cwd> <command>  -> RUN_CODE (exit code), RUN_STDERR (the hook's message)
#
# The hook's stderr is captured rather than discarded: a hook that exits 2 with
# no explanation is otherwise indistinguishable from one that explains itself,
# and diagnosing a failing case meant re-running it by hand. Globals rather than
# an echoed value because a command substitution would run this in a subshell
# and lose RUN_STDERR.
RUN_CODE=0
RUN_STDERR=""
run() {
  local cwd="$1" cmd="$2" payload err="$TMP/hook-stderr"
  payload=$(jq -n --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
  ( cd "$cwd" && printf '%s' "$payload" | env -u CI -u GITHUB_ACTIONS "$HOOK" >/dev/null 2>"$err" )
  RUN_CODE=$?
  RUN_STDERR="$(cat "$err" 2>/dev/null)"
  rm -f "$err"
}

# report <expect allow|block> <label> <exit code> [cwd] [cmd]
report() {
  local expect="$1" label="$2" code="$3" cwd="${4:-}" cmd="${5:-}" want
  if [[ "$expect" == "allow" ]]; then want=0; else want=2; fi
  if [[ "$code" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok   [%-5s] %s\n' "$expect" "$label"
    return 0
  fi
  FAIL=$((FAIL + 1))
  printf '  FAIL [%-5s] %s (exit %s, wanted %s)\n' "$expect" "$label" "$code" "$want"
  [[ -n "$cwd" ]] && printf '       cwd: %s\n       cmd: %s\n' "$cwd" "$cmd"
  if [[ -n "$RUN_STDERR" ]]; then
    printf '       hook said:\n'
    printf '%s\n' "$RUN_STDERR" | sed 's/^/         /'
  else
    printf '       hook printed nothing to stderr\n'
  fi
}

# check <expect allow|block> <label> <cwd> <command>
check() {
  local expect="$1" label="$2" cwd="$3" cmd="$4"
  run "$cwd" "$cmd"
  report "$expect" "$label" "$RUN_CODE" "$cwd" "$cmd"
}

echo "enforce-worktree-bash.sh"
echo "  main:     $MAIN"
echo "  worktree: $WT"
echo

# --- the two false positives from delivery-ops#328 --------------------------

check allow "issue body merely mentions bin/devcontainer-exec (heredoc)" "$MAIN" \
  'gh issue create --repo fundbright/delivery-ops --title "hook" --body "$(cat <<'"'"'EOF'"'"'
The fix is: bin/devcontainer-exec env RAILS_ENV=test bin/rails db:test:prepare
Also mentions rsync and git apply (see #328) — none of it is executed.
EOF
)"'

check allow "cp of a script whose NAME contains devcontainer-exec, into scratch" "$MAIN" \
  "cp $MAIN/bin/devcontainer-exec-fixed.sh $SCRATCH/"

check allow "commit message mentions rsync" "$MAIN" \
  'git commit -m "document the rsync vector"'

check allow "grep for a trigger word" "$MAIN" \
  'grep -rn "bin/devcontainer-exec" . | head -20'

check allow "echoing a trigger word into /tmp" "$MAIN" \
  "echo 'rsync is the culprit' > $SCRATCH/notes.md"

# --- genuine writes in a main checkout (must stay blocked) ------------------

check block "rsync from the main checkout" "$MAIN" \
  'rsync -a src/ dest/'

check block "bin/devcontainer-exec from the main checkout" "$MAIN" \
  'bin/devcontainer-exec bundle install'

check block "git apply in the main checkout" "$MAIN" \
  'git apply /tmp/fix.diff'

check block "git stash pop in the main checkout" "$MAIN" \
  'git stash pop'

check block "sed -i in the main checkout" "$MAIN" \
  "sed -i '' 's/a/b/' file.txt"

check block "patch in the main checkout" "$MAIN" \
  'patch -p1 < /tmp/fix.diff'

check block "cd into main, then rsync" "$WT" \
  "cd $MAIN && rsync -a $WT/ ."

# --- previously UNDER-blocked gaps ------------------------------------------

check block "git -C <main> stash pop, run from a worktree" "$WT" \
  "git -C $MAIN stash pop"

check block "git -C <main> apply, run from a worktree" "$WT" \
  "git -C $MAIN apply /tmp/fix.diff"

check block "plain redirection into the main checkout" "$MAIN" \
  'echo scribble > notes.txt'

check block "append redirection into the main checkout" "$MAIN" \
  'cat /tmp/x >> file.txt'

check block "append-redirect from a worktree into the main checkout" "$WT" \
  "cat /tmp/x >> $MAIN/file.txt"

check block "tee into the main checkout" "$WT" \
  "echo scribble | tee $MAIN/file.txt"

check block "cp into the main checkout from a worktree" "$WT" \
  "cp file.txt $MAIN/file.txt"

check block "mv into the main checkout from a worktree" "$WT" \
  "mv file.txt $MAIN/moved.txt"

check block "rsync into the main checkout from a worktree" "$WT" \
  "rsync -a ./ $MAIN/"

check block "sed -i on a file inside the main checkout, from a worktree" "$WT" \
  "sed -i.bak 's/a/b/' $MAIN/file.txt"

check block "eval of a blocked command" "$MAIN" \
  'eval "rsync -a src/ dest/"'

check block "bash -c wrapping a blocked command" "$MAIN" \
  "bash -c \"sed -i '' s/a/b/ file.txt\""

check block "command substitution running rsync" "$MAIN" \
  'echo "$(rsync -a src/ dest/)"'

# --- legitimate work must not be blocked ------------------------------------

check allow "rsync inside a worktree" "$WT" \
  'rsync -a src/ dest/'

check allow "sed -i inside a worktree" "$WT" \
  "sed -i '' 's/a/b/' file.txt"

check allow "git stash pop inside a worktree" "$WT" \
  'git stash pop'

check allow "git -C <worktree> stash pop, run from main" "$MAIN" \
  "git -C $WT stash pop"

check allow "redirection to /dev/null from the main checkout" "$MAIN" \
  'git status --porcelain > /dev/null 2>&1'

check allow "redirection to /tmp from the main checkout" "$MAIN" \
  "git log --oneline -20 > $SCRATCH/log.txt"

check allow "pristine restore in the main checkout" "$MAIN" \
  'git checkout HEAD -- . && git clean -fd'

check allow "branch switch + pull in the main checkout" "$MAIN" \
  'git checkout main && git pull --ff-only'

check allow "reading files in the main checkout" "$MAIN" \
  'cat file.txt | wc -l'

check allow "cp OUT of the main checkout into scratch" "$MAIN" \
  "cp file.txt $SCRATCH/file.txt"

check allow "non-git directory is never guarded" "$SCRATCH" \
  'rsync -a a/ b/'

check allow "2>&1 redirection is not a file write" "$MAIN" \
  'ls -la 2>&1 | head'

check allow "here-string is not a write" "$MAIN" \
  'grep foo <<< "rsync"'

check allow "git -C <main> commit (deliberately still allowed)" "$WT" \
  "git -C $MAIN commit -m 'wip'"

check allow "rsync to a REMOTE destination from a worktree" "$WT" \
  'rsync -a ./ mac-mini-1:~/Workspace/x/'

check allow "multi-line chain that only reads" "$MAIN" \
  'git status --porcelain \
  && git log --oneline -5'

check block "build output redirected into main, multi-line" "$WT" \
  "cd $MAIN &&
npm run build > build.log"

check block "subshell hiding an rsync in main" "$WT" \
  "(cd $MAIN && rsync -a $WT/ .)"

# --- a subshell's `cd` must not follow it out ---------------------------------
#
# CURDIR is a global, so before this was handled a `cd` inside `$( … )` / `( … )`
# / `bash -c` left the parent context pointing at the wrong directory, and every
# later relative path was judged against the wrong repo. Real bash never lets a
# child shell move its parent.

check allow "cd inside \$( ) does not move the parent's CWD" "$WT" \
  "OUT=\"\$(cd $MAIN && git log --oneline -1)\"; echo \"\$OUT\" > notes.txt"

check allow "cd inside ( ) does not move the parent's CWD" "$WT" \
  "(cd $MAIN && git status --porcelain); echo done > notes.txt"

check allow "cd inside bash -c does not move the parent's CWD" "$WT" \
  "bash -c \"cd $MAIN && git status\"; echo done > notes.txt"

# …while the write still gets caught when it really is in the child.
check block "a write INSIDE the subshell that cd'd into main is still caught" "$WT" \
  "(cd $MAIN && echo scribble > notes.txt)"

# `eval` is NOT a subshell — its cd genuinely persists, so this must stay blocked.
check block "cd via eval persists into the rest of the command" "$WT" \
  "eval \"cd $MAIN\"; echo scribble > notes.txt"

# --- rsync with no destination writes nothing --------------------------------

check allow "rsync listing a source with no destination is not a write" "$WT" \
  "rsync --dry-run $MAIN/"

check block "rsync WITH a destination in main is still a write" "$WT" \
  "rsync --dry-run ./ $MAIN/"

check allow "sed WITHOUT -i in the main checkout" "$MAIN" \
  "sed -n '1,5p' file.txt"

check allow "gh pr create whose body contains a full command chain" "$MAIN" \
  'gh pr create --body "$(cat <<'"'"'MD'"'"'
Run `cd repo && rsync -a src/ dest/` then `sed -i "" s/a/b/ file.txt`.
MD
)"'

# --- fail-closed behaviour ---------------------------------------------------

check block "unterminated quote in the main checkout (fail closed)" "$MAIN" \
  'echo "oops'

check block "unresolvable ~user cd target then rsync (fail closed)" "$WT" \
  'cd ~someoneelse/repo && rsync -a a/ b/'

check block "unresolvable \$VAR redirection target in main (fail closed)" "$MAIN" \
  'echo hi > "$OUT"'

check allow "unresolvable \$VAR redirection target outside a repo" "$SCRATCH" \
  'echo hi > "$OUT"'

# --- variables assigned earlier in the same command ---------------------------

check block "\$VAR assigned to a scratch dir, then redirected to, from main (rule 4: computed target)" "$MAIN" \
  "SP=$SCRATCH; echo hi > \"\$SP/out.txt\""

check block "\${VAR} assigned on its own line, then tee'd to, from main (rule 4)" "$MAIN" \
  "SP=\"$SCRATCH\"
echo hi | tee \"\${SP}/out.txt\""

check block "export VAR= then cd \$VAR and write there, from main (rule 4: computed cd)" "$MAIN" \
  "export D=$SCRATCH && cd \"\$D\" && echo hi > out.txt"

check block "a value containing \$ is never bound (quoting was lost), from main" "$MAIN" \
  "A=$TMP; B=\$A/scratch; echo hi > \"\$B/out.txt\""

check block "assignment before && then a \$VAR target, from main (rule 4)" "$MAIN" \
  "SP=$SCRATCH && echo hi > \"\$SP/out.txt\""

check block "\$VAR assigned to the main checkout, then redirected to" "$SCRATCH" \
  "D=$MAIN; echo hi > \"\$D/file.txt\""

check block "\$VAR assigned to the main checkout, cd there, then sed -i" "$SCRATCH" \
  "D=$MAIN; cd \$D && sed -i s/a/b/ file.txt"

check block "prefix assignment does not bind for the command's own redirect (main)" "$MAIN" \
  "SP=$SCRATCH echo hi > \"\$SP/out.txt\""

check block "assignment from a command substitution stays unresolvable (main)" "$MAIN" \
  "SP=\$(mktemp -d); echo hi > \"\$SP/out.txt\""

check block "assignment inside a subshell does not leak to the parent (main)" "$MAIN" \
  "( SP=$SCRATCH ); echo hi > \"\$SP/out.txt\""

check block "unknown variable alongside a known one stays unresolvable (main)" "$MAIN" \
  "SP=$SCRATCH; echo hi > \"\$SP/\$NAME\""

# agent-estate#25 review (Codex P1s): each must fail closed.
check block "assignment after && may be skipped: poisons the var (Codex P1)" "$MAIN" \
  "D=$MAIN; false && D=$SCRATCH; echo hi > \"\$D/file.txt\""

check block "assignment after || may be skipped: poisons the var" "$MAIN" \
  "D=$SCRATCH; true || D=$MAIN; echo hi > \"\$D/file.txt\""

check block "assignment inside if/fi may be skipped: poisons the var" "$MAIN" \
  "D=$MAIN
if false; then
  D=$SCRATCH
fi
echo hi > \"\$D/file.txt\""

check block "assignment inside { … } after || poisons the var" "$MAIN" \
  "D=$SCRATCH; false || { D=$MAIN; }; echo hi > \"\$D/file.txt\""

check block "env D=… only sets D for env's child (Codex P1)" "$MAIN" \
  "D=$MAIN; env D=$SCRATCH; echo hi > \"\$D/file.txt\""

check block "pipeline-member assignment does not bind" "$MAIN" \
  "SP=$SCRATCH | true; echo hi > \"\$SP/out.txt\""

check block "escaped \\\$ in a value is literal, not an expansion (Codex P1)" "$MAIN" \
  "D=$SCRATCH; P=\\\$D; echo hi > \"\$P\""

check block "single-quoted \$ in a value is literal, not an expansion" "$MAIN" \
  "D=$SCRATCH; P='\$D'; echo hi > \"\$P\""

# agent-estate#25 second review (Codex P1s) + the generic rule behind the fix:
# any other mention of a bound name poisons it.
check block "assignment inside bash -c does not bind in the parent (Codex P1)" "$MAIN" \
  "D=$MAIN/; bash -c 'D=$SCRATCH/'; echo hi > \"\${D}file.txt\""

check block "prefix assignment before a special builtin persists (Codex P1)" "$MAIN" \
  "D=$SCRATCH/; D=$MAIN/ export D; echo hi > \"\${D}file.txt\""

check block "unset removes the binding (Codex P1)" "$MAIN" \
  "D=$SCRATCH/; unset D; echo hi > \"\${D}file.txt\""

check block "append assignment changes the binding (Codex P1)" "$MAIN" \
  "D=$SCRATCH/; D+=../repo/; echo hi > \"\${D}file.txt\""

check block "read into a bound name poisons it" "$MAIN" \
  "D=$SCRATCH; read -r D < /dev/null; echo hi > \"\$D/file.txt\""

check block "for loop variable poisons a bound name" "$MAIN" \
  "D=$SCRATCH; for D in a; do :; done; echo hi > \"\$D/file.txt\""

check block "eval'd assignment poisons the binding" "$MAIN" \
  "D=$SCRATCH; eval 'D=$MAIN'; echo hi > \"\$D/file.txt\""

check block "declare -n nameref drops every binding" "$MAIN" \
  "D=$SCRATCH; declare -n R=D; R=$MAIN; echo hi > \"\$D/file.txt\""

check block "source drops every binding" "$MAIN" \
  "D=$SCRATCH; . /dev/null; echo hi > \"\$D/file.txt\""

check block "re-assigning a bound name to a scratch literal, from main (rule 4)" "$MAIN" \
  "D=$MAIN; D=$SCRATCH; echo hi > \"\$D/out.txt\""

# agent-estate#25 third review (Codex P1s).
check block "a poisoned name that pointed into main still blocks outside a repo (Codex P1)" "$SCRATCH" \
  "D=$MAIN; echo D; echo hi > \"\$D/file.txt\""

check block "a skipped assignment's main-checkout value blocks outside a repo" "$SCRATCH" \
  "D=$SCRATCH; false || D=$MAIN; echo hi > \"\$D/file.txt\""

check block "bash -c assigning a main path blocks outside a repo" "$SCRATCH" \
  "D=$SCRATCH/; bash -c 'D=$MAIN/'; echo hi > \"\${D}file.txt\""

check block "cd to a DANGER variable, then a relative write, outside a repo" "$SCRATCH" \
  "D=$MAIN; true && D=$SCRATCH; cd \"\$D\" && echo hi > file.txt"

check block "attached option form printf -vD poisons D (Codex P1)" "$MAIN" \
  "D=$SCRATCH/; printf -vD %s $MAIN/; echo hi > \"\${D}file.txt\""

check block "attached option form read -aD poisons D" "$MAIN" \
  "D=$SCRATCH; read -aD < /dev/null; echo hi > \"\$D/file.txt\""

check block "arithmetic ((D=0)) runs in this shell (Codex P1)" "$MAIN" \
  "D=$SCRATCH/; ((D=0)); echo hi > \"\${D}file.txt\""

check block "arithmetic expansion \$((D=0)) runs in this shell" "$MAIN" \
  "D=$SCRATCH/; echo \$((D=0)); echo hi > \"\${D}file.txt\""

check block "a bound name changed by a skipped assignment is DANGER even if both values are outside main" "$SCRATCH" \
  "D=$SCRATCH; true || D=$TMP; echo hi > \"\$D/out.txt\""

# agent-estate#25 fourth review (Codex P1): indirect targets.
check block "printf -v through a bound indirect name (Codex P1)" "$MAIN" \
  "D=$SCRATCH/; N=D; printf -v \"\$N\" %s $MAIN/; echo hi > \"\${D}file.txt\""

check block "read into an unknown indirect name drops every binding" "$MAIN" \
  "D=$SCRATCH; read -r \"\$WHO\" < /dev/null; echo hi > \"\$D/file.txt\""

check block "declare with an expanded target name drops every binding" "$MAIN" \
  "D=$SCRATCH; declare \"\$WHO=$MAIN\"; echo hi > \"\$D/file.txt\""

check block "printf without -v, \$VAR target, from main (rule 4)" "$MAIN" \
  "SP=$SCRATCH; printf '%s' \"\$X\" > \"\$SP/out.txt\""

# agent-estate#25 fifth review (Codex P1): declare options transform values.
check block "declare -u transforms the value, so it is not cached (Codex P1)" "$SCRATCH" \
  "D=$MAIN; declare -u D=$SCRATCH; echo hi > \"\$D/file.txt\""

check block "declare -l from main: the transformed value is unknown" "$MAIN" \
  "declare -l D=$SCRATCH; echo hi > \"\$D/out.txt\""

check block "export NAME=literal, then a \$NAME target, from main (rule 4)" "$MAIN" \
  "export SP=$SCRATCH; echo hi > \"\$SP/out.txt\""

# agent-estate#25 sixth review (Codex P1s).
check block "a value built from a known main-checkout var is DANGER (Codex P1)" "$SCRATCH" \
  "ROOT=$MAIN/; D=\$ROOT; echo hi > \"\${D}file.txt\""

check block "extended expansion of a bound main-checkout var blocks outside a repo (Codex P1)" "$SCRATCH" \
  "D=$MAIN/; echo hi > \"\${D%/}/file.txt\""

check block "extended expansion of a bound scratch var still blocks (it can rewrite the path)" "$SCRATCH" \
  "D=$SCRATCH/; echo hi > \"\${D/scratch/repo}/file.txt\""

check block "a subshell cd does not clear the parent's DIR_DANGER (Codex P1)" "$SCRATCH" \
  "D=$MAIN/; readonly D; cd \"\$D\"; (cd /tmp); echo hi > file.txt"

check allow "a value built from a known scratch var stays allowed outside a repo" "$SCRATCH" \
  "ROOT=$SCRATCH/; D=\$ROOT; echo hi > \"\${D}out.txt\""

# agent-estate#25 seventh review (Codex P1s).
check allow "a relative, non-existent bound value then mentioned does not hang (Codex P1)" "$SCRATCH" \
  "D=does-not-exist; echo D; echo done"

check block "indexed assignment D[0]= gives scalar D a main-checkout value (Codex P1)" "$SCRATCH" \
  "D=$SCRATCH/; D[0]=$MAIN/; echo hi > \"\${D}file.txt\""

check block "assignment inside an array subscript drops every binding" "$MAIN" \
  "D=$SCRATCH; a[D=1]=x; echo hi > \"\$D/file.txt\""

check block "bash -c cd does not clear the parent's DIR_DANGER (Codex P1)" "$SCRATCH" \
  "D=$MAIN/; false && D=/tmp/; cd \"\$D\"; bash -c 'cd /tmp'; echo hi > file.txt"

# agent-estate#25 eighth review (Codex P1s): a bound name changed in a way we
# can't follow is DANGER everywhere; ~ candidates are expanded for the check.
check block "printf -v over a bound scratch var blocks outside a repo (Codex P1)" "$SCRATCH" \
  "D=$SCRATCH/; printf -v D %s $MAIN/; echo hi > \"\${D}file.txt\""

HOME="$TMP" check block "a ~/ value pointing into a main checkout is DANGER (Codex P1)" "$SCRATCH" \
  "D=~/repo/; echo hi > \"\${D}file.txt\""

check allow "an unbound name from a command substitution keeps baseline behaviour outside a repo" "$SCRATCH" \
  "D=\$(mktemp -d); echo hi > \"\$D/out.txt\""

check allow "re-binding a scratch var to another literal is still allowed" "$SCRATCH" \
  "D=$SCRATCH/a; D=$SCRATCH/b; echo hi > \"\$D/out.txt\""

# agent-estate#25 ninth review (Codex P1s): implicit targets and top-level local.
check block "read with no names writes REPLY (Codex P1)" "$MAIN" \
  "REPLY=$SCRATCH/; read <<< $MAIN/; echo hi > \"\${REPLY}file.txt\""

check block "mapfile with no name writes MAPFILE" "$MAIN" \
  "MAPFILE=$SCRATCH/; mapfile < /dev/null; echo hi > \"\${MAPFILE}file.txt\""

check block "top-level local fails and keeps the old value (Codex P1)" "$MAIN" \
  "D=$MAIN/; local D=$SCRATCH/; echo hi > \"\${D}file.txt\""

# agent-estate#25 tenth review (Codex P1): bash-managed variables never bind.
check block "BASH_REMATCH is rewritten by =~ (Codex P1)" "$MAIN" \
  "BASH_REMATCH=$SCRATCH/; [[ $MAIN/ =~ .* ]]; echo hi > \"\${BASH_REMATCH}file.txt\""

check block "PWD is rewritten by cd" "$MAIN" \
  "PWD=$SCRATCH; cd $MAIN; echo hi > \"\$PWD/file.txt\""

# agent-estate#25 eleventh review (Codex).
check block "bash -c does not see the parent's unexported binding (Codex P1; was a regression)" "$MAIN" \
  "D=$SCRATCH/; bash -c 'echo hi > \"\${D}file.txt\"'"

check block "a managed variable assigned a main path is DANGER outside a repo (Codex P1)" "$SCRATCH" \
  "REPLY=$MAIN/; echo hi > \"\${REPLY}file.txt\""

check block "LINES is shell-managed (Codex P2)" "$MAIN" \
  "LINES=$SCRATCH/; echo hi > \"\${LINES}file.txt\""

check block "unbound prefix assignment before export persists: DANGER outside a repo (Codex P1)" "$SCRATCH" \
  "D=$MAIN/ export D; echo hi > \"\${D}file.txt\""

check allow "prefix assignment before an ordinary command stays scoped" "$SCRATCH" \
  "D=$MAIN/ true; echo hi > out.txt"

check block "append to an unbound name before export: DANGER outside a repo (Codex P1)" "$SCRATCH" \
  "unset D; D+=$MAIN/ export D; echo hi > \"\${D}file.txt\""

# fundbright-web#1718 review.
check block "an exported main-checkout binding stays DANGER inside bash -c" "$SCRATCH" \
  "export D=$MAIN; cd /tmp; bash -c 'echo x > \$D/f'"

check block "ls -la \"\$a\", then a \$a target, from main (rule 4)" "$MAIN" \
  "a=$SCRATCH; ls -la \"\$a\"; echo hi > \"\$a/out.txt\""

check block "prefix assignment exported into bash -c stays DANGER" "$SCRATCH" \
  "D=$MAIN bash -c 'echo x > \"\$D/f\"'"

check block "env prefix assignment exported into bash -c stays DANGER" "$SCRATCH" \
  "env D=$MAIN bash -c 'echo x > \"\$D/f\"'"

check block "prefix value built from a known main-checkout var into bash -c" "$SCRATCH" \
  "ROOT=$MAIN; D=\$ROOT bash -c 'echo x > \"\$D/f\"'"

# --- consumer-sync regressions (2026-11-23) and their relatives ---------------
# Each of (a)–(c) was blocked by an older vendored copy and allowed by canonical.
# Rule: when the guard cannot tell what bash will do, the target is unresolved:
# block.

# (a) quoting around a `$`: the lexer dropped quotes, so a literal `$D` was
# expanded. Bash writes a file literally named `$D` into the checkout.
check block "single-quoted '\$D' is a literal name, not D's value (sync a)" "$MAIN" \
  "D=/tmp; printf x > '\$D'"
check block "backslash-escaped \\\$D target is literal" "$MAIN" \
  "D=$SCRATCH; printf x > \\\$D"
check block "escaped \\\$D inside double quotes is literal" "$MAIN" \
  "D=$SCRATCH; printf x > \"\\\$D\""
check block "a literal-\$ path under a main checkout, from a worktree" "$WT" \
  "printf x > '$MAIN/\$D'"
check block "an unresolvable part under a main checkout, from a worktree" "$WT" \
  "printf x > \"$MAIN/\$NAME\""
check block "ANSI-C \$'…' with an escaped quote no longer misparses the redirect" "$WT" \
  "echo \$'\\'' > $MAIN/f.txt"
check block "ANSI-C \$'…' target under a main checkout, from a worktree" "$WT" \
  "printf x > \$'$MAIN/f.txt'"
check block "locale \$\"…\" target under a main checkout, from a worktree" "$WT" \
  "printf x > \$\"$MAIN/f.txt\""
check allow "a literal \$ in the DATA only, scratch destination, from main" "$MAIN" \
  "printf '%s' '\$HOME' > $SCRATCH/out.txt"
check allow "an unresolvable part under scratch, from a worktree" "$WT" \
  "printf x > \"$SCRATCH/\$NAME\""
check block "eval re-parses an escaped \\\$: still caught" "$WT" \
  "D=$MAIN; eval \"printf x > \\\$D/f.txt\""

# (b) assignments bash rejects (readonly / declare -r), eval, and other ways
# the shell stops doing what the guard modelled.
check block "readonly D, then a rebinding bash rejects (sync b)" "$MAIN" \
  "readonly D=$MAIN; export D=$SCRATCH; printf x > \"\$D/probe\""
check block "readonly D, rebinding rejected, run from a worktree" "$WT" \
  "readonly D=$MAIN; export D=$SCRATCH; printf x > \"\$D/probe\""
check block "declare -r D, rebinding rejected, outside a repo" "$SCRATCH" \
  "declare -r D=$MAIN; D=$SCRATCH; printf x > \"\$D/probe\""
check block "typeset -rx D, rebinding rejected" "$SCRATCH" \
  "typeset -rx D=$MAIN; D=$SCRATCH; printf x > \"\$D/probe\""
check block "local -r in a function body" "$SCRATCH" \
  "f() { local -r D=$MAIN; D=$SCRATCH; printf x > \"\$D/probe\"; }; f"
check block "readonly anywhere on the line, from main (fail closed)" "$MAIN" \
  "readonly X=1; echo done"
check block "eval anywhere on the line, from main (fail closed)" "$MAIN" \
  "eval true"
check allow "eval from a worktree with no main checkout in play" "$WT" \
  "eval true; echo hi > out.txt"
check block "set -r makes the later cd fail, from main" "$MAIN" \
  "set -r; cd $SCRATCH; cp $SCRATCH/a.txt b.txt"
check block "a trap command string runs later in this shell" "$WT" \
  "trap \"printf x > $MAIN/f.txt\" EXIT"
# agent-estate#77 review (Codex P1): a trap / alias body runs later, so its cd
# must not move the directory the rest of the line is judged in.
check block "a trap body's cd does not move the outer cwd (Codex P1)" "$WT" \
  "cd $MAIN; trap 'cd $SCRATCH' EXIT; printf x > probe"
check block "an alias body's cd does not move the outer cwd" "$WT" \
  "cd $MAIN; alias x='cd $SCRATCH'; printf x > probe"
check block "a trap body's assignment does not bind for the rest of the line" "$SCRATCH" \
  "D=$MAIN; trap 'D=$SCRATCH' EXIT; printf x > \"\$D/probe\""
check block "an EXIT trap is judged with the line's final cwd" "$WT" \
  "trap 'echo x > probe' EXIT; cd $MAIN/"
check block "an alias can rename a writer, from main" "$MAIN" \
  "alias c='rsync -a'
c src/ dest/"
check block "a function overriding cd makes the cd a no-op" "$MAIN" \
  "cd() { :; }; cd $SCRATCH; cp $SCRATCH/a.txt b.txt"
check block "a function that cds leaves the cwd unknown, from a worktree" "$WT" \
  "f() { cd \"\$1\"; }; f $MAIN; echo hi > out.txt"
check block "a failed cd (missing dir) leaves the shell in main" "$MAIN" \
  "cd $SCRATCH/missing; printf x > out.txt"
check allow "cd to a missing dir guarded by && skips the write" "$MAIN" \
  "cd $SCRATCH/missing && printf x > out.txt"
check allow "mkdir -p, then cd into it, from main" "$MAIN" \
  "mkdir -p $SCRATCH/new; cd $SCRATCH/new; printf x > out.txt"
check block "cd - returns to main" "$MAIN" \
  "cd $SCRATCH; cd -; printf x > out.txt"
check block "popd returns to main" "$MAIN" \
  "pushd $SCRATCH; popd; printf x > out.txt"
check block "CDPATH sends a relative cd into main, from outside a repo" "$SCRATCH" \
  "CDPATH=$TMP; cd repo; printf x > out.txt"

# (c) default assignments ${D:=…} / ${D=…}, and their relatives.
check block "\${D:=…} assigns D (sync c)" "$MAIN" \
  "D=; : \"\${D:=$MAIN}\"; printf x > \"\$D/probe\""
check block "\${D:=…} assigning a main path, outside a repo" "$SCRATCH" \
  "D=; : \"\${D:=$MAIN}\"; printf x > \"\$D/probe\""
check block "\${D=…} assigns an unset D" "$SCRATCH" \
  ": \${D=$MAIN}; printf x > \"\$D/probe\""
check block "\${D:=…} in a here-string assigns D" "$SCRATCH" \
  "cat <<< \"\${D:=$MAIN}\"; printf x > \"\$D/f.txt\""
check block "\${D:=…} in an unquoted heredoc body assigns D" "$SCRATCH" \
  "cat <<EOF
\${D:=$MAIN}
EOF
printf x > \"\$D/f.txt\""
check block "\${D:-main} default is a main path, from a worktree" "$WT" \
  "printf x > \"\${D:-$MAIN}/probe\""
check block "\${D:+main} alternative is a main path, from a worktree" "$WT" \
  "printf x > \"\${D:+$MAIN}/probe\""
check block "nested defaults ending in a main path" "$WT" \
  "printf x > \"\${A:-\${B:-$MAIN}}/probe\""
check block "a value with a main default makes the variable DANGER" "$WT" \
  "D=\${X:-$MAIN}; printf x > \"\$D/probe\""
check block "cd to a main default, then a relative write" "$WT" \
  "cd \"\${D:-$MAIN}\"; printf x > out.txt"
check allow "\${D:-scratch} default, from a worktree" "$WT" \
  "printf x > \"\${D:-$SCRATCH}/out.txt\""
check block "set -- main, then \$1" "$WT" \
  "set -- $MAIN; printf x > \"\$1/f.txt\""
check block "printf -v into an unbound name, main value" "$WT" \
  "printf -v D %s $MAIN; printf x > \"\$D/f.txt\""
check block "printf -v building a main path from parts" "$WT" \
  "printf -v D '%s/%s' $TMP repo; printf x > \"\$D/f.txt\""
check block "for loop leaves its variable at a main path" "$WT" \
  "for D in $MAIN; do :; done; printf x > \"\$D/f.txt\""
check block "read from a here-string into an unbound name" "$WT" \
  "read -r D <<< $MAIN; printf x > \"\$D/f.txt\""

# Lexer gaps found alongside: `>& word` is a FILE unless word is an fd, and a
# redirection with no command word still creates/truncates its target.
check block ">& FILE writes stdout+stderr to a file in main, from a worktree" "$WT" \
  "echo x >& $MAIN/f.txt"
check block "a bare redirection with no command truncates a main file" "$WT" \
  "> $MAIN/f.txt"
check allow ">&2 and 2>&1 stay fd duplications" "$MAIN" \
  "ls 2>&1 >&2; echo hi >&-"
check block "cd - with no earlier cd on the line: unknown directory" "$WT" \
  "cd -; echo hi > out.txt"

# --- rule 4: from a main checkout, a computed write destination blocks ------
# (2026-11-23, approved). Tracking variable values kept leaking (Codex rounds on
# agent-estate#77), so from a main checkout any destination bash computes blocks,
# whatever value the guard thinks it has. Literal paths resolve as before;
# worktrees and other directories keep the tracking rules above.

# The #77 bypasses, each run from main.
check block "unquoted word splitting turns \$D into src + a main dest (#77)" "$MAIN" \
  "D=\"$SCRATCH/a.txt file.txt\"; cp \$D"
check block "unquoted word splitting into tee (#77)" "$MAIN" \
  "D=\"$SCRATCH/out.txt file.txt\"; echo x | tee \$D"
check block "declare -x attribute, then a \$D target (#77)" "$MAIN" \
  "declare -x D=$SCRATCH; printf x > \"\$D/probe\""
check block "typeset -i attribute, then a \$D target (#77)" "$MAIN" \
  "typeset -i D=1; printf x > \"$SCRATCH/\$D\""
check block "a quoted assignment word is a command, not an assignment (#77)" "$MAIN" \
  "D=$MAIN; 'D=$SCRATCH'; printf x > \"\$D/probe\""
check block "a quoted name in an assignment word (#77)" "$MAIN" \
  "D=$MAIN; \"D\"=$SCRATCH; printf x > \"\$D/probe\""
check block "a user binding of __literal_dollar__ (#77)" "$MAIN" \
  "__literal_dollar__=$SCRATCH/; printf x > '\$D'"
check block "undecodable ANSI-C \$'\\x..' target (#77)" "$MAIN" \
  "printf x > \$'\\x66ile.txt'"
check block "ANSI-C quoting inside an assignment (#77)" "$MAIN" \
  "D=\$'$SCRATCH'; printf x > \"\$D/probe\""

# Every kind of expansion, from main, into an otherwise-outside path.
check block "\$HOME is not special-cased, from main" "$MAIN" \
  "printf x > \"\$HOME/.cache/out.txt\""
check block "\$TMPDIR is not special-cased, from main" "$MAIN" \
  "printf x > \"\$TMPDIR/out.txt\""
check block "command substitution, from main" "$MAIN" \
  "printf x > \"\$(mktemp -d)/out.txt\""
check block "arithmetic expansion, from main" "$MAIN" \
  "printf x > $SCRATCH/\$((1 + 1)).txt"
check block "brace expansion, from main" "$MAIN" \
  "echo x | tee $SCRATCH/{a,b}.txt"
check block "a glob that can climb back into main, from main" "$MAIN" \
  "cp $SCRATCH/a.txt $SCRATCH/*/../../repo/"
check block "~user, from main" "$MAIN" \
  "printf x > ~root/out.txt"
check block "~+ (the cwd), from main" "$MAIN" \
  "printf x > ~+/out.txt"
check block "started in main, cd'd out literally, computed target" "$MAIN" \
  "cd $SCRATCH && printf x > \"\$X/out.txt\""
check block "cd into main from a worktree, computed target" "$WT" \
  "cd $MAIN && printf x > \"$SCRATCH/\$X\""
check block "cd to a computed dir, then rsync, from main" "$MAIN" \
  "D=$SCRATCH; cd \"\$D\" && rsync -a a/ b/"

# Literal destinations from main stay allowed.
check allow "a literal outside path, from main" "$MAIN" \
  "printf x > $SCRATCH/out.txt"
HOME="$SCRATCH" check allow "a plain ~/ prefix, from main" "$MAIN" \
  "printf x > ~/out.txt; echo y | tee -a ~/out.txt"
HOME="$SCRATCH" check allow "\$VAR in the data only, ~/ destination, from main" "$MAIN" \
  "echo \"\$X \$(date)\" > ~/out.txt"
check allow "a computed source, literal destination, from main" "$MAIN" \
  "cp \"\$SRC\" $SCRATCH/copy.txt"
check allow "a computed git -C for a read-only subcommand, from main" "$MAIN" \
  "D=$WT; git -C \"\$D\" status"

# HOME changes on the line: ~ is no longer literal.
HOME="$SCRATCH" check block "HOME assigned, then ~/, from main" "$MAIN" \
  "HOME=$SCRATCH; printf x > ~/out.txt"
HOME="$SCRATCH" check block "HOME assigned later in a loop, ~/ earlier, from main" "$MAIN" \
  "for i in 1 2; do printf x > ~/out.txt; HOME=$MAIN; done"
HOME="$SCRATCH" check block "HOME changed later in a loop, write relative to cd ~, from main" "$MAIN" \
  "for i in 1 2; do cd ~ && printf x > out.txt; HOME=$MAIN; done"
HOME="$SCRATCH" check allow "cd ~ and git -C ~ status with HOME changed, no write, from main (Codex P2)" "$MAIN" \
  "HOME=/tmp; cd ~; pwd; git -C ~ status; echo HOME"
HOME="$SCRATCH" check block "HOME set through an indirect printf -v, from main" "$MAIN" \
  "N=HO; printf -v \"\${N}ME\" %s $MAIN; printf x > ~/f.txt"
HOME="$SCRATCH" check block "HOME bound to main, then ~/, from a worktree" "$WT" \
  "HOME=$MAIN; printf x > ~/f.txt"
check block "a name that starts with HOME is its own variable, from a worktree" "$WT" \
  "HOMEDIR=$MAIN; printf x > \"\$HOMEDIR/f.txt\""
HOME="$SCRATCH" check block "a bare cd goes to a HOME bound to main, from a worktree" "$WT" \
  "HOME=$MAIN; cd; printf x > f.txt"
HOME="$SCRATCH" check allow "a bare cd goes home, then a relative write, from main" "$MAIN" \
  "cd && printf x > out.txt"
check block "printf -v through an unbound indirect name, from a worktree" "$WT" \
  "N=D; printf -v \"\$N\" %s $MAIN; printf x > \"\$D/f.txt\""

# Writers that only the computed-target rule judges.
check block "touch a computed path, from main" "$MAIN" \
  "touch \"\$D/new.txt\""
check block "mkdir -p a computed path, from main" "$MAIN" \
  "mkdir -p \"\$D/sub\""
check block "dd of= a computed path, from main" "$MAIN" \
  "dd if=/dev/zero of=\"\$D/blob\" count=1"
check block "ln -s to a computed link path, from main" "$MAIN" \
  "ln -s $SCRATCH/a.txt \"\$D/link\""
check block "git -C a computed dir, apply, from main" "$MAIN" \
  "D=$WT; git -C \"\$D\" apply /tmp/fix.diff"
check block "touch: any computed argument blocks from main, option values too (accepted FP)" "$MAIN" \
  "touch --reference \"\$REF\" $SCRATCH/t.txt"
check block "touch under POSIXLY_CORRECT: -r after an operand is a file (Codex P2)" "$MAIN" \
  "export POSIXLY_CORRECT=1; D=out; touch first -r \"\$D\""
check block "touch --ref abbreviation: computed value blocks (accepted FP)" "$MAIN" \
  "touch --ref \"\$REF\" $SCRATCH/t.txt"
check allow "touch with literal option values, from main" "$MAIN" \
  "touch -r $SCRATCH/t.txt --date 2020-01-01 $SCRATCH/u.txt"
check block "touch -rFILE takes an attached value: the next word is a target (Codex P2)" "$MAIN" \
  "D=file.txt; touch -rstart \"\$D\""
check block "mkdir: a computed mode blocks from main too (accepted FP)" "$MAIN" \
  "mkdir -m \"\$MODE\" $SCRATCH/m3"
check block "mkdir under POSIXLY_CORRECT: -m after an operand is a dir (Codex P2)" "$MAIN" \
  "export POSIXLY_CORRECT=1; D=sub; mkdir firstdir -m \"\$D\""
check allow "mkdir with a literal mode, from main" "$MAIN" \
  "mkdir -pm 755 $SCRATCH/m4; mkdir --mode=700 $SCRATCH/m5"
check block "mkdir -m755 takes an attached value: the next word is a target" "$MAIN" \
  "mkdir -m755 \"\$D\""
check block "touch -- ends options: -r is a file and \$D a target (Codex P2)" "$MAIN" \
  "D=file.txt; touch -- -r \"\$D\""
check block "mkdir -- ends options: -m is a dir and \$D a target (Codex P2)" "$MAIN" \
  "D=subdir; mkdir -- -m \"\$D\""
HOME="$SCRATCH" check allow "an absolute cd after cd ~ ends the ~ dependency (Codex P2)" "$MAIN" \
  "HOME=/tmp; cd ~; cd $SCRATCH; printf x > out.txt"
HOME="$SCRATCH" check block "a subshell cd does not end the outer ~ dependency" "$MAIN" \
  "for i in 1 2; do cd ~; (cd /tmp); printf x > out.txt; HOME=$MAIN; done"
HOME="$SCRATCH" check block "cd - back to a cd ~ directory keeps the ~ dependency (Codex P2)" "$MAIN" \
  "for i in 1 2; do cd; cd /tmp; cd -; printf x > out.txt; HOME=$MAIN; done"
HOME="$SCRATCH" check block "popd back to a cd ~ directory keeps the ~ dependency" "$MAIN" \
  "for i in 1 2; do cd ~; pushd /tmp; popd; printf x > out.txt; HOME=$MAIN; done"
HOME="$TMP" check block "a quoted 'HOME=…' is a command: ~ keeps the inherited HOME, from a worktree (Codex P1)" "$WT" \
  "'HOME=$SCRATCH'; printf x > ~/repo/probe"
HOME="$SCRATCH" check allow "git -C an absolute worktree after cd ~ does not depend on HOME (Codex P2)" "$MAIN" \
  "HOME=$SCRATCH; cd ~; git -C $WT apply /tmp/change.patch"
HOME="$SCRATCH" check block "a failed absolute cd keeps the ~ dependency (Codex P1)" "$MAIN" \
  "for i in 1 2; do cd; cd $SCRATCH/missing; printf x > probe; HOME=$MAIN; done"
HOME="$TMP" check block "after source, ~/<main> still blocks from a worktree (Codex P1)" "$WT" \
  "source /dev/null; printf x > ~/repo/file.txt"
HOME="$TMP" check block "after arithmetic, ~/<main> still blocks from a worktree (Codex P1)" "$WT" \
  ": \$((1+1)); printf x > ~/repo/file.txt"
check allow "touch / mkdir of literal paths, from main (unchanged)" "$MAIN" \
  "touch $SCRATCH/t.txt; mkdir -p $SCRATCH/m; touch -d 2020-01-01 $SCRATCH/t.txt"

# Worktree and outside contexts are unchanged: computed targets still resolve.
check allow "\$VAR to scratch, from a worktree" "$WT" \
  "SP=$SCRATCH; echo hi > \"\$SP/out.txt\""
HOME="$SCRATCH" check allow "\$HOME target, from a worktree" "$WT" \
  "printf x > \"\$HOME/out.txt\""
check allow "touch / mkdir / dd computed paths, from a worktree" "$WT" \
  "touch \"\$D/x\"; mkdir -p \"\$D\"; dd if=/dev/zero of=\"\$D/b\" count=1"
check allow "re-binding a main var to a scratch literal, outside a repo" "$SCRATCH" \
  "D=$MAIN; D=$SCRATCH; echo hi > \"\$D/out.txt\""

# --- jq-missing degraded mode ------------------------------------------------

degraded() { # $1 cwd, $2 command -> RUN_CODE / RUN_STDERR (as `run`)
  local payload err="$TMP/hook-stderr"
  payload=$(jq -n --arg c "$2" '{tool_name:"Bash", tool_input:{command:$c}}')
  local stub="$TMP/nojq"
  mkdir -p "$stub"
  ( cd "$1" && printf '%s' "$payload" \
      | env -u CI -u GITHUB_ACTIONS PATH="$stub:/usr/bin:/bin" "$HOOK" >/dev/null 2>"$err" )
  RUN_CODE=$?
  RUN_STDERR="$(cat "$err" 2>/dev/null)"
  rm -f "$err"
}

degraded "$MAIN" 'rsync -a src/ dest/'
report block "jq missing -> fails CLOSED on a trigger in main" "$RUN_CODE"

degraded "$MAIN" 'brew install jq'
report allow "jq missing -> 'brew install jq' still allowed (no deadlock)" "$RUN_CODE"

# --- review findings on the estate rollout (2026-09-25) -----------------------
# -t / --target-directory name the destination explicitly; the last argument is
# then a SOURCE, so judging it instead let a copy into main through.

check block "cp -t MAIN (target flag) from scratch" "$SCRATCH" \
  "cp -t $MAIN $SCRATCH/a.txt"
check block "cp --target-directory=MAIN" "$SCRATCH" \
  "cp --target-directory=$MAIN $SCRATCH/a.txt"
check block "mv -vt MAIN (clustered short flags)" "$SCRATCH" \
  "mv -vt $MAIN $SCRATCH/a.txt"
check block "install --target-directory MAIN (separate arg)" "$SCRATCH" \
  "install --target-directory $MAIN $SCRATCH/a.txt"
check allow "cp -t SCRATCH of a main file (reading main is fine)" "$MAIN" \
  "cp -t $SCRATCH $MAIN/file.txt"

# A destination built from a command substitution can't be resolved statically;
# it used to collapse to an empty string and skip the check entirely.

check block "redirect to \$(pwd)/file in main" "$MAIN" \
  'echo x > "$(pwd)/file.txt"'
check block "redirect to \$(git rev-parse --show-toplevel)/new in main" "$MAIN" \
  'echo x > $(git rev-parse --show-toplevel)/new.txt'
check block "tee to a backtick-built path in main" "$MAIN" \
  'echo x | tee `pwd`/file.txt'
check allow "same substitution-built write from a worktree" "$WT" \
  'echo x > $(git rev-parse --show-toplevel)/new.txt'
check allow "substitution only in the DATA, literal destination in scratch" "$MAIN" \
  "echo \"\$(date)\" > $SCRATCH/log.txt"

# The host:path and fd-number exemptions belong to rsync and redirections only.

check block "tee to a local file whose name has a colon, in main" "$MAIN" \
  'echo x | tee notes:draft.txt'
check block "cp to an all-digits relative filename in main" "$MAIN" \
  "cp $SCRATCH/a.txt 2024"
check allow "rsync from a worktree to a remote host:path" "$WT" \
  'rsync -a ./ backup-host:/srv/copy/'
check allow "stderr redirect to an fd in main" "$MAIN" \
  'ls 2>&1 >/dev/null; echo hi >&2'

# An UNQUOTED heredoc body expands $(…) and `…` when the command runs, so those
# substitutions execute; a quoted delimiter (<<'EOF') keeps the body literal.
check block "unquoted heredoc body runs \$(cp … main) (round 2)" "$SCRATCH" \
  "cat <<EOF
\$(cp $SCRATCH/a.txt $MAIN/injected.txt)
EOF"
check block "unquoted heredoc body with a backtick write into main" "$SCRATCH" \
  "cat <<EOF
\`echo x > $MAIN/injected.txt\`
EOF"
check allow "QUOTED heredoc body mentioning \$(cp … main) is literal" "$SCRATCH" \
  "cat <<'EOF'
\$(cp $SCRATCH/a.txt $MAIN/injected.txt)
EOF"
check allow "escaped \\\$(…) in an unquoted heredoc does not run" "$SCRATCH" \
  "cat <<EOF
\\\$(cp $SCRATCH/a.txt $MAIN/injected.txt)
EOF"
check allow "unquoted heredoc with a harmless substitution" "$SCRATCH" \
  "cat <<EOF > $SCRATCH/out.txt
built \$(date) in \$(pwd)
EOF"

# --- an unresolvable cd makes the directory unknown (2026-11-23) ----------------
# A cd / pushd / popd whose target is empty, an option only, an unknown option,
# a glob, too many words, or built from any expansion leaves the working
# directory UNRESOLVED: relative writes and in-place commands after it block
# wherever the line runs. A cd target is never resolved from the line's own
# bindings. These are the four e23f613 regressions Codex found, and relatives.
mkdir -p "$TMP/REPO" 2>/dev/null

# 1. cd "" was read as a bare cd (to HOME). bash refuses it and stays put.
check block "cd \"\" then a relative write, from main (e23f613 regression)" "$MAIN" \
  'cd ""; printf x > out.txt'
check block "cd '' then a relative write, from main" "$MAIN" \
  "cd ''; printf x > out.txt"
check block "cd \"\" then a relative write, from a worktree" "$WT" \
  'cd ""; printf x > out.txt'
HOME="$SCRATCH" check block "cd -- \"\" then a relative write, from main" "$MAIN" \
  'cd -- ""; printf x > out.txt'

# 2. An option-only or unknown-option cd was read as a bare cd too.
check block "cd -q (unknown option) then a relative write, from main (e23f613 regression)" "$MAIN" \
  'cd -q; printf x > victim'
check block "cd -q DIR (unknown option: cd fails) then a relative write, from main" "$MAIN" \
  "cd -q $SCRATCH; printf x > out.txt"
check block "cd --bogus DIR then a relative write, from main" "$MAIN" \
  "cd --bogus $SCRATCH; printf x > out.txt"
HOME="$SCRATCH" check block "cd -L (option only) then a relative write, from main" "$MAIN" \
  'cd -L; printf x > out.txt'
HOME="$SCRATCH" check block "cd -- (option only) then a relative write, from main" "$MAIN" \
  'cd --; printf x > out.txt'
check block "cd -q then a relative write, from a worktree" "$WT" \
  'cd -q; printf x > victim'
check block "cd with two directories (bash refuses) then a relative write, from main" "$MAIN" \
  "cd $SCRATCH $WT; printf x > out.txt"
check block "pushd -q DIR (unknown option) then a relative write, from main" "$MAIN" \
  "pushd -q $SCRATCH; printf x > out.txt"
check block "pushd -n DIR does not change directory, from main" "$MAIN" \
  "pushd -n $SCRATCH; printf x > out.txt"
check block "popd with an unknown option then a relative write, from main" "$MAIN" \
  "pushd $SCRATCH; popd -q; printf x > out.txt"
check block "popd with a stray argument then a relative write, from a worktree" "$WT" \
  "cd $MAIN; pushd $SCRATCH; popd $WT; printf x > out.txt"

# Glob- and brace-bearing targets stay unresolved.
check block "cd to a glob then a relative write, from main" "$MAIN" \
  "cd $TMP/scr*; printf x > out.txt"
check block "cd to a glob then a relative write, from a worktree" "$WT" \
  "cd $TMP/re?o; printf x > out.txt"
check block "cd to a brace expansion then sed -i, from a worktree" "$WT" \
  "cd $TMP/{repo,x}; sed -i s/a/b/ file.txt"

# 3. declare -l / -u / typeset / local attributes transform the value bash stores.
check block "declare -l then cd \"\$D\" and sed -i, from a worktree (e23f613 regression)" "$WT" \
  "declare -l D; D=$TMP/REPO; cd \"\$D\"; sed -i s/x/y/ file.txt"
check block "typeset -l then cd \"\$D\" and a relative write, from a worktree" "$WT" \
  "typeset -l D; D=$TMP/REPO; cd \"\$D\"; printf x > file.txt"
check block "declare -l then a write through \$D, from a worktree" "$WT" \
  "declare -l D; D=$TMP/REPO; printf x > \"\$D/file.txt\""
check block "declare -l D=value then a write through \$D, from a worktree" "$WT" \
  "declare -l D=$TMP/REPO; printf x > \"\$D/file.txt\""
check block "declare -lx D=value then a write through \$D, from outside a repo" "$SCRATCH" \
  "declare -lx D=$TMP/REPO; printf x > \"\$D/file.txt\""

# 4. A quoted "D=…" word is a command name, not an assignment: D keeps its value.
check block "quoted D=… does not re-bind, then cd \"\$D\" and sed -i, from a worktree (e23f613 regression)" "$WT" \
  "D=$MAIN; \"D=$SCRATCH\"; cd \"\$D\"; sed -i s/old/new/ file.txt"
check block "single-quoted D=… does not re-bind, then a write through \$D, from a worktree" "$WT" \
  "D=$MAIN; 'D=/tmp'; printf x > \"\$D/probe\""
check block "D\\=… (escaped =) does not re-bind, then a write through \$D, from a worktree" "$WT" \
  "D=$MAIN; D\\=/tmp; printf x > \"\$D/probe\""
check block "\"D\"=… does not re-bind, then a write through \$D, from outside a repo" "$SCRATCH" \
  "D=$MAIN; \"D\"=/tmp; printf x > \"\$D/probe\""

# Never resolve a cd target from the line's bindings.
check block "cd to a bound scratch var then a relative write, from a worktree" "$WT" \
  "D=$SCRATCH; cd \"\$D\"; printf x > out.txt"
check block "cd to an unknown var then a relative write, from a worktree" "$WT" \
  'cd "$D"; printf x > out.txt'
check block "cd \$(…) then a relative write, from a worktree" "$WT" \
  'cd "$(git rev-parse --show-toplevel)/.."; printf x > out.txt'
check block "a relative cd after an unresolved cd stays unresolved" "$WT" \
  'cd "$D"; cd ..; printf x > out.txt'
check block "cd - back to an unresolved directory stays unresolved" "$WT" \
  'cd "$D"; cd /tmp; cd -; printf x > out.txt'
check block "popd back to an unresolved directory stays unresolved" "$WT" \
  'cd "$D"; pushd /tmp; popd; printf x > out.txt'
check block "cd - after a failed cd returns to main, not the last good dir" "$MAIN" \
  "cd $SCRATCH; cd $SCRATCH/missing; cd -; printf x > out.txt"
check block "unresolved cd then git apply, from a worktree" "$WT" \
  'cd "$D" && git apply /tmp/change.patch'
check block "unresolved cd then tee to a relative file, from outside a repo" "$SCRATCH" \
  'cd "$D"; echo x | tee out.txt'

# A cd that may not run may leave the shell where it was; one in a child shell
# does not move this shell at all.
check block "false && cd DIR; then a relative write, from main" "$MAIN" \
  "false && cd $SCRATCH; printf x > out.txt"
check block "cd DIR inside if … fi, then a relative write, from main" "$MAIN" \
  "if false; then cd $SCRATCH; fi; printf x > out.txt"
check block "cd DIR inside a for loop, then sed -i, from main" "$MAIN" \
  "for i in; do cd $SCRATCH; done; sed -i s/a/b/ file.txt"
check block "cd DIR in a pipeline does not move this shell, from main" "$MAIN" \
  "cd $SCRATCH | cat; printf x > out.txt"
check block "cd DIR in a background job does not move this shell, from main" "$MAIN" \
  "cd $SCRATCH & printf x > out.txt"
check block "a conditional cd from an unresolved directory stays unresolved" "$WT" \
  "cd \"\$D\"; true && cd $SCRATCH; printf x > out.txt"
check allow "test -d DIR && cd DIR && a relative write, from main" "$MAIN" \
  "test -d $SCRATCH && cd $SCRATCH && printf x > out.txt"
check allow "cd DIR after a closed if … fi, then a relative write, from main" "$MAIN" \
  "if true; then echo ok; fi; cd $SCRATCH; printf x > out.txt"
check allow "cd DIR || exit, then a relative write, from main" "$MAIN" \
  "cd $SCRATCH || exit 1; printf x > out.txt"
check allow "cd DIR inside a { … } group, then a relative write, from main" "$MAIN" \
  "{ cd $SCRATCH; printf x > out.txt; }"
check block "false && { cd DIR; }; then a relative write, from main" "$MAIN" \
  "false && { cd $SCRATCH; }; printf x > out.txt"
check block "cd DIR inside case, then a relative write, from main" "$MAIN" \
  "case x in y) cd $SCRATCH;; esac; printf x > out.txt"
check allow "cd DIR after a closed case, then a relative write, from main" "$MAIN" \
  "case x in y) echo;; esac; cd $SCRATCH; printf x > out.txt"

# cd - follows $OLDPWD and popd ${DIRSTACK[1]}; an external or opaque cd.
check block "OLDPWD assigned to main, then cd -, from a worktree" "$WT" \
  "cd /tmp; OLDPWD=$MAIN; cd -; printf x > out.txt"
check block "DIRSTACK edited to main, then popd, from a worktree" "$WT" \
  "pushd /tmp; DIRSTACK[1]=$MAIN; popd; printf x > out.txt"
check block "sudo cd DIR does not move this shell, from main" "$MAIN" \
  "sudo cd $SCRATCH; printf x > out.txt"
check block "env cd DIR does not move this shell, from main" "$MAIN" \
  "env cd $SCRATCH; printf x > out.txt"
check block "a command named by \$X may be cd, from a worktree" "$WT" \
  "X=cd; \$X $MAIN; printf x > out.txt"
check block "a sourced file may cd, from a worktree" "$WT" \
  ". /dev/null; printf x > out.txt"
check allow "builtin cd DIR moves this shell, from main" "$MAIN" \
  "builtin cd $SCRATCH; printf x > out.txt"
check allow "a command named by \$X in a pipeline, from a worktree" "$WT" \
  "\$X --version | cat; printf x > out.txt"

# Codex round 1 on #81.
check block "env \"D=…\" still runs the command after it (sed -i), from main" "$MAIN" \
  'env "D=/tmp" sed -i s/a/b/ file.txt'
check block "sudo 'D=…' still runs the command after it (rsync), from main" "$MAIN" \
  "sudo 'D=/tmp' rsync -a a/ b/"
check block "with lastpipe, the last pipeline member's cd moves this shell" "$SCRATCH" \
  "shopt -s lastpipe; true | cd $MAIN; printf x > file.txt"
# BASHOPTS is read-only in this shell: hand it to the hook through env.
( cd "$SCRATCH" && jq -n --arg c "true | cd $MAIN; printf x > file.txt" '{tool_name:"Bash", tool_input:{command:$c}}' \
    | env -u CI -u GITHUB_ACTIONS BASHOPTS=lastpipe "$HOOK" >/dev/null 2>&1 )
RUN_CODE=$?; RUN_STDERR=""
report block "lastpipe inherited through BASHOPTS" "$RUN_CODE"
check block "a cd at the end of a pipeline may move this shell (lastpipe): unknown" "$SCRATCH" \
  "true | cd $MAIN; printf x > file.txt"

# A compound command in a pipeline or background job runs in a child shell.
check block "{ cd DIR; } | cat does not move this shell, from main" "$MAIN" \
  "{ cd $SCRATCH; } | cat; printf x > out.txt"
check block "a while loop's cd, piped, does not move this shell, from main" "$MAIN" \
  "while true; do cd $SCRATCH; break; done | cat; printf x > out.txt"
check block "echo | { true; cd DIR; } does not move this shell, from main" "$MAIN" \
  "echo | { true; cd $SCRATCH; }; printf x > out.txt"
check block "{ cd DIR; } & does not move this shell, from main" "$MAIN" \
  "{ cd $SCRATCH; } & printf x > out.txt"
check block "true | { cd MAIN; write; }: the group's cd applies inside it (Codex round 2)" "$SCRATCH" \
  "true | { cd $MAIN; printf x > file.txt; }"
check block "{ cd MAIN; write; } | cat: the group's cd applies inside it" "$SCRATCH" \
  "{ cd $MAIN; printf x > file.txt; } | cat"
check block "true | while …; do cd MAIN; write; done" "$SCRATCH" \
  "true | while true; do cd $MAIN; printf x > file.txt; break; done"
check block "true | { D=MAIN; write through \$D; }: the group's binding applies inside it" "$WT" \
  "true | { D=$MAIN; printf x > \"\$D/file.txt\"; }"
check block "true | { if …; then cd MAIN; fi; write; } (Codex round 3)" "$SCRATCH" \
  "true | { if true; then cd $MAIN; fi; printf x > file.txt; }"
check block "true | { for …; do cd MAIN; done; write; }" "$SCRATCH" \
  "true | { for i in 1; do cd $MAIN; done; printf x > file.txt; }"
check block "true | if …; then { cd MAIN; }; write; fi" "$SCRATCH" \
  "true | if true; then { cd $MAIN; }; printf x > file.txt; fi"
check block "{ cd SCRATCH; } | cat: a piped compound's cd leaves the directory unknown" "$WT" \
  "{ cd $SCRATCH; } | cat; printf x > out.txt"
check block "a piped group's binding does not outlive it" "$WT" \
  "D=$MAIN; { D=$SCRATCH; } | cat; printf x > \"\$D/file.txt\""
check allow "a piped compound with no cd leaves the directory known, from a worktree" "$WT" \
  "{ echo a; echo b; } | sort; printf x > out.txt"

check block "/usr/bin/cd DIR is a program and does not move this shell, from main" "$MAIN" \
  "/usr/bin/cd $SCRATCH; printf x > out.txt"
check block "a DEBUG trap that cds may move the shell before a write, from a worktree" "$WT" \
  "trap 'cd $MAIN' DEBUG; printf x > out.txt"
check block "dirs -c empties the stack, so popd fails and stays put, from a worktree" "$WT" \
  "pushd $MAIN; dirs -c; popd; printf x > out.txt"
check allow "a trap with no cd leaves the directory known, from a worktree" "$WT" \
  "trap 'rm -f /tmp/x' EXIT; printf x > out.txt"
check allow "a trap whose cd is only in a subshell, from a worktree (Codex round 4)" "$WT" \
  "trap '(cd /tmp)' DEBUG; printf x > out.txt"
check allow "a trap whose cd is only in bash -c, from a worktree" "$WT" \
  "trap 'bash -c \"cd /tmp\"' DEBUG; printf x > out.txt"
check block "a trap whose cd follows a subshell still cds, from a worktree" "$WT" \
  "trap '(cd /tmp); cd $MAIN' DEBUG; printf x > out.txt"

# Codex round 5 on #81, and relatives.
check block "true | (cd MAIN; write): a subshell's first cd applies inside it" "$WT" \
  "true | (cd $MAIN; printf x > file.txt)"
check block "true | bash -c 'cd MAIN; write'" "$WT" \
  "true | bash -c 'cd $MAIN; printf x > file.txt'"
check block "true | eval 'cd MAIN; write'" "$WT" \
  "true | eval 'cd $MAIN; printf x > file.txt'"
check block "a piped eval's cd does not outlive it, from main" "$MAIN" \
  "true | eval 'cd $SCRATCH'; printf x > out.txt"
check block "false && eval 'true; cd DIR'; a relative write, from main" "$MAIN" \
  "false && eval 'true; cd $SCRATCH'; printf x > out.txt"
check block "false && { true; cd DIR; }; a relative write, from main" "$MAIN" \
  "false && { true; cd $SCRATCH; }; printf x > out.txt"
check block "false && (true; cd MAIN; write)" "$WT" \
  "false && (true; cd $MAIN; printf x > file.txt)"
check allow "an EXIT-only trap that cds does not move the shell mid-line, from a worktree" "$WT" \
  "trap 'cd /tmp' EXIT; printf x > out.txt"
check block "a trap on EXIT and INT that cds may move it mid-line, from a worktree" "$WT" \
  "trap 'cd $MAIN' EXIT INT; printf x > out.txt"

# Codex review on ready (#81).
check block "false && popd keeps an unresolved directory unresolved, from a worktree" "$WT" \
  "D=$MAIN; pushd $WT; cd \"\$D\"; false && popd; printf x > out.txt"
check block "false && cd - keeps an unresolved directory unresolved, from a worktree" "$WT" \
  "cd /tmp; cd \"\$D\"; false && cd -; printf x > out.txt"
check block "a popd that may not run may leave the shell in main, from a worktree" "$WT" \
  "cd $MAIN; pushd $SCRATCH; cd $MAIN; if false; then popd; fi; printf x > out.txt"
check block "a pushd that may not run leaves the stack uncertain, from a worktree" "$WT" \
  "pushd $MAIN; false && pushd $SCRATCH; popd; printf x > out.txt"
check block "bash -O lastpipe -c: the child's pipeline cd moves the child" "$WT" \
  "bash -O lastpipe -c 'true | cd $MAIN; printf x > file.txt'"
check block "bash -ec (clustered) still analyses its command string" "$WT" \
  "bash -ec 'cd $MAIN; printf x > file.txt'"
check block "BASHOPTS=lastpipe bash -c: the child's pipeline cd moves the child" "$WT" \
  "BASHOPTS=lastpipe bash -c 'true | cd $MAIN; printf x > file.txt'"
check block "zsh -c: the last pipeline member runs in the shell (Codex round 8)" "$WT" \
  "zsh -c 'true | cd $MAIN; printf x > file.txt'"
check block "ksh -c: the last pipeline member runs in the shell" "$WT" \
  "ksh -c 'true | cd $MAIN; printf x > file.txt'"
check block "shopt -s {lastpipe,nullglob} may enable lastpipe (Codex round 9)" "$WT" \
  "shopt -s {lastpipe,nullglob}; true | cd $MAIN; printf x > out.txt"
check block "shopt -s \$X may enable lastpipe" "$WT" \
  "shopt -s \$X; true | cd $MAIN; printf x > out.txt"
check block "bash -O \$X -c may enable lastpipe in the child" "$WT" \
  "bash -O \$X -c 'true | cd $MAIN; printf x > file.txt'"
check block "shopt -s nullglob, then a cd at the end of a pipeline: unknown" "$WT" \
  "shopt -s nullglob; true | cd $MAIN; printf x > out.txt"
check block "bash -c: a cd at the end of a pipeline may move the child: unknown" "$WT" \
  "bash -c 'true | cd $MAIN; printf x > file.txt'"
check allow "true && popd back to a worktree, then a relative write" "$WT" \
  "pushd $SCRATCH && popd && printf x > out.txt"

# Codex round 10 on #81.
check block "an unresolvable pushd leaves the stack uncertain for popd, from a worktree" "$WT" \
  "pushd $SCRATCH; D=$MAIN; S=$WT; cd \"\$D\"; pushd \"\$S\"; popd; printf x > file.txt"
check block "a pushd to a missing directory leaves the stack uncertain, from a worktree" "$WT" \
  "cd $MAIN; pushd $SCRATCH; pushd $SCRATCH/missing; popd; popd; printf x > out.txt"
check allow "pushd / popd to existing absolute directories stays known, from a worktree" "$WT" \
  "pushd $SCRATCH; pushd /tmp; popd; popd; printf x > out.txt"

# Codex round 11 on #81.
check block "quoted \"if\" / \"fi\" are commands, not a compound, from a worktree" "$WT" \
  "\"if\"; cd $MAIN; \"fi\" | cat; printf x > file.txt"
check block "command { / command } are commands, not a group, from a worktree" "$WT" \
  "command {; cd $MAIN; command } | cat; printf x > file.txt"
check block "D=1 done is a command, not a loop end, from a worktree" "$WT" \
  "while false; do :; D=1 done | cat; cd $MAIN; printf x > file.txt; done"
check allow "a subshell's dirs -c does not taint the parent stack, from a worktree" "$WT" \
  "pushd $SCRATCH; (dirs -c); popd; printf x > out.txt"
check allow "a subshell's OLDPWD assignment does not taint the parent, from a worktree" "$WT" \
  "cd $SCRATCH; (OLDPWD=/x); cd -; printf x > out.txt"

# Codex round 12 on #81.
check block "\"time\" if … \"time\" fi: a quoted time is the program, not a keyword prefix" "$WT" \
  "\"time\" if; cd $MAIN; \"time\" fi | cat; printf x > file.txt"
check block "\"!\" { … \"!\" }: a quoted ! is a command name" "$WT" \
  "\"!\" {; cd $MAIN; \"!\" } | cat; printf x > file.txt"
check block "/usr/bin/time cd DIR does not move this shell, from main" "$MAIN" \
  "/usr/bin/time cd $SCRATCH; printf x > out.txt"
check allow "time { cd DIR; } keeps the keyword, from main" "$MAIN" \
  "time { cd $SCRATCH; }; printf x > out.txt"

# Codex round 13 on #81.
check block "pushd at the end of a pipeline leaves the stack uncertain, from a worktree" "$WT" \
  "pushd $SCRATCH; D=$MAIN; cd \"\$D\"; shopt -s lastpipe; true | pushd $SCRATCH; popd; printf x > file.txt"
check block "a compound with pushd at the end of a pipeline leaves the stack uncertain" "$WT" \
  "pushd $SCRATCH; D=$MAIN; cd \"\$D\"; true | { pushd $SCRATCH; }; popd; printf x > file.txt"

# Something that may run several cds loses OLDPWD and the stack too.
check block "source may set OLDPWD: cd - afterwards is unknown, from a worktree" "$WT" \
  "cd $SCRATCH; cd $SCRATCH; . /dev/null; cd -; printf x > out.txt"
check block "a trap handler that cds may set OLDPWD, from a worktree" "$WT" \
  "cd $SCRATCH; cd $SCRATCH; trap 'cd $MAIN; cd /tmp' DEBUG; cd -; printf x > out.txt"

# Codex round 14 on #81.
check allow "an EXIT trap's dirs -c does not taint the stack mid-line, from a worktree" "$WT" \
  "pushd $SCRATCH; trap 'dirs -c' EXIT; popd; printf x > out.txt"
check block "a DEBUG trap's dirs -c does taint the stack, from a worktree" "$WT" \
  "cd $MAIN; pushd $SCRATCH; trap 'dirs -c' DEBUG; popd; printf x > out.txt"

# Codex round 15 on #81: case patterns are not commands.
check block "a case pattern fi|y) does not close a compound, from a worktree" "$WT" \
  "case x in x) cd $MAIN;; fi|y) :;; esac; printf x > file.txt"
check block "a case pattern named cd is not a bare cd, from main" "$MAIN" \
  "case z in a) :;; cd) :;; esac; printf x > out.txt"
check block "a (pattern) with a leading paren is not a subshell, from a worktree" "$WT" \
  "case x in (x) cd $MAIN;; esac; printf x > file.txt"
check block "a cd in a case item applies after it, from a worktree" "$WT" \
  "case x in
  a | b) :;;
  x) cd $MAIN;;
esac
printf x > file.txt"
check allow "a case with no cd leaves the directory known, from a worktree" "$WT" \
  "case \$1 in -h|--help) echo usage;; *) echo run;; esac; printf x > out.txt"
check allow "(declare -l D) in a subshell does not reach the parent, from a worktree" "$WT" \
  "(declare -l D); D=/tmp; printf x > \"\$D/out.txt\""

# Codex round 16 on #81.
check block "a (esac|y) pattern does not close the case, from a worktree" "$WT" \
  "case x in x) cd $MAIN;; (esac|y) :;; esac; printf x > file.txt"
check allow "an EXIT trap's declare -l does not reach the rest of the line, from a worktree" "$WT" \
  "trap 'declare -l D' EXIT; D=/tmp; printf x > \"\$D/out.txt\""
check block "a DEBUG trap's declare -l does, from a worktree" "$WT" \
  "trap 'declare -l D' DEBUG; D=$TMP/REPO; printf x > \"\$D/file.txt\""

# Codex round 17 on #81.
check allow "declare -l in a non-final pipeline member stays in the child, from a worktree" "$WT" \
  "declare -l D | cat; D=/tmp; printf x > \"\$D/out.txt\""
check block "declare -l at the end of a pipeline may reach this shell, from a worktree" "$WT" \
  "true | declare -l D; D=$TMP/REPO; printf x > \"\$D/file.txt\""

# Codex round 18 on #81.
check block "popd -n drops the entry: a later popd fails and stays put, from a worktree" "$WT" \
  "pushd $SCRATCH; D=$MAIN; cd \"\$D\"; popd -n; popd; printf x > file.txt"
check block "a popd -n that may not run leaves the stack uncertain, from a worktree" "$WT" \
  "cd $MAIN; pushd $SCRATCH; pushd /tmp; false && popd -n; popd; popd; printf x > out.txt"
check allow "pushd A; pushd B; popd -n; popd returns to the start, from a worktree" "$WT" \
  "pushd $SCRATCH; pushd /tmp; popd -n; popd; printf x > out.txt"

# Stack reorders: pushd +N / bare pushd / popd +N leave the stack uncertain.
check block "pushd +1 rotates the stack: a later popd is unknown, from a worktree" "$WT" \
  "cd $MAIN; pushd $SCRATCH; pushd /tmp; pushd +1; cd /tmp; popd; printf x > out.txt"
check block "popd +1 removes an entry: a later popd is unknown, from a worktree" "$WT" \
  "cd $MAIN; pushd $SCRATCH; pushd /tmp; popd +1; cd /tmp; popd; printf x > out.txt"

# Codex round 19 on #81.
check block "pushd +1 after an unresolved cd: popd stays unknown, from a worktree" "$WT" \
  "pushd $SCRATCH; D=$MAIN; cd \"\$D\"; pushd +1; popd; printf x > file.txt"
check block "popd +1 after an unresolved cd: popd stays unknown, from a worktree" "$WT" \
  "pushd $SCRATCH; D=$MAIN; cd \"\$D\"; popd +1; popd; printf x > file.txt"

# Codex review on ready, round 20 (#81).
check allow "dirs -v / dirs +1 only display the stack, from a worktree" "$WT" \
  "pushd $SCRATCH; dirs -v; dirs +1; dirs -lp; popd; printf x > out.txt"
check block "dirs -lc clears the stack, from a worktree" "$WT" \
  "pushd $MAIN; dirs -lc; popd; printf x > out.txt"

# Codex review on ready, round 21 (#81).
check block "pushd -n +1 rotates the stack: later popds stay unknown, from a worktree" "$WT" \
  "pushd $SCRATCH; D=$MAIN; cd \"\$D\"; pushd -n +1; popd; popd; printf x > file.txt"

# Codex round 22 on #81.
check block "a trap handler's popd sees the stack as uncertain as it is, from a worktree" "$WT" \
  "pushd $SCRATCH; D=$MAIN; cd \"\$D\"; pushd +1; trap 'popd; printf x > file.txt' EXIT"
check allow "dirs -c in a non-final pipeline member clears only a child's stack, from a worktree" "$WT" \
  "pushd $SCRATCH; dirs -c | cat; popd; printf x > out.txt"

# Shell-state commands in a child shell do not reach this one.
check allow "OLDPWD=… in a non-final pipeline member, then cd -, from a worktree" "$WT" \
  "cd $SCRATCH; cd /tmp; OLDPWD=$MAIN true | cat; cd -; printf x > out.txt"
check allow "trap 'cd …' DEBUG in a non-final pipeline member, from a worktree" "$WT" \
  "trap 'cd $MAIN' DEBUG | cat; printf x > out.txt"
check allow "set -r / shopt -s cdable_vars / alias in a child, from a worktree" "$WT" \
  "set -r | cat; shopt -s cdable_vars | cat; alias x=y | cat; printf x > out.txt"
check block "a child trap's handler writes are still judged, from a worktree" "$WT" \
  "trap 'printf x > $MAIN/file.txt' EXIT | cat"

check block "DIRSTACK[1]=<main> alone is an assignment, not a program, from a worktree" "$WT" \
  "pushd /tmp; DIRSTACK[1]=$MAIN; popd; printf x > out.txt"
check block "a[0]=… / D+=… are assignments, not command names, from main" "$MAIN" \
  "a[0]=/tmp/x; D+=/y; cd $SCRATCH | cat; printf x > out.txt"

# Codex round 23 on #81.
check block "eval 'cd MAIN; write' | cat: the cd applies inside eval, from a worktree" "$WT" \
  "eval 'cd $MAIN; printf x > file.txt' | cat"
check block "bash -c 'cd MAIN; write' | cat, from a worktree" "$WT" \
  "bash -c 'cd $MAIN; printf x > file.txt' | cat"
check block "bash -c 'cd MAIN; write' &, from a worktree" "$WT" \
  "bash -c 'cd $MAIN; printf x > file.txt' & wait"

# Codex review on ready, round 24 (#81).
check allow "a trap whose cd is only in a child eval, from a worktree" "$WT" \
  "trap 'eval \"cd /tmp\" | cat' DEBUG; printf x > out.txt"
check allow "a trap whose cd is only in a child's trap, from a worktree" "$WT" \
  "trap 'trap \"cd /tmp\" DEBUG | cat' DEBUG; printf x > out.txt"

# Codex round 25 on #81.
check allow "OLDPWD=… alone in a non-final pipeline member, then cd -, from a worktree" "$WT" \
  "cd $SCRATCH; OLDPWD=/tmp | cat; cd -; printf x > out.txt"
check allow "DIRSTACK[1]=… alone in a background job, then popd, from a worktree" "$WT" \
  "pushd $SCRATCH; DIRSTACK[1]=/tmp & popd; printf x > out.txt"
check block "OLDPWD=… alone in this shell, then cd -, from a worktree" "$WT" \
  "cd $SCRATCH; cd /tmp; OLDPWD=$MAIN; cd -; printf x > out.txt"

# A child shell's source / eval / printf -v do not taint this shell's OLDPWD or stack.
check allow ". FILE | cat, then cd -, from a worktree" "$WT" \
  "cd $SCRATCH; cd /tmp; . /dev/null | cat; cd -; printf x > out.txt"
check allow "eval ':' | cat, then popd, from a worktree" "$WT" \
  "pushd $SCRATCH; eval ':' | cat; popd; printf x > out.txt"
check block ". FILE in this shell, then cd -, from a worktree" "$WT" \
  "cd $SCRATCH; cd /tmp; . /dev/null; cd -; printf x > out.txt"

# Codex round 26 on #81.
check allow "a DEBUG trap that installs an EXIT trap with a cd, from a worktree" "$WT" \
  "trap 'trap \"cd /tmp\" EXIT' DEBUG; printf x > out.txt"
check allow "source /dev/null | cat, then popd, from a worktree" "$WT" \
  "pushd $SCRATCH; source /dev/null | cat; popd; printf x > out.txt"

# Codex round 27 on #81.
check block "popd \"\$N\" (N=-n) may edit the stack: later popd unknown, from a worktree" "$WT" \
  "pushd $SCRATCH; D=$MAIN; cd \"\$D\"; N=-n; popd \"\$N\"; popd; printf x > file.txt"
check block "pushd \"\$N\" (N=-n) may edit the stack: later popd unknown, from a worktree" "$WT" \
  "cd $MAIN; pushd $SCRATCH; N=-n; pushd \"\$N\" /tmp; cd $SCRATCH; popd; printf x > file.txt"

# Codex round 28 on #81.
check allow "declare +i D removes an attribute, from a worktree" "$WT" \
  "declare +i D; D=/tmp; printf x > \"\$D/out.txt\""
# cd -P / physical mode resolve .. through symlinks.
mkdir -p "$SCRATCH/w"; ln -sfn "$MAIN/sub" "$SCRATCH/w/link" 2>/dev/null; mkdir -p "$MAIN/sub"
check block "cd -P link/.. lands in the symlink target's parent (main), from scratch" "$SCRATCH/w" \
  "cd -P link/..; printf x > file.txt"
check block "set -P then cd link/.. lands in main, from scratch" "$SCRATCH/w" \
  "set -P; cd link/..; printf x > file.txt"
check allow "cd link/.. (logical) stays in scratch, from scratch" "$SCRATCH/w" \
  "cd link/..; printf x > out.txt"

# Codex review on ready, round 29 (#81).
check allow "declare -ip D only displays, from a worktree" "$WT" \
  "D=/tmp; declare -ip D; D=/tmp; printf x > \"\$D/out.txt\""
check block "declare -i D (not print-only) still transforms, from a worktree" "$WT" \
  "declare -l D; D=$TMP/REPO; printf x > \"\$D/file.txt\""

# Codex round 1 on #82.
check block "declare -l D -p: -p after an operand is not an option, from a worktree" "$WT" \
  "declare -l D -p; D=$TMP/REPO; printf x > \"\$D/file.txt\""
check allow "(set -P) does not reach the parent, from scratch" "$SCRATCH/w" \
  "(set -P); cd link/..; printf x > out.txt"
check allow "bash -c 'set -P' does not reach the parent, from scratch" "$SCRATCH/w" \
  "bash -c 'set -P'; cd link/..; printf x > out.txt"

check allow "an EXIT trap's set -P does not apply mid-line, from scratch" "$SCRATCH/w" \
  "trap 'set -P' EXIT; cd link/..; printf x > out.txt"
check block "a DEBUG trap's set -P may apply mid-line, from scratch" "$SCRATCH/w" \
  "trap 'set -P' DEBUG; cd link/..; printf x > file.txt"

# Codex round 2 on #82.
check allow "set +P / set +o physical turn physical mode off, from scratch" "$SCRATCH/w" \
  "set +P; set +o physical; cd link/..; printf x > out.txt"
check block "set -o physical turns it on, from scratch" "$SCRATCH/w" \
  "set -o physical; cd link/..; printf x > file.txt"

# Codex round 3 on #82.
check allow "set -P does not reach a new bash -c (SHELLOPTS not exported), from scratch" "$SCRATCH/w" \
  "set -P; bash -c 'cd link/..; printf x > out.txt'"
check block "bash -P -c: the child is physical, from scratch" "$SCRATCH/w" \
  "bash -P -c 'cd link/..; printf x > file.txt'"
check block "export SHELLOPTS: the child may be physical, from scratch" "$SCRATCH/w" \
  "set -P; export SHELLOPTS; bash -c 'cd link/..; printf x > file.txt'"

# Codex round 4 on #82: a logical cd drops .. textually before a later cd -P.
ln -sfn "$SCRATCH" "$MAIN/link2" 2>/dev/null
check block "cd -L MAIN/link/..; cd -P . lands in main, from scratch" "$SCRATCH" \
  "cd -L $MAIN/link2/..; cd -P .; printf x > file.txt"
check allow "cd -L MAIN/link/.. … then cd /tmp, from main" "$MAIN" \
  "cd -L $MAIN/link2/..; cd /tmp; printf x > out.txt"

# The kernel resolves a write's .. through symlinks.
check block "printf x > link/../f writes into the symlink target's parent (main), from scratch" "$SCRATCH/w" \
  "printf x > link/../file.txt"
check allow "printf x > repo/link2/../f lands beside scratch (link2 -> scratch), not in main" "$TMP" \
  "printf x > repo/link2/../out.txt"

# Codex round 5 on #82.
check block "cd -L SCRATCH/missing/.. fails (bash refuses it), from main" "$MAIN" \
  "cd -L $SCRATCH/missing/..; printf x > out.txt"
check block "cd -P SCRATCH/missing/.. fails, from main" "$MAIN" \
  "cd -P $SCRATCH/missing/..; printf x > out.txt"
check allow "mkdir -p SCRATCH/new; cd SCRATCH/new/.. works, from main" "$MAIN" \
  "mkdir -p $SCRATCH/new2; cd $SCRATCH/new2/..; printf x > out.txt"
check block "mkdir SCRATCH/x does not make SCRATCH/missing/.. reachable, from main" "$MAIN" \
  "mkdir -p $SCRATCH/x3; cd $SCRATCH/missing/..; printf x > out.txt"
check allow "mkdir -p then cd into it still works, from main" "$MAIN" \
  "mkdir -p $SCRATCH/x4/y; cd $SCRATCH/x4/y; printf x > out.txt"

# Codex round 6 on #82: a logical cd falls back to the physical path.
mkdir -p "$MAIN/dest6"
check block "cd -L link/../dest falls back to the physical target (main), from scratch" "$SCRATCH/w" \
  "cd -L $SCRATCH/w/link/../dest6; printf x > out.txt"

# Codex round 7 on #82.
mkdir -p "$SCRATCH/safe" "$TMP/nl"; mkdir -p "$SCRATCH/safe
x"; ln -sfn "$MAIN" "$SCRATCH/safe
x/m" 2>/dev/null
check block "a directory name with a newline is not truncated, from a worktree" "$WT" \
  "cd '$SCRATCH/safe
x/m'; printf x > file.txt"
check allow "set -P; set +P turns physical mode off again, from scratch" "$SCRATCH/w" \
  "set -P; set +P; cd link/..; printf x > out.txt"
check block "set -P; false && set +P keeps it possibly on, from scratch" "$SCRATCH/w" \
  "set -P; false && set +P; cd link/..; printf x > file.txt"

# Codex round 8 on #82.
mkdir -p "$SCRATCH/sub8"
check block "cd -L SCRATCH/sub/../missing/.. fails (a later component is missing), from main" "$MAIN" \
  "cd -L $SCRATCH/sub8/../missing/..; printf x > out.txt"
mkdir -p "$SCRATCH/safe8"; ln -sfn "$MAIN" "$SCRATCH/safe8
" 2>/dev/null
check block "cd -P to a name ending in a newline is not truncated, from a worktree" "$WT" \
  "cd -P '$SCRATCH/safe8
'; printf x > file.txt"

# Codex round 9 on #82: a missing intermediate logical component falls back to physical.
mkdir -p "$MAIN/foo9"
check block "cd -L link/../foo/.. falls back physically into main, from scratch" "$SCRATCH/w" \
  "cd -L $SCRATCH/w/link/../foo9/..; printf x > probe.txt"
check allow "cd -L link/.. stays logical (in scratch), from scratch" "$SCRATCH/w" \
  "cd -L $SCRATCH/w/link/..; printf x > out.txt"

# Codex round 10 on #82.
check allow "bash -P +P -c / bash -o physical +o physical -c end logical, from scratch" "$SCRATCH/w" \
  "bash -P +P -c 'cd link/..; printf x > out.txt'; bash -o physical +o physical -c 'cd link/..; printf x > out.txt'"
check allow "export SHELLOPTS inside a subshell does not reach a later child, from scratch" "$SCRATCH/w" \
  "(set -P; export SHELLOPTS); bash -c 'cd link/..; printf x > out.txt'"

# Codex round 11 on #82.
check allow "mkdir -p SCRATCH/./new; cd SCRATCH/./new, from main" "$MAIN" \
  "mkdir -p $SCRATCH/./new11; cd $SCRATCH/./new11; printf x > out.txt"

# Codex round 12 on #82.
check block "mkdir -p link/../new does not make SCRATCH/new reachable, from main" "$MAIN" \
  "mkdir -p $SCRATCH/w/link/../new12; cd $SCRATCH/w/new12; printf x > out.txt"

# mkdir: without -p a missing parent fails; conditional or relative-to-unknown mkdir is not counted.
check block "mkdir SCRATCH/x/y without -p fails when x is missing, from main" "$MAIN" \
  "mkdir $SCRATCH/nx13/y; cd $SCRATCH/nx13; printf x > out.txt"
check block "false && mkdir DIR; cd DIR: the mkdir may not run, from main" "$MAIN" \
  "false && mkdir $SCRATCH/c13; cd $SCRATCH/c13; printf x > out.txt"
check block "mkdir new after an unresolved cd is not new under the old cwd, from scratch" "$SCRATCH" \
  "cd \"\$D\"; mkdir r13; cd $SCRATCH/r13; printf x > out.txt"
check allow "mkdir -p DIR && cd DIR && write, from main" "$MAIN" \
  "mkdir -p $SCRATCH/ok13/a && cd $SCRATCH/ok13/a && printf x > out.txt"

# 084c604 regressions (director brief, 24 Nov): parser confusion must never
# switch the guard off. Every older copy blocked these.
check block "\$(case x in (x) write;; esac), from main" "$MAIN" \
  'echo "$(case x in (x) printf x > probe;; esac)"'
check block "\$(case x in x) write;; esac) (unparenthesised pattern), from main" "$MAIN" \
  'echo "$(case x in x) printf x > probe;; esac)"'
check block "(case x in (x) cd /tmp;; esac); write: the cd stays in the subshell, from main" "$MAIN" \
  '(case x in (x) cd /tmp;; esac); printf x > file.txt'
check block "(case x in x) cd /tmp;; esac); write, from main" "$MAIN" \
  '(case x in x) cd /tmp;; esac); printf x > file.txt'
check block "case x in esac; printf: an empty case does not swallow the next command, from main" "$MAIN" \
  'case x in esac; printf x > file.txt'
check block "case x in esac; echo bad > file, from main" "$MAIN" \
  'case x in esac; echo bad > file.txt'
check block "case x in esac (newline), then a write, from main" "$MAIN" \
  'case x in esac
printf x > file.txt'
check block "case x in esac; cp into main, from scratch" "$SCRATCH" \
  "case x in esac; cp $SCRATCH/a.txt $MAIN/x.txt"
check block "case x in esac; sed -i, from main" "$MAIN" \
  'case x in esac; sed -i s/a/b/ file.txt'
check block "a case item ending in ; && is not a pattern: the write is judged, from main" "$MAIN" \
  'case x in x) true;; y) false;; esac && printf x > file.txt'
check block "nested: \$( ( case x in (x) cd /tmp;; esac ); write ), from main" "$MAIN" \
  'echo "$( (case x in (x) cd /tmp;; esac); printf x > probe )"'
check block "nested: ( \$(case …) ; cd /tmp in a pattern body ) then write, from main" "$MAIN" \
  '( x=$(case y in y) echo;; esac); case x in (x) cd /tmp;; esac ); printf x > file.txt'
check block "case pattern ) inside backticks, from main" "$MAIN" \
  'echo `case x in x) printf x > probe;; esac`'
check block "\$(case …) whose item cps into main, from scratch" "$SCRATCH" \
  "echo \"\$(case x in x) cp $SCRATCH/a.txt $MAIN/x.txt;; esac)\""
check block "\$(case …) whose item runs sed -i on a main file, from scratch" "$SCRATCH" \
  "echo \"\$(case x in (x) sed -i s/a/b/ $MAIN/file.txt;; esac)\""
check block "an unclosed case in \$( … ) fails closed, from main" "$MAIN" \
  'echo "$(case x in x) echo)"; printf x > /tmp/ok.txt'
check block "D=<main>; cd \"\$D\"; printf x > '~missinguser' (a relative name), from a worktree" "$WT" \
  "D=$MAIN; cd \"\$D\"; printf x > '~missinguser'"
check block "D=<main>; cd \"\$D\"; printf x > ~missinguser (unresolved ~user stays relative), from a worktree" "$WT" \
  "D=$MAIN; cd \"\$D\"; printf x > ~missinguser"
check block "D=<main>; cd \"\$D\"; cp f '~/x' (quoted ~ is a relative dir), from a worktree" "$WT" \
  "D=$MAIN; cd \"\$D\"; cp /tmp/a.txt '~/x'"
check block "printf x > '~/x' from main writes main/~/x (quoted ~ is literal)" "$MAIN" \
  "printf x > '~/x'"
mkdir -p "$SCRATCH/qt"; ln -sfn "$MAIN" "$SCRATCH/qt/~"
check block "printf x > '~/f' where ./~ links to main, from outside a repo (Codex round 13 on #82)" "$SCRATCH/qt" \
  "printf x > '~/probe.txt'"
check allow "printf x > '~/f' where ./~ is a plain scratch dir, from a worktree" "$WT" \
  "mkdir -p '~'; printf x > '~/probe.txt'"
check block "printf x > \\~/x from main (escaped ~ is literal)" "$MAIN" \
  'printf x > \~/x'
HOME="$SCRATCH" check allow "unquoted ~/x after an unresolved cd is still absolute, from a worktree" "$WT" \
  'cd "$D"; printf x > ~/out.txt'
check allow "case with items and a write elsewhere, from main" "$MAIN" \
  "case x in x) echo hi;; esac; printf x > $SCRATCH/out.txt"
check allow "\$(case …) with no write, then an absolute write, from main" "$MAIN" \
  "v=\"\$(case x in (x) echo a;; esac)\"; printf '%s' \"\$v\" > $SCRATCH/out.txt"

# The last member of a pipeline may run in this shell: fail closed.
check allow "a cd before a | is a child shell, from a worktree" "$WT" \
  "cd $MAIN | cat; printf x > out.txt"
check block "true | eval 'cd DIR': eval at the end of a pipeline, from main" "$MAIN" \
  "true | eval 'cd $SCRATCH'; printf x > out.txt"
check block "true | { D=MAIN; }: a binding it changed is not trusted, from a worktree" "$WT" \
  "D=/tmp; true | { D=$MAIN; }; printf x > \"\$D/file.txt\""
check block "true | D=MAIN: a last-member assignment may persist, from a worktree" "$WT" \
  "D=/tmp; true | D=$MAIN; printf x > \"\$D/file.txt\""
check allow "true | { echo; }: no cd or binding change leaves the state known" "$WT" \
  "D=/tmp; true | { echo hi; }; printf x > \"\$D/out.txt\"; printf x > out.txt"

# An unquoted $D splits and globs: a value with spaces or glob characters is
# never bound.
check block "a value with a space splits into a main path, from a worktree" "$WT" \
  "D='/tmp/x $MAIN/file.txt'; echo x | tee \$D"
check block "a glob value may match a main path, from a worktree" "$WT" \
  "D=$TMP/rep*; printf x > \$D/file.txt"
check allow "a value with a space naming scratch paths, from a worktree" "$WT" \
  "D='$SCRATCH/a $SCRATCH/b'; echo x | tee \$D"

# Unchanged: literal targets resolve, absolute writes are judged on their own.
check allow "cd -P DIR (valid option) then a relative write, from main" "$MAIN" \
  "cd -P $SCRATCH; printf x > out.txt"
check allow "cd -- DIR then a relative write, from main" "$MAIN" \
  "cd -- $SCRATCH; printf x > out.txt"
check allow "an absolute cd after an unresolved cd settles it" "$WT" \
  "cd \"\$D\"; cd $SCRATCH; printf x > out.txt"
check allow "unresolved cd, then an absolute write elsewhere, from a worktree" "$WT" \
  "cd \"\$D\"; printf x > $SCRATCH/out.txt"
check allow "unresolved cd with no write, from a worktree" "$WT" \
  'cd "$D" && ls && git status'
check allow "pushd / popd round trip, from a worktree" "$WT" \
  "pushd $SCRATCH; printf x > out.txt; popd; printf x > notes.txt"
check allow "a plain re-binding still binds" "$SCRATCH" \
  "D=$MAIN; D=$SCRATCH; printf x > \"\$D/out.txt\""
check allow "export \"D=…\" is an assignment" "$SCRATCH" \
  "D=$MAIN; export \"D=$SCRATCH\"; printf x > \"\$D/out.txt\""

# Codex on the luminalityai sync PRs (delivery-ops#581, marketing-ops#55,
# luminality-app#465): writes into main that 723d4bf allowed. The empty-case
# close looked for esac at a fixed word, so a prefix left the case "open" and
# later commands were read as patterns; case patterns were not scanned for
# ${D:=…}. Every row here is a real write into main in bash.
echo "  -- case statements after a prefix, and their patterns --"
echo s > "$SCRATCH/a.txt"
check block "! case x in esac, NL, cp into main, from scratch" "$SCRATCH" \
  "! case x in esac
cp $SCRATCH/a.txt $MAIN/probe"
check block "! case x in esac, NL, printf > main, from scratch" "$SCRATCH" \
  "! case x in esac
printf x > $MAIN/probe"
check block "time case x in esac, NL, printf > main, from scratch" "$SCRATCH" \
  "time case x in esac
printf x > $MAIN/probe"
check block "case x in y) :;; \${D:=MAIN}) :;; esac; printf > \$D/f, from scratch" "$SCRATCH" \
  "case x in y) :;; \${D:=$MAIN}) :;; esac; printf x > \"\$D/file.txt\""

# Every reserved-word prefix and separator before an empty case.
while IFS= read -r _w; do
  [[ -z "$_w" ]] && continue
  _pre="${_w%%@*}"; _post="${_w#*@}"
  check block "${_pre}case x in esac${_post}, NL, printf > main, from scratch" "$SCRATCH" \
    "${_pre}case x in esac${_post}
printf x > $MAIN/probe"
  check block "${_pre}case x in esac${_post}; cp into main, from scratch" "$SCRATCH" \
    "${_pre}case x in esac${_post}; cp $SCRATCH/a.txt $MAIN/x.txt"
  check block "${_pre}case x in esac${_post}, NL, cd main, NL, relative write, from a worktree" "$WT" \
    "${_pre}case x in esac${_post}
cd $MAIN
printf x > probe"
done <<'ROWS'
! @
time @
time -p @
coproc @
{ @; }
( @ )
if @ then :; fi
if true; then @; fi
while false; do @; done
if false; then :; else @; fi
true; @
true && @
false || @
true | @
true
@
! { @; }
case y in y) @;; esac
echo "$(! @)"
ROWS

check block "case x in x) ! case y in esac;; esac, NL, write, from scratch" "$SCRATCH" \
  "case x in x) ! case y in esac;; esac
printf x > $MAIN/probe"
check block "! case x in (y) cd MAIN;; esac; relative write, from scratch" "$SCRATCH" \
  "! case x in (y) cd $MAIN;; esac; printf x > probe"
check block "time -p case x in y) cd /tmp;; esac; relative write, from main" "$MAIN" \
  "time -p case x in y) cd /tmp;; esac; printf x > probe"
check block "a closer then a reserved word: if while …; done then cd MAIN; fi, from scratch" "$SCRATCH" \
  "if while false; do :; done then cd $MAIN; fi; printf x > probe"
check block "case x in esac then cd MAIN, from scratch" "$SCRATCH" \
  "if case x in esac then cd $MAIN; fi; printf x > probe"
check block "case x (NL) in (NL) esac, NL, write, from scratch" "$SCRATCH" \
  "case x
in
esac
printf x > $MAIN/probe"

# Expansions in case patterns and case words.
check block "\${D=MAIN} in a later pattern, from scratch" "$SCRATCH" \
  "case x in y) :;; \${D=$MAIN}) :;; esac; printf x > \"\$D/file.txt\""
check block "\${D:=MAIN} as the case word, from scratch" "$SCRATCH" \
  "case \${D:=$MAIN} in esac; printf x > \"\$D/file.txt\""
check block "\${D:=MAIN} in the first pattern, from scratch" "$SCRATCH" \
  "case x in \${D:=$MAIN}) :;; esac; printf x > \"\$D/file.txt\""
check block "\${D:=MAIN} in a (pattern), from scratch" "$SCRATCH" \
  "case x in (\${D:=$MAIN}) :;; esac; printf x > \"\$D/file.txt\""
check block "\${D:=MAIN} after | in a pattern list, from scratch" "$SCRATCH" \
  "case x in y|\${D:=$MAIN}) :;; esac; printf x > \"\$D/file.txt\""
check block "\"\${D:=MAIN}\" quoted in a pattern, from scratch" "$SCRATCH" \
  "case x in y) :;; \"\${D:=$MAIN}\") :;; esac; printf x > \"\$D/file.txt\""
check block "nested \${D:=\${E:=MAIN}} assigns E, from scratch" "$SCRATCH" \
  "case x in y) :;; \${D:=\${E:=$MAIN}}) :;; esac; printf x > \"\$E/file.txt\""
check block "nested \${D:=\${E:=MAIN}} outside a case, from scratch" "$SCRATCH" \
  ": \${D:=\${E:=$MAIN}}; printf x > \"\$E/file.txt\""
check block "\$(…) in a pattern writes into main, from scratch" "$SCRATCH" \
  "case x in \"\$(printf x > $MAIN/probe)\") :;; esac"
check block "\$(…) as the case word writes into main, from scratch" "$SCRATCH" \
  "case \$(printf x > $MAIN/probe) in esac"
check block "\$((D=1)) in a pattern, then \$D/f, from main" "$MAIN" \
  "case x in \$((D=1))) :;; esac; printf x > \"\$D/f\""
check block "\$((D=…)) in a pattern, then \$D/f, from a worktree (backstop)" "$WT" \
  "case x in \$((D=1))) :;; esac; printf x > \"\$D/f\""

# A value given on a branch that may not run is still a value the line gave:
# concatenated, it lands in main.
_MP="${MAIN%/*}"; _MB="${MAIN##*/}"
check block "if …; then D=<parent>/<half>; fi; > \"\${D}<rest>/f\", from scratch" "$SCRATCH" \
  "if true; then D=$_MP/${_MB:0:2}; fi; printf x > \"\${D}${_MB:2}/file.txt\""
check block "read D <<< <parent>/<half>; > \"\${D}<rest>/f\", from scratch" "$SCRATCH" \
  "read D <<< $_MP/${_MB:0:2}; printf x > \"\${D}${_MB:2}/file.txt\""
check block "printf -v D … <half>; > \"\${D}<rest>/f\", from scratch" "$SCRATCH" \
  "printf -v D %s $_MP/${_MB:0:2}; printf x > \"\${D}${_MB:2}/file.txt\""
check block "true && D=<parent>/<half>; > \"\${D}<rest>/f\", from scratch" "$SCRATCH" \
  "true && D=$_MP/${_MB:0:2}; printf x > \"\${D}${_MB:2}/file.txt\""
check block "if …; then A=<parent>; B=<name>; fi; > \"\$A/\$B/f\", from scratch" "$SCRATCH" \
  "if true; then A=$_MP; B=$_MB; fi; printf x > \"\$A/\$B/file.txt\""
check allow "true && D=SCRATCH/half; > \"\${D}rest/f\" stays in scratch" "$SCRATCH" \
  "true && D=$SCRATCH/o; printf x > \"\${D}ut.txt\""

echo "  -- structural backstop --"
check block "bash <<EOF with a write into main, from a worktree" "$WT" \
  "bash <<'EOF'
printf x > $MAIN/probe
EOF"
check block "echo '…' | sh with a variable write into main, from a worktree" "$WT" \
  "echo 'D=$MAIN; printf x > \"\$D/f\"' | sh"
check block "sh <<EOF with a variable write, from a worktree" "$WT" \
  "sh <<'EOF'
D=$MAIN; printf x > \"\$D/f\"
EOF"
check block "eval 'printf > main', from a worktree" "$WT" \
  "eval 'printf x > $MAIN/probe'"
check block "case …; a computed destination, from a worktree (backstop rule B)" "$WT" \
  "case \$1 in a) :;; esac; printf x > \"\$OUT/f\""
check block "case …; cd \"\$D\"; relative write, from a worktree (backstop rule B)" "$WT" \
  "case \$1 in a) :;; esac; cd \"\$D\"; printf x > out.txt"
check block "a computed command name on a case line, from a worktree" "$WT" \
  "case \$1 in a) :;; esac; \$WRITER x"
mkdir -p "$SCRATCH/cv"
check block "case …; shopt -s cdable_vars; cd NAME (→ \$NAME); relative write, from scratch" "$SCRATCH" \
  "case x in esac; shopt -s cdable_vars; cv=$MAIN; cd cv; printf x > probe"
check block "touch into main, from scratch" "$SCRATCH" "touch $MAIN/new.txt"
check block "mkdir into main, from scratch" "$SCRATCH" "mkdir -p $MAIN/newdir"
check block "rm in main, from scratch" "$SCRATCH" "rm -f $MAIN/file.txt"
check block "ln -s into main, from scratch" "$SCRATCH" "ln -s /tmp $MAIN/lnk"
check block "chmod a main file, from scratch" "$SCRATCH" "chmod +x $MAIN/file.txt"
check block "truncate a main file, from scratch" "$SCRATCH" "truncate -s 0 $MAIN/file.txt"
check block "dd of= a main file, from scratch" "$SCRATCH" "dd if=/dev/zero of=$MAIN/file.txt count=1"
check block "curl -o into main, from scratch" "$SCRATCH" "curl -sSLo $MAIN/x https://example.com"
check block "sort -o into main, from scratch" "$SCRATCH" "sort -o $MAIN/file.txt $SCRATCH/a.txt"
check block "touch with a relative path, from main" "$MAIN" "touch new.txt"
check allow "touch / mkdir / rm / chmod in scratch, from main" "$MAIN" \
  "touch $SCRATCH/t2.txt; mkdir -p $SCRATCH/d2; chmod +x $SCRATCH/t2.txt; rm -f $SCRATCH/t2.txt"
check allow "case with literal writes to scratch, from a worktree" "$WT" \
  "case \$1 in a) printf x > $SCRATCH/a.out;; *) printf y >> $SCRATCH/b.out;; esac"
check allow "a PR body that mentions writes into main is prose, from main" "$MAIN" \
  "gh pr create --title t --body \"\$(cat <<'EOF'
Repro: printf x > $MAIN/probe; cp a $MAIN/x (don't run it)
EOF
)\""
check allow "a commit message with > and a main path is prose, from main" "$MAIN" \
  "git commit -m \"case x in esac; printf x > $MAIN/probe\""
check allow "bash -c writing to scratch, from main" "$MAIN" \
  "bash -c 'printf x > $SCRATCH/c.out'"
check allow "eval \"\$(mise activate bash)\"; mise ls, from a worktree" "$WT" \
  'eval "$(mise activate bash)"; mise ls'
check allow "eval \"\$(ssh-agent -s)\" then a scratch write, from a worktree" "$WT" \
  "eval \"\$(ssh-agent -s)\"; printf x > $SCRATCH/agent.out"
check allow "time -p and coproc with no write, from main" "$MAIN" \
  "time -p git status; ! case x in esac"

# repro3 rows (Codex on the rarebit sync PRs): an empty case after any
# reserved-word prefix, its closer on a later line.
check block "repro3: if true; then case x in esac, NL write, NL fi, from scratch" "$SCRATCH" \
  "if true; then case x in esac
printf x > $MAIN/p1
fi"
check block "repro3: else case x in esac, NL write, NL fi, from scratch" "$SCRATCH" \
  "if false; then :; else case x in esac
printf x > $MAIN/p2
fi"
check block "repro3: for … do case x in esac, NL write, NL done, from scratch" "$SCRATCH" \
  "while false; do :; done; for i in 1; do case x in esac
printf x > $MAIN/p3
done"
check block "repro3: { case x in esac, NL write, NL }, from scratch" "$SCRATCH" \
  "{ case x in esac
printf x > $MAIN/p4
}"
check block "repro3: true && case x in esac, NL write, from scratch" "$SCRATCH" \
  "true && case x in esac
printf x > $MAIN/p5"
check block "repro3: true; ! case x in esac, NL write, from scratch" "$SCRATCH" \
  "true; ! case x in esac
printf x > $MAIN/p6"
check block "repro3: ! case x in esac, NL write, from scratch" "$SCRATCH" \
  "! case x in esac
printf x > $MAIN/p7"
check block "repro3: time case x in esac, NL write, from scratch" "$SCRATCH" \
  "time case x in esac
printf x > $MAIN/p8"
check block "repro3: \${D:=MAIN} in a case pattern, from scratch" "$SCRATCH" \
  "case x in y) :;; \${D:=$MAIN}) :;; esac; printf x > \"\$D/p9\""
check block "repro3: printf > main, from scratch" "$SCRATCH" \
  "printf x > $MAIN/p0"

# repro2 rows (the director's repro, as tests).
check block "repro2: case x in esac, NL, printf > main, from scratch" "$SCRATCH" \
  "case x in esac
printf x > $MAIN/probe"
check block "repro2: printf > main, from scratch" "$SCRATCH" \
  "printf x > $MAIN/probe"

# --- repro4 (agent-estate#84 follow-up): ANSI-C payloads, relative writes ---
# Inside $'…', \x2f is a `/`: MAIN spelled that way.
MAINX="${MAIN//\//\\x2f}"
mkdir -p "$MAIN/ewbsub"

check block "repro4: bash -c \$'…\\x78…' after cd main, from scratch" "$SCRATCH" \
  "bash -c \$':; cd $MAIN; printf \\x78 > p1'"
check block "repro4: sh -c \$'…\\x78…' after cd main, from scratch" "$SCRATCH" \
  "sh -c \$':; cd $MAIN; printf \\x78 > p1'"
check block "repro4: bash -lc \$'…\\x78…' after cd main, from scratch" "$SCRATCH" \
  "bash -lc \$'cd $MAIN\\nprintf \\x78 > p1'"
check block "repro4: bash -o pipefail -c \$'…' after cd main, from scratch" "$SCRATCH" \
  "bash -o pipefail -c \$'cd $MAIN; touch \\x70\\x31'"
check block "repro4: bash -c \$'…' target spelled with \\x2f, from scratch" "$SCRATCH" \
  "bash -c \$'printf x > $MAINX\\x2fp1'"
check block "repro4: nested bash -c inside bash -c, \\x2f path, from scratch" "$SCRATCH" \
  "bash -c \"bash -c \$'touch $MAINX\\x2fp1'\""
check block "repro4: touch \$'…\\x2f…' into main, from scratch" "$SCRATCH" \
  "touch \$'$MAINX\\x2fp1'"
check block "repro4: octal-escaped command name in a payload, from scratch" "$SCRATCH" \
  "sh -c \$'cd $MAIN; \\164ouch p1'"
check block "repro4: eval \$'…\\n…' after cd main, from scratch" "$SCRATCH" \
  "eval \$'cd $MAIN\\nprintf x > e1'"
check block "repro4: find -exec sh -c \$'…' into main, from scratch" "$SCRATCH" \
  "find . -maxdepth 0 -exec sh -c \$'touch $MAINX\\x2fp1' \\;"
check block "repro4: bash -s ARG reads commands from stdin (Codex P1), from scratch" "$SCRATCH" \
  "bash -s arg <<< 'printf x > $MAIN/probe'"
check block "repro4: bash -i / bash /dev/stdin / sh - read stdin, from scratch" "$SCRATCH" \
  "bash /dev/stdin <<< 'printf x > $MAIN/probe'"
check block "repro4: sh -c \"\$1\" re-parses a literal positional argument (Codex P1), from scratch" "$SCRATCH" \
  "bash -c 'sh -c \"\$1\"' -- 'printf x > $MAIN/probe'"
check block "repro4: find -exec sh -c with the code in a positional argument, from scratch" "$SCRATCH" \
  "find . -maxdepth 0 -exec sh -c 'sh -c \"\$1\"' _ 'printf x > $MAIN/probe' \\;"
check block "repro4: bash -c \"\$X\" with X's code quoted on the line, from scratch" "$SCRATCH" \
  "X='printf x > $MAIN/probe'; bash -c \"\$X\""
check block "repro4: eval \"\$X\" with code quoted later on the line, from scratch" "$SCRATCH" \
  "eval \"\$X\"; Y='printf x > $MAIN/probe'"
check block "repro4: bash -c '. /dev/stdin' <<< code (Codex P1), from scratch" "$SCRATCH" \
  "bash -c '. /dev/stdin' <<< 'printf x > $MAIN/probe'"
check block "repro4: source /dev/stdin with a quoted heredoc, from scratch" "$SCRATCH" \
  "source /dev/stdin <<'EOF'
printf x > $MAIN/probe
EOF"
check block "repro4: bash -c 'source <(cat)' <<< code, from scratch" "$SCRATCH" \
  "bash -c 'source <(cat)' <<< 'printf x > $MAIN/probe'"
check allow "repro4: source a literal file, then jq 'select(…)' to /tmp, from a worktree" "$WT" \
  "source $SCRATCH/env.sh; jq '.[] | select(.a)' $SCRATCH/in.json > /tmp/ewb-o.json"
check block "repro4: BASH_ENV=/dev/stdin bash -c true <<< code (Codex P1), from scratch" "$SCRATCH" \
  "BASH_ENV=/dev/stdin bash -c true <<< 'printf x > $MAIN/probe'"
check block "repro4: bash --rcfile /dev/stdin -ic true <<< code (Codex P1), from scratch" "$SCRATCH" \
  "bash --rcfile /dev/stdin -ic true <<< 'printf x > $MAIN/probe'"
check block "repro4: bash /dev/./stdin <<< code (Codex P1), from scratch" "$SCRATCH" \
  "bash /dev/./stdin <<< 'printf x > $MAIN/probe'"
check block "repro4: a script file the line writes from quoted text, then bash runs it, from scratch" "$SCRATCH" \
  "printf '%s' 'printf x > $MAIN/probe' > /tmp/ewb-s.sh; bash /tmp/ewb-s.sh"
check block "repro4: on a bash -c line every quoted string is code (accepted over-block)" "$SCRATCH" \
  "bash -c 'true'; printf '%s' '<!-- a --> b' > /tmp/ewb-o.html; echo '> $MAIN/x'"
check allow "repro4: bash -c with a literal positional argument that only prints, to /tmp" "$SCRATCH" \
  "bash -c 'echo \"\$1\"' _ hi > /tmp/ewb-o"
check block "repro4: an escape shells decode differently (\\q) in a payload, from scratch" "$SCRATCH" \
  "bash -c \$'cd $MAIN; printf \\q > p1'"
check block "repro4: \\u in a payload is unresolved (literal in bash 3.2), even to /tmp (accepted)" "$SCRATCH" \
  "bash -c \$'echo \\u41 > /tmp/ewb-u41'"
check block "repro4: \\c in a payload is unresolved (zsh does not decode it)" "$SCRATCH" \
  "bash -c \$'cd $MAIN; echo \\cA > p1'"
check block "repro4: NUL in a payload is unresolved" "$SCRATCH" \
  "bash -c \$'cd $MAIN; echo \\x00 > p1'"
check block "repro4: cd main; touch, from a worktree" "$WT" \
  "cd $MAIN; touch p2"
check block "repro4: cd main; touch, from scratch" "$SCRATCH" \
  "cd $MAIN; touch p2"
check block "repro4: cd main && touch, from a worktree" "$WT" \
  "cd $MAIN && touch p2"
check block "repro4: cd .; touch, from main" "$MAIN" \
  "cd .; touch p3"
check block "repro4: cd ..; touch into main, from scratch" "$SCRATCH" \
  "cd $MAIN/ewbsub; cd ..; touch p3"
check block "repro4: cd -; touch back in main, from a worktree" "$WT" \
  "cd $MAIN; cd $SCRATCH; cd -; touch p3"
check block "repro4: pushd main; touch, from a worktree" "$WT" \
  "pushd $MAIN; touch p3"
check block "repro4: pushd main; pushd scratch; popd; touch, from a worktree" "$WT" \
  "pushd $MAIN; pushd $SCRATCH; popd; touch p3"
check block "repro4: ( cd main; touch ), from a worktree" "$WT" \
  "( cd $MAIN; touch p3 )"
check block "repro4: cd main; mkdir, from a worktree" "$WT" \
  "cd $MAIN; mkdir newdir"
check block "repro4: cd main; rm, from a worktree" "$WT" \
  "cd $MAIN; rm -f file.txt"
check block "repro4: cd main; rmdir, from a worktree" "$WT" \
  "cd $MAIN; rmdir ewbsub"
check block "repro4: cd main; ln -s, from a worktree" "$WT" \
  "cd $MAIN; ln -s /tmp/x link"
check block "repro4: cd main; chmod, from a worktree" "$WT" \
  "cd $MAIN; chmod 644 file.txt"
check block "repro4: cd main; truncate, from a worktree" "$WT" \
  "cd $MAIN; truncate -s 0 file.txt"
check block "repro4: cd main; dd of=, from a worktree" "$WT" \
  "cd $MAIN; dd if=/dev/null of=d.bin"
check block "repro4: cd main; sort -o, from a worktree" "$WT" \
  "cd $MAIN; sort -o s.txt $SCRATCH/in.txt"
check block "repro4: cd main; curl -o, from a worktree" "$WT" \
  "cd $MAIN; curl -sSo c.txt https://example.com"
check block "repro4: cd main; cp / mv into ., from a worktree" "$WT" \
  "cd $MAIN; cp $SCRATCH/in.txt ."
check block "repro4: cd main; tee, from a worktree" "$WT" \
  "cd $MAIN; echo x | tee t.txt"
check block "repro4: unresolved cd; touch, from a worktree" "$WT" \
  "cd \"\$X\"; touch p4"
check block "repro4: unresolved cd; mkdir, from scratch" "$SCRATCH" \
  "cd \$(dirname $MAIN/x); mkdir q"
check block "repro4: a quoted '=' does not hide a live \${X:=y} (Codex P1), from a worktree" "$WT" \
  ": \${X:=y}; printf '=' > \"\$D/probe\""
check block "repro4: a quoted \$'=' does not hide a live \${X:=y}, from a worktree" "$WT" \
  ": \${X:=y}; printf \$'=' > \"\$D/probe\""
check block "repro4: \${X:='a'} is live (its value is quoted, the expansion is not), from a worktree" "$WT" \
  ": \${X:='a'}; printf x > \"\$D/probe\""
check block "repro4: \"\${X:=y}\" in double quotes is live, from a worktree" "$WT" \
  "printf '%s' \"\${X:=y}\" > \"\$D/probe\""
check block "repro4: an unquoted heredoc's \${X:=y} stays live, from a worktree" "$WT" \
  "cat <<EOF > \"\$D/x\"
\${X:=y}
EOF"

# Should-allow: quoted text is data; everyday commands.
check allow "repro4: <<'EOF' body with \${X:=y} and case, computed destination, from a worktree" "$WT" \
  "cat <<'EOF' > \"\$TMPDIR/ewb-x\"
x=\${X:=y}
case \$1 in a) f;; esac
EOF"
check allow "repro4: <<\"EOF\" body with \${X:=y} and a function, ~ destination, from a worktree" "$WT" \
  "cat <<\"EOF\" > ~/.cache/ewb-x.sh
f() { echo \${X:=y}; }
EOF"
check allow "repro4: <<\\EOF body with \${X:=y}, computed destination, from a worktree" "$WT" \
  "cat <<\\EOF > \"\$TMPDIR/ewb-x\"
\${X:=y} \$(touch nothing)
EOF"
check allow "repro4: '\${X:=y}' single-quoted, computed destination, from a worktree" "$WT" \
  "printf '%s\\n' '\${X:=y}' > \"\$TMPDIR/ewb-x\""
check allow "repro4: jq 'select(…)', computed destination, from a worktree" "$WT" \
  "jq '.[] | select(.draft)' $SCRATCH/in.json > \"\$TMPDIR/ewb-o.json\""
check allow "repro4: printf '<!-- … -->' to /tmp, from main" "$MAIN" \
  "printf '%s' '<!-- a --> b' > /tmp/ewb-o.html"
check allow "repro4: <<'EOF' defining a function, computed destination, from a worktree" "$WT" \
  "cat <<'EOF' > \"\$TMPDIR/ewb-f.sh\"
f() { select x in a; do :; done; }
EOF"
check allow "repro4: a decodable \$'…' payload writing to /tmp, from main" "$MAIN" \
  "bash -c \$'printf x\\\\n > /tmp/ewb-ok2'"
check allow "repro4: printf > \$'\\x2ftmp…', from a worktree" "$WT" \
  "printf x > \$'\\x2ftmp\\x2fewb-ok3'"
check allow "repro4: git worktree add, from main" "$MAIN" \
  "git worktree add .worktrees/x -b x origin/main"
check allow "repro4: bin/estate-wt new, from main" "$MAIN" \
  "bin/estate-wt new x"
check allow "repro4: git fetch, from main" "$MAIN" \
  "git fetch"
check allow "repro4: git pull --ff-only, from main" "$MAIN" \
  "git pull --ff-only"
check allow "repro4: printf > /tmp, from main" "$MAIN" \
  "printf x > /tmp/ok.txt"
check block "repro4: git worktree add && cd into it && touch: judged like a redirection there (accepted)" "$MAIN" \
  "git worktree add .worktrees/n -b n origin/main && cd .worktrees/n && touch f"
check allow "repro4: mkdir -p scratch/new && cd && touch, from main" "$MAIN" \
  "mkdir -p $SCRATCH/n2 && cd $SCRATCH/n2 && touch f"
check allow "repro4: cd scratch; mkdir / rm / chmod there, from main" "$MAIN" \
  "cd $SCRATCH; mkdir -p d; rm -f d/x; chmod 644 in.txt; touch t"
check allow "repro4: touch / mkdir / rm relative, from a worktree" "$WT" \
  "touch a.txt; mkdir -p d; rm -f a.txt"

echo
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" == "0" ]] || exit 1
exit 0
