#!/usr/bin/env bash
# Resolver cases for hooks/pre-push-prepare.sh, ported from
# sidekick-labs/sidekick-harness .claude/hooks/lib/resolve-push-root.test.sh
# (ai-foundations-brain#745; deleted there in sidekick-harness#1434). The
# canonical hook inlines the resolver (estate hooks are vendored as single
# files), so the functions are sourced out of it.
#
# Every case below maps to a way a pre-push gate inspected a tree other than
# the one being pushed.
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pre-push-prepare.sh"
# shellcheck disable=SC1090
source <(sed -n '/^GIT_PUSH_RE=/,/^# push_root_in_scope/p' "$HOOK")

# Real repos, under $HOME so the tilde case applies; isolated git config.
mkdir -p "${HOME}/.cache"
BASE="$(mktemp -d "${HOME}/.cache/rpr-test.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
BASE="$(cd "$BASE" && pwd -P)" || exit 1
# Never let cleanup touch anything but the directory created above: an empty or
# unexpected BASE (mktemp failing on a runner without ~/.cache) once resolved to
# the checkout itself, and the trap deleted it.
[[ -d "$BASE" && "$(basename "$BASE")" == rpr-test.* ]] || { echo "refusing: unexpected BASE '$BASE'" >&2; exit 1; }
trap 'rm -rf -- "$BASE"' EXIT
printf '[user]\n\tname = T\n\temail = t@example.com\n' > "$BASE/gitconfig"
export GIT_CONFIG_GLOBAL="$BASE/gitconfig" GIT_CONFIG_NOSYSTEM=1
git init -q "$BASE/repo" && git init -q "$BASE/other"
REPO_ROOT="$BASE/repo"
MAIN_ROOT="$BASE/other"

pass=0
fail=0

# Cases with a `{}` payload deliberately exercise the no-cwd fallback, which
# warns on stderr by design. Silence it here so real failures stand out.
rpr() { resolve_push_root "$@" 2>/dev/null; }
# <desc> <command> <payload> [hook-HOME]: resolution must fail (the hook then skips)
fails() {
  local out
  if out=$(HOME="${4:-$HOME}" resolve_push_root "$2" "$3" 2>/dev/null); then
    fail=$((fail + 1)); printf 'FAIL %s\n       expected: non-zero\n       actual:   %s\n' "$1" "$out"
  else
    pass=$((pass + 1)); printf 'ok   %s\n' "$1"
  fi
}

check() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$1"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
  fi
}

# Run every case from a cwd that is NOT a git checkout, so a bug that falls
# back to the hook process's own directory can never accidentally pass.
cd / || exit 1

R="$REPO_ROOT"
OTHER="$MAIN_ROOT"

# --- the push segment's own `git -C` -----------------------------------
check "git -C bare path" "$R" "$(rpr "git -C $R push origin topic" '{}')"
check "git -C double-quoted" "$R" "$(rpr "git -C \"$R\" push" '{}')"
check "git -C single-quoted" "$R" "$(rpr "git -C '$R' push" '{}')"

