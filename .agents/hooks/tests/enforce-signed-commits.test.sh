#!/bin/bash
# Test harness for hooks/enforce-signed-commits.sh
#
# Feeds the hook PreToolUse payloads and asserts: plain commits get -S injected
# (via updatedInput), signing bypasses are BLOCKED (exit 2), and everything that
# isn't a commit passes through untouched.
#
# Usage: hooks/tests/enforce-signed-commits.test.sh
set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/enforce-signed-commits.sh"
[[ -x "$HOOK" ]] || { echo "hook not executable: $HOOK" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required to run these tests" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/esc-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# A signing key must be configured for the hook to inject -S; give it one in an
# isolated global config so the developer's own git config never leaks in.
printf '[user]\n\tsigningkey = %s/key.pub\n[gpg]\n\tformat = ssh\n' "$TMP" > "$TMP/gitconfig"

PASS=0
FAIL=0
OUT=""
CODE=0

run() { # run <command>  -> CODE, OUT (stdout)
  local payload
  payload=$(jq -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}')
  OUT=$(printf '%s' "$payload" | env -u CI -u GITHUB_ACTIONS -u SKIP_SIGNED_COMMITS_HOOK \
        GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1 "$HOOK" 2>/dev/null)
  CODE=$?
}

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }

signs() { # signs <label> <command> <expected rewritten command>
  run "$2"
  local got
  got=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null)
  if [[ "$CODE" == 0 && "$got" == "$3" ]]; then ok "$1"; else bad "$1" "exit $CODE, got: ${got:-<no rewrite>}"; fi
}

blocks() { # blocks <label> <command>
  run "$2"
  if [[ "$CODE" == 2 ]]; then ok "$1"; else bad "$1" "exit $CODE (wanted 2)"; fi
}

passes() { # passes <label> <command>   (exit 0, no rewrite)
  run "$2"
  if [[ "$CODE" == 0 && -z "$OUT" ]]; then ok "$1"; else bad "$1" "exit $CODE, out: $OUT"; fi
}

echo "enforce-signed-commits.sh"

signs  "plain commit gets -S"            'git commit -m "x"'            'git commit -S -m "x"'
signs  "amend gets -S"                   'git commit --amend --no-edit' 'git commit -S --amend --no-edit'
signs  "commit after && gets -S"         'git add -A && git commit -m y' 'git add -A && git commit -S -m y'
signs  "git -C DIR commit gets -S"       'git -C /r commit -m z'        'git -C /r commit -S -m z'
signs  "git -c key=val commit gets -S"   'git -c core.editor=true commit' 'git -c core.editor=true commit -S'

blocks "--no-gpg-sign is blocked"                     'git commit --no-gpg-sign -m x'
blocks "-c commit.gpgsign=false is blocked"           'git -c commit.gpgsign=false commit -m x'
blocks "-c commit.gpgsign=0 is blocked"               'git -c commit.gpgsign=0 commit -m x'
blocks "-c commit.gpgSign=no (any case) is blocked"   'git -c commit.gpgSign=no commit -m x'
blocks "--no-gpg-sign after && is blocked"            'git add . && git commit --no-gpg-sign'

# review findings, rounds 2-3 (2026-09-25): a text scan errs toward BLOCKING.
# Stripping "message text" opened bypasses, so messages that MENTION a bypass flag
# are refused (the error says to rephrase), and none of these tricks gets through.
blocks "message that MENTIONS --no-gpg-sign is refused (rephrase)" 'git commit -m "block --no-gpg-sign and -c commit.gpgsign=false"'
blocks "heredoc message mentioning the flag is refused"  $'git commit -F - <<\'EOF\'\nblocks --no-gpg-sign\nEOF'
blocks "round 3: \$(cat <<EOF) wrapping a real flag"    $'git commit -m t $(cat <<EOF\n--no-gpg-sign\nEOF\n)'
blocks "round 3: multi-line -m then a real flag"         $'git commit -m "line one\nline two" --no-gpg-sign'
blocks "round 3: stray <<EOF in a quoted arg, flag after" $'git commit -m "see <<EOF" \\\n  --no-gpg-sign'
signs  "git --no-pager commit gets -S"             'git --no-pager commit -m x' 'git --no-pager commit -S -m x'
blocks "git --no-pager commit --no-gpg-sign"       'git --no-pager commit --no-gpg-sign -m x'
blocks "git --git-dir=.git commit --no-gpg-sign"   'git --git-dir=.git commit --no-gpg-sign'
blocks "quoted -c 'commit.gpgsign=false'"          "git -c 'commit.gpgsign=false' commit -m x"
blocks "GIT_CONFIG_KEY/VALUE env bypass"           'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false git commit -m x'
blocks "GIT_CONFIG_PARAMETERS env bypass"          "GIT_CONFIG_PARAMETERS=\"'commit.gpgsign'='false'\" git commit -m x"

# decision (d), 2026-09-25: only an EXPORTED SKIP_SIGNED_COMMITS_HOOK skips the hook;
# an inline prefix (which an agent can type) does not.
signs  "inline SKIP prefix no longer skips: still signed" 'SKIP_SIGNED_COMMITS_HOOK=1 git commit -m x' 'SKIP_SIGNED_COMMITS_HOOK=1 git commit -S -m x'
blocks "inline SKIP prefix can't carry a bypass flag"     'SKIP_SIGNED_COMMITS_HOOK=1 git commit --no-gpg-sign -m x'
blocks "double-quoted value: -c commit.gpgsign=\"false\""  'git -c commit.gpgsign="false" commit -m x'

passes "not a commit: git status"         'git status'
passes "not a commit: git commit-tree"    'git commit-tree HEAD^{tree}'
passes "a commit only mentioned in echo"  'echo "run git status"'

echo
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" == "0" ]] || exit 1
exit 0