# --- `cd` before the push ----------------------------------------------
check "cd && push" "$R" "$(rpr "cd $R && git push" '{}')"
check "cd quoted && push" "$R" "$(rpr "cd \"$R\" && git push" '{}')"
check "last cd before push wins" "$R" "$(rpr "cd /tmp; cd $R && git push" '{}')"
# The repo lives under $HOME in every dev setup here; if it ever doesn't,
# skip rather than assert something untrue of the environment.
if [[ "$R" == "$HOME"/* ]]; then
  check "tilde cd expands" "$R" "$(rpr "cd ~${R#"$HOME"} && git push" '{}')"
else
  printf 'skip repo not under \$HOME; tilde case not applicable\n'
fi

# --- session cwd from the hook payload ---------------------------------
check "payload .cwd" "$R" "$(resolve_push_root "git push" "{\"cwd\":\"$R\"}")"
check "payload .context.cwd" "$R" "$(resolve_push_root "git push" "{\"context\":{\"cwd\":\"$R\"}}")"

# --- cases that previously selected the WRONG checkout ------------------
# An unrelated `git -C` elsewhere in a compound command must not win: doing
# so pointed the gate at another repo and skipped validation entirely.
check "unrelated git -C ignored" "$R" \
  "$(resolve_push_root "git -C $OTHER log -1 && git push" "{\"cwd\":\"$R\"}")"
# A `cd` after the push is not where the push ran.
check "cd after push ignored" "$R" \
  "$(rpr "cd $R && git push && cd $OTHER" '{}')"
# `cd -` is the interactive shell's OLDPWD, unknowable here; resolving it
# landed on the hook's own cwd (the main checkout) — the original bug.
fails "cd - before push does not fall back to payload cwd" \
  "cd - && git push" "{\"cwd\":\"$R\"}"
# Mixed quoting across segments: the push segment's -C must win.
check "per-segment -C, push segment wins" "$R" \
  "$(rpr "git -C \"$OTHER\" status && git -C $R push" '{}')"
# Relative paths resolve against the session cwd, not the hook's cwd.
check "relative cd vs session cwd" "$R" \
  "$(resolve_push_root "cd . && git push" "{\"cwd\":\"$R\"}")"
# A runtime variable (`cd "$WORKTREE"`) is unknowable here; falling back to
# the payload cwd checked a different checkout than the one pushed (review
# finding). Resolution fails, so the hook skips; it never blocks the push.
fails "unexpanded \$VAR does not fall back to payload cwd" \
  'cd $NOT_SET_HERE && git push' "{\"cwd\":\"$R\"}"
fails "quoted runtime \$VAR does not fall back" \
  'cd "$WORKTREE" && git push' "{\"cwd\":\"$R\"}"
# A literal missing dir: bash's cd fails and the shell stays put, so the
# push still runs in the (known) previous directory.
check "failed literal cd keeps the directory (;)" "$R" \
  "$(resolve_push_root "cd /no/such/dir; git push" "{\"cwd\":\"$R\"}")"
# ...but across `||` which side ran is not knowable, so any cd there skips
# (agent-estate#20; this case resolved $R before).
fails "cd on the left of || before the push skips" \
  "cd /no/such/dir || git push" "{\"cwd\":\"$R\"}"
check "failed literal cd then relative cd composes from kept dir" "$R" \
  "$(resolve_push_root "cd /no/such/dir; cd $(basename "$R"); git push" "{\"cwd\":\"$BASE\"}")"
# A cd to a non-checkout: git would fail there, so do not fall back either.
fails "cd to a non-checkout does not fall back" \
  "cd $BASE && git push" "{\"cwd\":\"$R\"}"

# --- review findings on the rollout (2026-09-25) ------------------------
# A COMMIT whose message contains the word "push" is not the push segment.
check "commit message mentioning push is not the push" "$R" \
  "$(rpr "cd $OTHER && git commit -m 'fix push flow' && cd $R && git push" '{}')"
# A relative -C resolves against the preceding cd, not the session cwd.
check "relative -C after cd resolves against the cd" "$R" \
  "$(rpr "cd $(dirname "$R") && git -C $(basename "$R") push" '{}')"

# --- review findings on the re-vendor (standard_circuit#92) --------------
# Chained cds compose: `cd .. && cd <sibling>` lands in ../<sibling>, not
# cwd/<sibling> (which fell back to the session cwd — the wrong worktree).
mkdir -p "$BASE/wt/task-a"
check "chained cd composes (cd .. && cd sibling)" "$R" \
  "$(resolve_push_root "cd .. && cd $(basename "$R") && git push" "{\"cwd\":\"$OTHER\"}")"
check "chained cd from a non-repo dir" "$R" \
  "$(resolve_push_root "cd ../.. && cd $(basename "$R") && git push" "{\"cwd\":\"$BASE/wt/task-a\"}")"
# A relative cd after an unresolvable one stays unknown -> session cwd.
fails "relative cd after cd - stays unknown" \
  "cd - && cd other && git push" "{\"cwd\":\"$R\"}"
# ...but an absolute cd re-anchors.
check "absolute cd after cd - re-anchors" "$R" \
  "$(resolve_push_root "cd - && cd $R && git push" "{\"cwd\":\"$OTHER\"}")"
# A relative -C after chained cds resolves against the composed directory.
check "relative -C after chained cds" "$R" \
  "$(resolve_push_root "cd $BASE/wt && cd .. && git -C $(basename "$R") push" "{\"cwd\":\"$OTHER\"}")"
# A cd in a pipeline stage runs in a subshell and does not move the shell.
check "pipeline-local cd is ignored" "$R" \
  "$(resolve_push_root "cd $OTHER | cat; cd $(basename "$R") && git push" "{\"cwd\":\"$BASE\"}")"
check "cd before || still composes" "$R" \
  "$(resolve_push_root "cd $BASE || exit 1; cd $(basename "$R") && git push" "{\"cwd\":\"$OTHER\"}")"
# An explicit -C that does not resolve must not fall back to another checkout.
if resolve_push_root "git -C $BASE/no-such-dir push" "{\"cwd\":\"$R\"}" >/dev/null 2>&1; then
  fail=$((fail + 1))
  printf 'FAIL invalid -C should not fall back\n'
else
  pass=$((pass + 1))
  printf 'ok   invalid -C returns non-zero (no fallback)\n'
fi

# --- review findings on the 3dd9736 re-vendor (agent-estate#20) --------
# Every case here resolved a checkout on 3dd9736; the push runs elsewhere, or
# its directory is not knowable, so resolution must fail (the hook skips).
mkdir -p "$BASE/nonrepo"
P_BASE="{\"cwd\":\"$BASE\"}"
P_OTHER="{\"cwd\":\"$OTHER\"}"
P_R="{\"cwd\":\"$R\"}"
# 1. a relative -C after an unknown cd resolved against the session cwd
fails "relative -C after an unknown cd" \
  'cd "$WORKTREE" && git -C repo push' "$P_BASE"
check "absolute -C after an unknown cd still resolves" "$R" \
  "$(resolve_push_root "cd \"\$WORKTREE\" && git -C $R push" "$P_OTHER")"
fails "relative -C with ~user" 'git -C ~nosuchuser_rpr/x push' "$P_R"
fails "two -C flags are not composed" "git -C $BASE -C repo push" "$P_OTHER"
# 2. `||` and `&&`: which steps ran
fails "cd a || cd b: either could be where the push runs" \
  "cd $R || cd $OTHER; git push" "$P_BASE"
fails "cd a && cd typo && push: the push never runs" \
  "cd $R && cd no-such-typo && git push" "$P_OTHER"
fails "a cd after a command of unknown status may not have run" \
  "make test && cd $R; git push" "$P_OTHER"
check "a failed cd ends its && list: the cd after it never runs" "$OTHER" \
  "$(resolve_push_root "cd /no/such/dir && cd $R; git push" "$P_OTHER")"
fails "a missing dir an earlier command could create is unknown" \
  "git worktree add $BASE/new-wt; cd $BASE/new-wt; git push" "$P_R"
check "|| after the push does not matter" "$R" \
  "$(resolve_push_root "cd $R && git push || echo failed" "$P_OTHER")"
check "cd <dir> || exit keeps <dir>" "$R" \
  "$(resolve_push_root "cd $R || exit 1; git push" "$P_OTHER")"
fails "cd <missing> || exit: the push never runs from a known dir" \
  "cd /no/such/dir || exit 1; git push" "$P_R"
fails "exit before the push" "exit 1; git push" "$P_R"
check "a backgrounded cd moves nothing" "$R" \
  "$(resolve_push_root "cd $OTHER & git push" "$P_R")"
fails "a subshell with a cd is not modelled" \
  "(cd $R; git push origin topic)" "$P_OTHER"
fails "(cd x); push is not modelled" "(cd $R); git push" "$P_OTHER"
fails "a cd inside if/then is not modelled" \
  "if cd $R; then git push; fi" "$P_OTHER"
fails "a cd inside a loop body is not modelled" \
  $'while false; do\ncd '"$R"$'\ndone; git push' "$P_OTHER"
fails "pushd is not followed" "pushd $R && git push" "$P_OTHER"
fails "eval may cd" "eval \"cd $R\"; git push" "$P_OTHER"
fails "source may cd" "source ./env.sh && git push" "$P_OTHER"
fails ". may cd" ". ./env.sh; git push" "$P_OTHER"
check "./script is not ." "$R" "$(resolve_push_root "./bin/x && git push" "$P_R")"
# the operand must come first; redirections may only follow it (Codex on #21)
# (HOME is a checkout here, so reading it as a bare cd would resolve)
if HOME="$OTHER" resolve_push_root "cd >/dev/null . && git push" "$P_R" >/dev/null 2>&1; then
  fail=$((fail + 1)); printf 'FAIL a redirection before the operand is not a bare cd\n'
else
  pass=$((pass + 1)); printf 'ok   a redirection before the operand is not a bare cd\n'
fi
fails "an fd-numbered redirection is not the operand" \
  "cd 2>/dev/null && git push" "$P_R"
fails "extra operands (bash: too many arguments)" "cd $R $OTHER && git push" "$P_OTHER"
check "redirections after the operand are fine" "$R" \
  "$(resolve_push_root "cd $R >/dev/null 2>&1 && git push" "$P_OTHER")"
check "bare cd with only a redirection is \$HOME" "$R" \
  "$(HOME="$R" resolve_push_root "cd >/dev/null && git push" "$P_OTHER")"
# escaped whitespace/operators are word characters (Codex on #21)
check "\\<space># is a word, not a comment: the cd runs" "$OTHER" \
  "$(resolve_push_root $'true \\ #not-a-comment; cd '"$OTHER"$'\ngit push' "$P_R")"
check "\\>& is a background &, not a redirection: the cd after it runs" "$OTHER" \
  "$(resolve_push_root "echo \\>& cd $OTHER; git push" "$P_R")"
check "bare cd goes to \$HOME" "$R" \
  "$(HOME="$R" resolve_push_root "cd && git push" "$P_OTHER")"
# 3. expansions that only exist at run time
fails "bracket glob target" "cd $BASE/rep[o] && git push" "$P_OTHER"
fails "brace expansion target" "cd $BASE/{repo,x} && git push" "$P_OTHER"
fails "~user target" "cd ~nosuchuser_rpr && git push" "$P_R"
fails "cd with an option" "cd -P $R && git push" "$P_OTHER"
mkdir -p "$BASE/tilde" && git init -q "$BASE/tilde/~"
check "quoted ~ is a literal directory name, not \$HOME" "$BASE/tilde/~" \
  "$(HOME="$R" resolve_push_root "cd \"~\" && git push" "{\"cwd\":\"$BASE/tilde\"}")"
# in "…" a backslash before an ordinary character is kept (Codex on #21)
mkdir -p "$BASE/bs" && git init -q "$BASE/bs/\\q" && git init -q "$BASE/bs/q"
check "double-quoted \\q keeps its backslash" "$BASE/bs/\\q" \
  "$(resolve_push_root "cd \"$BASE/bs/\\q\" && git push" "$P_OTHER")"
# an attached &> ends the word (Codex on #21)
git init -q "$BASE/amp&"
check "cd dir&>/dev/null is dir, not dir&" "$R" \
  "$(resolve_push_root "cd $R&>/dev/null && git push" "$P_OTHER")"
check "cd dir&>>log is dir" "$R" \
  "$(resolve_push_root "cd $BASE/repo&>>/dev/null && git push" "$P_OTHER")"
check "cd amp&>/dev/null targets amp (missing: skip), never amp&" "" \
  "$(resolve_push_root "cd $BASE/amp&>/dev/null && git push" "$P_OTHER" 2>/dev/null)"
# 4. quoted or escaped separators are not separators
check "quoted | in a redirection is not a pipe" "$R" \
  "$(resolve_push_root "cd $R 2>\"/tmp/a|b\" && git push" "$P_OTHER")"
check "escaped | is not a pipe" "$R" \
  "$(resolve_push_root "cd $R 2>/tmp/a\\|b && git push" "$P_OTHER")"
check "2>&1 is not a background &" "$R" \
  "$(resolve_push_root "cd $R 2>&1 && git push" "$P_OTHER")"
# 6. phantom cds and pushes inside quoted text, heredocs and substitutions
check "a cd inside a commit message is not a cd" "$R" \
  "$(resolve_push_root "git commit -m \"x; cd $OTHER now\" && git push" "$P_R")"
check "\"git push\" inside a commit message is not the push" "$R" \
  "$(resolve_push_root "git commit -m \"run git push later\" && cd $R && git push" "$P_OTHER")"
check "a heredoc body is not commands" "$R" \
  "$(resolve_push_root $'git commit -F - <<\'EOF\'\ncd '"$OTHER"$'\nEOF\ngit push' "$P_R")"
check "heredoc in \$(…) with an apostrophe" "$R" \
  "$(resolve_push_root $'git commit -m "$(cat <<\'EOF\'\nIt\'s; cd '"$OTHER"$'\nEOF\n)" && git push' "$P_R")"
check "<<- strips leading tabs from the delimiter line" "$R" \
  "$(resolve_push_root $'cat <<-EOF\n\tcd '"$OTHER"$'\n\tEOF\ngit push' "$P_R")"
fails "plain << does not: a tab-indented EOF is body, so no push is seen" \
  $'cat <<EOF\n\tEOF\ngit push' "$P_R"
check "\${…} holding ; and # is one word" "$R" \
  "$(resolve_push_root 'echo ${X:-a; cd /}; git push' "$P_R")"
fails "GIT_DIR= points the push elsewhere" "GIT_DIR=$OTHER/.git git push" "$P_R"
fails "quoted export \"GIT_DIR=…\"" "export \"GIT_DIR=$OTHER/.git\"; git push" "$P_R"
fails "env 'GIT_WORK_TREE=…' git push" "env 'GIT_WORK_TREE=$OTHER' git push" "$P_R"
fails "export GIT_WORK_TREE= before the push" "export GIT_WORK_TREE=$OTHER; git push" "$P_R"
check "a comment is not commands" "$R" \
  "$(resolve_push_root $'# cd '"$OTHER"$'\ngit push' "$P_R")"
check "line continuation after &&" "$R" \
  "$(resolve_push_root $'cd '"$R"$' &&\n  git push' "$P_OTHER")"
fails "no real push segment" 'git commit -m "then git push"' "$P_R"
fails "unterminated quote" "cd $R && git push \"oops" "$P_OTHER"

# --- agent-estate#23: residual gaps from the 071da7f re-vendor reviews ---
# 1. inside "…", ${…} nests: its own quotes do not close the outer string
check "\"\${x:-\"…\"}\": the inner quotes are data, not commands" "$R" \
  "$(resolve_push_root "echo \"\${x:-\"; cd $OTHER;\"}\"; git push" "$P_R")"
check "\"\${x:-'}'}\": a quoted } does not close the expansion" "$R" \
  "$(resolve_push_root "echo \"\${x:-'}'}\"; git push" "$P_R")"
check "\"\${x}\" closes, so a following cd still applies" "$R" \
  "$(resolve_push_root "echo \"\${x}\"; cd $R && git push" "$P_OTHER")"
# 2. only a `.` in command position is the source builtin
check "git add . && git push" "$R" "$(resolve_push_root "git add . && git push" "$P_R")"
check "docker build . ; git push" "$R" "$(resolve_push_root "docker build . ; git push" "$P_R")"
fails ". ./env.sh may cd invisibly" ". ./env.sh; git push" "$P_R"
fails "FOO=1 . ./env.sh may cd invisibly" "FOO=1 . ./env.sh; git push" "$P_R"
fails "if . ./env.sh; then … may cd invisibly" "if . ./env.sh; then :; fi; git push" "$P_R"
fails "2>/dev/null . ./env.sh: a redirection before . keeps it in command position" "2>/dev/null . ./env.sh; git push" "$P_R"
fails ">log . ./env.sh" ">log . ./env.sh; git push" "$P_R"
fails "FOO+=1 . ./env.sh: an additive assignment keeps . in command position" "FOO+=1 . ./env.sh; git push" "$P_R"
fails "arr[0]=x . ./env.sh" "arr[0]=x . ./env.sh; git push" "$P_R"
fails "command -p . ./env.sh: options on a prefix keep . in command position" "command -p . ./env.sh; git push" "$P_R"
fails "time -p . ./env.sh" "time -p . ./env.sh; git push" "$P_R"
check "git add -A . (an option before .) is not a dot command" "$R" "$(resolve_push_root "git add -A . && git push" "$P_R")"
fails "2> /dev/null . ./env.sh (spaced target)" "2> /dev/null . ./env.sh; git push" "$P_R"
# 4. a bare cd (or ~) after the command changes HOME is unknown: the hook's own
#    $HOME is stale. The hook's HOME is set to a checkout so a stale value resolves.
check "bare cd is the hook's \$HOME when nothing changed it" "$R" \
  "$(HOME="$R" rpr "cd && git push" "$P_OTHER")"
check "reading \$HOME is not changing it" "$R" \
  "$(HOME="$R" rpr "echo \$HOME \${HOME}; cd && git push" "$P_OTHER")"
fails "HOME=…; cd; git push" "HOME=$OTHER; cd; git push" "$P_OTHER" "$R"
fails "unset HOME; cd" "unset HOME; cd; git push" "$P_OTHER" "$R"
fails "export \"HOME=…\" && cd ~" "export \"HOME=$OTHER\" && cd ~ && git push" "$P_OTHER" "$R"
fails "HOME=… then git -C ~ push" "HOME=$OTHER; git -C ~ push" "$P_OTHER" "$R"
# 5. inside $( … ), # at the start of a word is a comment, so its ) closes nothing
check "# inside \$(…) comments out a )" "$R" \
  "$(resolve_push_root $'x=$(echo a # ) cd '"$OTHER"$'\n); git push' "$P_R")"
check "an escaped space before # inside \$(…) is not a comment" "$R" \
  "$(resolve_push_root "x=\$(echo \\ #); cd $R && git push" "$P_OTHER")"
check "an escaped backslash then a space: # is a comment again" "$R" \
  "$(resolve_push_root $'x=$(echo \\\\ # ) cd '"$OTHER"$'\n); git push' "$P_R")"
check "\$# inside \$(…) is not a comment" "$R" \
  "$(resolve_push_root "x=\$(echo \$#); cd $R && git push" "$P_OTHER")"

# 3. --force-with-lease goes into the lexed push segment, not the first textual match
check "lease: plain push" "git push --force-with-lease origin topic" \
  "$(_rpr_lease_command "git push origin topic")"
check "lease: an unquoted echo of git push earlier is left alone" \
  "echo git push; git push --force-with-lease origin feature" \
  "$(_rpr_lease_command "echo git push; git push origin feature")"
check "lease: an assignment prefix before git push" \
  "GIT_TRACE=1 git push --force-with-lease" \
  "$(_rpr_lease_command "GIT_TRACE=1 git push")"
check "lease: a redirection before git push" \
  "2>/tmp/push.err git push --force-with-lease origin topic" \
  "$(_rpr_lease_command "2>/tmp/push.err git push origin topic")"
check "lease: command -p git push" \
  "command -p git push --force-with-lease" \
  "$(_rpr_lease_command "command -p git push")"
check "lease: env -i git push" \
  "env -i git push --force-with-lease" \
  "$(_rpr_lease_command "env -i git push")"
check "lease: env -u NAME git push" "env -u HOME git push --force-with-lease" "$(_rpr_lease_command "env -u HOME git push")"
check "lease: nice -n 10 git push" "nice -n 10 git push --force-with-lease" "$(_rpr_lease_command "nice -n 10 git push")"
check "lease: exec -a alias git push" "exec -a alias git push --force-with-lease" "$(_rpr_lease_command "exec -a alias git push")"
check "lease: a negated push" "! git push --force-with-lease origin topic" "$(_rpr_lease_command "! git push origin topic")"
fails "env -C <dir> git push changes directory: unknown, so the hook skips" "env -C $OTHER git push" "$P_R"
fails "env --chdir <dir> git push" "env --chdir $OTHER git push" "$P_R"
fails "env -S \"…\" git push re-parses the command" "env -S \"x\" git push" "$P_R"
check "resolver: env -i git push is still the push" "$R" "$(resolve_push_root "env -i git push" "$P_R")"
check "resolver: env -- git push is the push" "$R" "$(resolve_push_root "env -- git push" "$P_R")"
fails "env -iC<dir> (clustered chdir) git push" "env -iC$OTHER git push" "$P_R"
fails "env -iS… (clustered split-string) git push" "env -iSx git push" "$P_R"
check "resolver: env -i0 git push (cluster without C/S) is the push" "$R" "$(resolve_push_root "env -i0 git push" "$P_R")"
check "resolver: env -uHOME git push (attached operand) is the push" "$R" "$(resolve_push_root "env -uHOME git push" "$P_R")"
check "resolver: env -iuHOME git push is the push" "$R" "$(resolve_push_root "env -iuHOME git push" "$P_R")"
check "resolver: env - git push is the push" "$R" "$(resolve_push_root "env - git push" "$P_R")"
fails "env --chdir <dir> still rejected after the separator change" "env -- --chdir $OTHER git push" "$P_R"
check "resolver: env --unset=HOME git push is the push" "$R" "$(resolve_push_root "env --unset=HOME git push" "$P_R")"
check "lease: env --unset=HOME git push" "env --unset=HOME git push --force-with-lease" "$(_rpr_lease_command "env --unset=HOME git push")"
fails "env --chdir=<dir> git push" "env --chdir=$OTHER git push" "$P_R"
check "resolver: an unquoted echo of git push before a cd is not the push" "$R" \
  "$(resolve_push_root "echo git push; cd $R && git push" "$P_OTHER")"
check "lease: an earlier git command with push in its arguments is left alone" \
  "git add git push; git push --force-with-lease origin topic" \
  "$(_rpr_lease_command "git add git push; git push origin topic")"
check "lease: a multibyte character earlier on the line (UTF-8 locale)" \
  "echo é; git push --force-with-lease origin topic" \
  "$(LC_ALL=C.UTF-8 _rpr_lease_command "echo é; git push origin topic")"
check "lease: git -C <dir> push" "git -C \"$R\" push --force-with-lease" \
  "$(_rpr_lease_command "git -C \"$R\" push")"
check "lease: an echoed \"git push\" earlier on the line is left alone" \
  "echo \"git push origin\"; cd $R && git push --force-with-lease origin topic" \
  "$(_rpr_lease_command "echo \"git push origin\"; cd $R && git push origin topic")"
check "lease: a commit message mentioning git push is left alone" \
  "git commit -m \"run git push later\" && git push --force-with-lease" \
  "$(_rpr_lease_command "git commit -m \"run git push later\" && git push")"
check "lease: a quoted env prefix mentioning git push is left alone" \
  "MSG=\"git push x\" git push --force-with-lease" \
  "$(_rpr_lease_command "MSG=\"git push x\" git push")"
check "lease: a heredoc body before the push is left alone" \
  $'cat <<EOF\ngit push x\nEOF\ngit push --force-with-lease' \
  "$(_rpr_lease_command $'cat <<EOF\ngit push x\nEOF\ngit push')"
check "lease: a line continuation inside the push segment" \
  $'echo "git push"; git \\\n  push --force-with-lease origin' \
  "$(_rpr_lease_command $'echo "git push"; git \\\n  push origin')"
check "lease: a push at the end of the line" "cd $R; git push --force-with-lease" \
  "$(_rpr_lease_command "cd $R; git push")"
check "lease: gh pr create before the push" "gh pr create --fill && git push --force-with-lease" \
  "$(_rpr_lease_command "gh pr create --fill && git push")"
fails_lease() { # <desc> <command>: no push segment, so nothing is edited
  if out=$(_rpr_lease_command "$2"); then
    fail=$((fail + 1)); printf 'FAIL %s\n       expected: non-zero\n       actual:   %s\n' "$1" "$out"
  else
    pass=$((pass + 1)); printf 'ok   %s\n' "$1"
  fi
}
fails_lease "lease: only a quoted git push" 'git commit -m "then git push"'
fails_lease "lease: unterminated quote" 'git push "oops'

# --- gh pr create is also a push-shaped target (prepare hook) -----------
check "gh pr create segment" "$R" \
  "$(rpr "cd $R && gh pr create --fill" '{}')"

# --- failure signalling -------------------------------------------------
if resolve_push_root "git push" '{"cwd":"/"}' >/dev/null 2>&1; then
  fail=$((fail + 1))
  printf 'FAIL non-repo cwd should not resolve\n'
else
  pass=$((pass + 1))
  printf 'ok   non-repo cwd returns non-zero\n'
fi

# --- the push matcher ---------------------------------------------------
matches() { [[ "$1" =~ $GIT_PUSH_RE ]] && echo yes || echo no; }
check "matcher: git push" "yes" "$(matches 'git push')"
check "matcher: git -C <dir> push" "yes" "$(matches 'git -C /x/y push')"
check "matcher: cd && git push" "yes" "$(matches 'cd /x && git push')"
check "matcher: git pushx" "no" "$(matches 'git pushx')"
check "matcher: mygit push" "no" "$(matches 'mygit push')"
check "matcher: git commit -m push" "no" "$(matches 'git commit -m push')"
check "matcher: git -C /x log" "no" "$(matches 'git -C /x log')"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
