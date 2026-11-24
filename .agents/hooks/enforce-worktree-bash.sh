#!/bin/bash
# Enforce worktree-only file mutations for the Bash tool.
#
# Companion to enforce-worktree.sh (which covers Edit/Write/NotebookEdit).
# Runs on PreToolUse for Bash. Blocks tree-mutating Bash commands whose target
# is a MAIN checkout (not a worktree).
#
# This closes the documented gap where the editor hook is bypassed by writing
# the working tree through Bash — the vector that once scribbled 100+ stale
# files onto an app repo's main checkout (bin/devcontainer-exec rsyncing
# container state back onto it).
#
# Exit codes:
#   0 — allow (worktree, CI, non-git path, or not a tree-mutating command)
#   2 — block (tree-mutating command targeting a main checkout, or a command
#              this guard could not parse confidently while in a main checkout)
#
# ---------------------------------------------------------------------------
# HOW IT DECIDES (rewritten 2026-07-22)
#
# The old implementation substring-matched its trigger words against the whole
# command TEXT. That was wrong in both directions:
#   * it OVER-blocked prose — `gh issue create --body "…bin/devcontainer-exec…"`
#     writes nothing, but the tool's name appearing in the body tripped it;
#   * it UNDER-blocked real writes — `git -C <main> apply`, `> file`, `tee`,
#     `cp`/`mv` into a main checkout all sailed through.
# Both are the same root cause: it scanned text instead of understanding the
# command. This version lexes the command properly (POSIX-ish shell grammar:
# quoting, escapes, heredocs, command substitution, pipelines, redirections)
# and inspects the COMMAND NAME of each simple command, plus the destination
# paths of the commands that write files.
#
# What it blocks:
#   1. A content-introducing command whose working directory is a main checkout
#      — bin/devcontainer-exec, rsync, patch, sed -i / perl -i,
#        git stash pop|apply, git apply, git am, git cherry-pick, git revert.
#      The working directory is tracked across `cd`/`pushd` in the command, and
#      for git it is taken from `-C <path>` when present (the documented gap).
#   2. A write whose DESTINATION PATH lands inside a main checkout, no matter
#      where it is run from — shell redirections (`>`, `>>`), tee, cp, mv,
#      install, ln, rsync's destination, sed -i / perl -i's file arguments,
#      and (2026-11-25) touch, mkdir, rm, rmdir, unlink, truncate, shred,
#      chmod / chown / chgrp, dd of=, sort -o, curl -o / -O, wget. A relative
#      destination is resolved against the tracked working directory, exactly
#      like a redirection's (after cd / cd . / cd .. / cd - / pushd / popd,
#      and blocking after a cd it cannot resolve, rule 5).
#   3. Anything it cannot parse confidently while a main checkout is in play
#      (unterminated quote, unbalanced `$(`, unresolvable `~user`/`$VAR` cd
#      target). Fail closed: an over-block on an exotic command is much cheaper
#      than letting a real write through.
#   4. From a main checkout, any write destination bash computes (2026-11-23):
#      a word with $VAR / ${…} / $(…) / `…` / $((…)) / $'…' / $"…", brace
#      expansion, a glob, or a tilde form other than a plain ~ or ~/ prefix
#      blocks, whatever value the guard thinks it has. "From a main checkout"
#      means the hook's working directory, or the directory the line has cd'd
#      to (or may still be in), is one. A computed cd target there makes the
#      directory unknown, so later relative writes block. Literal paths are
#      resolved as before; worktrees and other directories keep the rules below.
#   5. After a directory change it cannot resolve, any relative write, wherever
#      the line runs (2026-11-23): a cd / pushd / popd whose directory is empty,
#      an option only, an unknown option, more than one word, a glob or brace
#      expansion, or built from any expansion makes the working directory
#      UNRESOLVED. A cd target is never resolved from the line's own bindings.
#      Relative writes and in-place commands then block, from a main checkout
#      or a worktree alike; absolute and ~ destinations are judged as usual. A
#      literal absolute cd settles it again. A cd that may not run (after && /
#      ||, inside if / while / until / for / select / case) may leave the shell
#      where it was. One before a `|` or `&` (a child shell) or after env /
#      sudo / … does not move this shell; one at the END of a pipeline may or
#      may not (lastpipe; zsh / ksh), so it leaves the directory unknown.
#   6. Anything that makes bash do something other than what this guard models,
#      while a main checkout is in play (2026-11-23): eval, readonly /
#      declare|typeset|local -r, trap 'CMD', alias, enable, set -r, shopt
#      cdable_vars, and function definitions. Function/alias/enable/set -r also
#      make the working directory unknown for the rest of the line, so relative
#      writes after them block anywhere.
#   7. Whatever the model above concluded, a structural backstop (2026-11-24,
#      see "structural backstop" below): a flat pass over the raw command that
#      shares none of the model's state. A literal destination of a redirection
#      or a write command (cp mv install ln tee touch mkdir rm truncate chmod
#      dd of= sed/perl -i rsync curl -o sort -o …) inside a main checkout
#      blocks from anywhere, and so does a relative one after cds it knows
#      certainly ran and succeeded (cd <main>; touch f). On a line with case /
#      esac, ${…=…}, eval, a shell reading stdin, coproc, select, a function
#      or an arithmetic assignment, a computed destination, or a relative one
#      after a cd it cannot follow, blocks from anywhere. Quoted text is data
#      for those constructs, except on a line that re-parses text (bash / sh,
#      eval, trap, alias, source of stdin), where every quoted string is code.
#   8. $'…' (2026-11-25) is decoded only where bash 3.2, bash 5 and zsh agree
#      (\a \b \e \f \n \r \t \v \\ \' \" \?, \xHH, octal up to \377).
#      \u / \U, \cX, unknown escapes (\q, \/), \x with no digit and NUL read
#      differently in one of them: in text the shell re-parses (bash -c / sh
#      -c / eval / trap / alias) such an escape blocks the whole line, wherever
#      it runs; the rest of the string is never dropped.
#
# Ambiguity is unresolved, and unresolved fails closed (2026-11-23):
#   * a `$` that was quoted ('$D', \$D, "\$D") is literal: the word is
#     unresolvable, never D's value. $'…' and $"…" strings are unresolvable too
#     (rule 4), but a decoded $'…' is judged by its literal value (rule 8);
#   * an unresolvable path whose literal start is inside a main checkout
#     (`<main>/$X`) blocks from anywhere;
#   * every reading of ${D:-w} / ${D=w} / ${D:+w} … is judged, and ${D:=w} /
#     ${D=w} assign D wherever they appear (arguments, redirections,
#     here-strings, unquoted heredoc bodies);
#   * values set by set --, printf -v, read <<< and for loops are judged;
#   * a quoted or escaped NAME ("D=x", 'D'=x, D\=x) is a command name, not an
#     assignment: D keeps its value (and is no longer trusted);
#   * declare / typeset / local -l -u -c -i -a -A transform what bash stores:
#     such a name is never bound and any use of it blocks;
#   * a value with whitespace or glob characters is never bound (an unquoted
#     $D splits or globs): each field is judged, and a glob value blocks;
#   * a cd whose target does not exist (and was not made by mkdir or git
#     worktree add on the line) may fail, leaving the shell where it was; so do
#     `cd -` and `popd` return there, and CDPATH is followed.
#
# What it deliberately does NOT block:
#   * pristine-RESTORING commands (git checkout HEAD -- ., git restore,
#     git clean) and branch switches — /cleanup and branch-switching flows need those on main;
#   * git commit / merge / pull / fetch — they introduce no foreign content
#     into the working tree, and /cleanup + /ship legitimately run them on main;
#   * reading anything, anywhere;
#   * a trigger word appearing inside a quoted argument, a heredoc body, a
#     commit message, or a filename — that is the bug this rewrite fixes.
#
# Known, accepted limits (documented rather than silently hoped away):
#   * an opaque command name (`$(which rsync) …`) is not resolved — but its
#     substitution IS analysed, and its destination paths are still checked;
#   * remote execution (`ssh host rsync …`) is out of scope;
#   * editors are not treated as writers; option values of touch / mkdir /
#     truncate … are skipped only for the options listed (a computed word of
#     theirs blocks from a main checkout, rule 4);
#   * values that only exist at run time (read from a file, $(…)) are
#     unresolvable: they block from a main checkout (rule 4), not elsewhere;
#   * aliases and functions inherited from the user's shell are not visible,
#     and CDPATH is read from this hook's environment.
#
# Requires bash 3.2 (macOS /bin/bash). No bash-4 features (no mapfile, no
# associative arrays, no ${arr[-1]}).
# ---------------------------------------------------------------------------

# --- input -----------------------------------------------------------------

# Skip in CI environments (the only sanctioned exception).
if [[ "${CI:-}" == "true" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  exit 0
fi

INPUT=$(cat)

DEGRADED=0
if command -v jq >/dev/null 2>&1; then
  TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""') || exit 2
  [[ "$TOOL_NAME" == "Bash" ]] || exit 0
  CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""') || exit 2
  [[ -z "$CMD" ]] && exit 0
else
  # jq is a setup prerequisite. If it is missing we cannot parse the payload,
  # so we degrade to the old, deliberately over-eager substring scan of the RAW
  # payload rather than failing open. The scan only knows the legacy trigger
  # commands (bin/devcontainer-exec, rsync, patch, sed/perl -i, git apply/am/
  # cherry-pick/revert/stash pop|apply): it over-blocks on those, but plain
  # redirections, tee, cp and mv are NOT caught until jq is back. It still lets
  # `brew install jq` through, so this is not a bootstrap deadlock.
  DEGRADED=1
  CMD="$INPUT"
fi

# --- small helpers ----------------------------------------------------------

# Out-parameters. Bash functions can only return an exit status, so helpers
# hand their result back through these:
#   RET      — the value (an expanded path, a selected argument)
#   RETUNRES — 1 when a path could not be resolved (unknown $VAR, ~otheruser)
#   RETCOUNT — how many candidates a selecting helper saw (_last_nonflag)
# Read them immediately after the call that sets them; the next call overwrites.
RET=""
RETUNRES=0
RETDANGER=0
RETCOUNT=0
RETP=""          # _dest_risk: the path it judged
RETWHY=""        # _dest_risk: why it judged it so (appended to block messages)
ALTS=()          # _alt_candidates: the readings of a word

# bash 5.2 makes `&` in a ${var//pat/rep} replacement mean "the match"; every
# replacement below means a literal string.
shopt -u patsub_replacement 2>/dev/null || true

# Placeholders the lexer leaves in a word where quoting decided what bash will
# do. Each contains a `$`, so any word holding one reads as unresolvable (fail
# closed) everywhere a path is judged. _script_text turns them back into shell
# text for eval / bash -c / trap / alias, which re-parse their argument.
LITD='${__literal_dollar__}'     # a `$` that was quoted or escaped: a literal $
QMARK='${__quoted_string__}'     # after a $'…' or $"…" string (decoded in full)
QLOST='${__undecoded_escape__}'  # a $'…' escape left undecoded; the rest of it is lost
QTILDE='${__quoted_tilde__}'     # before a quoted / escaped leading ~ ('~/x'): never tilde-expanded
BQ=0             # >0 while lexing inside backticks, where \$ is NOT literal

# The line does something this guard cannot follow (eval, readonly, a function
# definition, …): block when a main checkout is in play. Holds the reason.
UNMOD_WHY=""
POS_DANGER=0     # positional parameters ($1, $@, …) may hold a main-checkout path
FN_SEEN=0        # a function/alias/enable may have changed what cd and friends do
CDPATH_TAINT=0   # CDPATH is mentioned on this line: its value is not the inherited one
OLDPWD_TAINT=0   # OLDPWD is mentioned on this line: cd - may go anywhere
DIRSTK_TAINT=0   # DIRSTACK is mentioned on this line: popd may go anywhere
CREATED=()       # directories mkdir / git worktree add create on this line
HOME_TAINT=0     # HOME may change on this line: ~ and $HOME are not the inherited value
TILDE_SEEN=0     # a write landed on a ~ path, or relative to a cd ~ (re-judged at the end)
TILDE_CD=0       # the cwd still depends on a cd ~ / cd ~/… (saved and restored with it)
TILDE_CD_EVER=0  # a cd ~ ran on this line: cd - / popd may return to it (sticky)
ATTR_N=()        # names given a value-transforming attribute (declare -l, -u, -i, …)

_expand_path() { # $1 -> RET (expanded), RETUNRES=1 when it cannot be resolved
  local p="$1"
  RETUNRES=0
  RETDANGER=0
  if [[ "$p" == "$QTILDE"* ]]; then
    # A quoted leading ~ ('~/x'): a literal path component, never HOME.
    p="${p#"$QTILDE"}"
  else
    case "$p" in
      '~'|'~/'*)
        if _home; then p="$RET${p#\~}"; else RETUNRES=1; fi ;;
      '~'*) RETUNRES=1 ;;   # ~otheruser, ~+, ~- — cannot resolve
    esac
  fi
  case "$p" in *'$'*) _subst_vars "$p"; p="$RET" ;; esac
  case "$p" in *'$'*) RETUNRES=1 ;; esac
  RET="$p"
}

# What ~ and $HOME expand to: the inherited HOME. HOME is never bound
# (_var_set); an assignment that may point it into a main checkout makes it
# DANGER. HOME_TAINT does not change this reading (judging it keeps ~/<main>
# blocked from a worktree); it only makes ~ computed for rule 4 (_nonliteral).
_home() { # -> RET; return 1 when unknown (RETDANGER=1 when it may be a main path)
  if _var_is_danger HOME; then RETDANGER=1; return 1; fi
  RET="$HOME"
}

# A word whose value bash computes: any expansion, brace expansion, a glob, or
# a tilde form other than a plain ~ / ~/ prefix under an unchanged HOME. The
# lexer has dropped quoting, so a quoted '*' or '{' counts too (an accepted
# false positive); every quoted `$` is already a placeholder holding one.
_nonliteral() { # $1 lexed word -> 0 when bash computes its value
  case "$1" in
    *'$'*|*'`'*|*[{}*?[]*) return 0 ;;
    '~'|'~/'*)
      [[ "$HOME_TAINT" == "1" ]] && return 0
      _var_is_danger HOME && return 0
      return 1 ;;
    '~'*) return 0 ;;
  esac
  return 1
}

_main_in_play() { # -> 0 when the line starts, is, or may still be in a main checkout
  _dir_is_main "$CURDIR" || _dir_is_main "$PWD" || { [[ -n "$DIR_ALT" ]] && _dir_is_main "$DIR_ALT"; }
}

_main_dir() { # -> RET: the main checkout in play (for the block message)
  local d
  RET="$PWD"
  for d in "$CURDIR" "$DIR_ALT" "$PWD"; do
    if [[ -n "$d" ]] && _dir_is_main "$d"; then RET="$d"; return 0; fi
  done
}

# Rule 4: from a main checkout, a computed write destination blocks.
_check_literal() { # $1 lexed destination word -> 0 when it blocked
  # HOME may change later on the line: the end of the run judges ~ writes again.
  case "$1" in '~'|'~/'*) TILDE_SEEN=1 ;; /*) ;; *) (( TILDE_CD )) && TILDE_SEEN=1 ;; esac
  _nonliteral "$1" || return 1
  _main_in_play || return 1
  _main_dir
  _block "write to '$1', a destination built from an expansion" "$RET" nonliteral
  return 0
}

# Variables assigned earlier in the SAME command line (`SP=/tmp/x; cat > "$SP/f"`,
# `export D=…; cd "$D"`), as two parallel arrays. Agents set a scratch dir this
# way in almost every call, because shell state does not persist between Bash
# calls; without this, every such write from a main checkout read as an
# unresolvable destination and failed closed. Only values that themselves fully
# resolve are kept, so a `$(…)` or unknown variable still fails closed.
VAR_K=()
VAR_V=()
# Names that are no longer bound but may still hold a path inside a main
# checkout (their last binding, or a value a skipped/unknown assignment may
# have given them, resolved into one). Forgetting such a name would fall back
# to "unresolvable", which is allowed outside a main checkout, so a use of a
# DANGER name blocks wherever the command runs. Sticky for the whole line.
VAR_D=()
NEXT_COND=0   # the next command runs only conditionally (after && / ||)
NEXT_PIPE=0   # the next command is a pipeline member (a child shell)
LINE_CTRL=0   # sticky: a compound command keyword has appeared on this line
CTRL_DEPTH=0  # how many if / while / until / for / case / select are open ({ … } always runs)
CTRL_STK=()   # per open compound: "<1 when it opened after a |>:<if|loop|case|brace>[:d]"
CASE_PAT=0    # the next simple command is a case pattern list (after `case … in` or ;;);
              # 2 after a leading `(`, where even esac is a pattern
CASE_OPENED=0 # the command just inspected was `case WORD in …`
LX_CPAREN=0   # the command being lexed is `case WORD in (` (its first pattern follows)
CTRL_SNAP=()  # per open compound: the directory state and bindings it opened with
IC_OPENED=0   # the command being inspected opened a compound ({ cd x; … } | …)
PHYS=0        # set -P / set -o physical may be on: cd resolves .. through symlinks
PHYS_ENV=0    # physical comes in through an exported SHELLOPTS (a new shell inherits it)
case ":${SHELLOPTS:-}:" in *:physical:*) PHYS=1; PHYS_ENV=1 ;; esac
SHOPTS_TAINT=0 # SHELLOPTS is mentioned on this line (export SHELLOPTS, …)
CD_COUNT=0    # bumped by every directory change that persists in the shell being modelled
              # (put back, like the directory, on leaving a subshell / bash -c / child compound)
LX_TERM=seq   # what ends the command being inspected: seq|and|or|pipe|bg

_var_get() { # $1 name -> RET value, return 1 when unknown
  local i
  for ((i = ${#VAR_K[@]} - 1; i >= 0; i--)); do
    if [[ "${VAR_K[i]}" == "$1" ]]; then RET="${VAR_V[i]}"; return 0; fi
  done
  return 1
}

_var_is_danger() { # $1 name -> 0 when listed in VAR_D
  local d
  for d in "${VAR_D[@]}"; do [[ "$d" == "$1" ]] && return 0; done
  return 1
}

_mark_danger_if_main() { # $1 name, $2 path (relative = against CURDIR)
  [[ -z "$2" ]] && return 0
  local path="$2"
  [[ "$path" != /* ]] && path="$CURDIR/$path"
  if _dir_is_main "$path"; then _var_is_danger "$1" || VAR_D+=("$1"); fi
  return 0
}

_forget() { # $1 name -> drop its binding (and danger mark) without judging it
  local i
  for ((i = 0; i < ${#VAR_K[@]}; i++)); do
    [[ "${VAR_K[i]}" == "$1" ]] && VAR_K[i]="" && VAR_V[i]=""
  done
}

_var_poison() { # $1 name, [$2 a candidate raw value] -> unknown from here on
  # A name bound earlier on this line and now changed in a way we can't follow
  # (printf -v, read, a skipped or quoted assignment, …) could hold anything,
  # including a main-checkout path, so it becomes DANGER outright. _var_set
  # clears this again when the change turns out to be a definite re-binding.
  if _var_get "$1"; then _var_is_danger "$1" || VAR_D+=("$1"); _cand_add "$1" "$RET"; fi
  [[ -n "${2:-}" ]] && _cand_add "$1" "$2"
  # A candidate value that may point into a main checkout — directly, through a
  # known variable (D=$ROOT, D=${ROOT%/}), through a default (D=${X:-<main>}),
  # or with an unresolvable part under one (D=<main>/$X) — makes it DANGER.
  if [[ -n "${2:-}" ]] && _value_risky "$2"; then _var_is_danger "$1" || VAR_D+=("$1"); fi
  _forget "$1"
}

# Every reading of a word bash may produce: the word itself, plus each
# ${NAME:-w} / ${NAME-w} / ${NAME:=w} / ${NAME=w} / ${NAME:+w} / ${NAME+w}
# with w in its place (innermost first, so nested defaults unwind).
_alt_candidates() { # $1 word -> ALTS
  ALTS=("$1")
  local i=0 s
  local re='^(.*)\$\{([A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*#?$!-])(\[[^]]*\])?:?([-=+])([^}]*)\}(.*)$'
  while (( i < ${#ALTS[@]} && ${#ALTS[@]} < 16 )); do
    s="${ALTS[i]}"
    if [[ "$s" == *'${'* && "$s" =~ $re ]]; then
      ALTS+=("${BASH_REMATCH[1]}${BASH_REMATCH[5]}${BASH_REMATCH[6]}")
    fi
    i=$((i + 1))
  done
}

# Judge one reading of a path. RET: danger (a variable in it may point into a
# main checkout), main (it, or the literal directory before its first
# unresolvable part, is in one), unres (unresolvable, nothing known under a main
# checkout), or safe.
_dest_risk() { # $1 word, $2 base dir -> RET, RETP, RETWHY
  local e unres p q
  RETWHY=""
  _expand_path "$1"; e="$RET"; unres="$RETUNRES"
  if [[ "$RETDANGER" == "1" ]]; then RET=danger; RETP="$2"; return 0; fi
  p="$e"; [[ "$p" != /* ]] && p="$2/$p"
  RETP="$p"
  if [[ "$unres" == "1" ]]; then
    # `<main>/$X`, `'<main>/$D'`: whatever the unresolvable part turns out to
    # be, it starts inside the main checkout.
    q="${p%%\$*}"
    if [[ "$q" == */* ]]; then
      q="${q%/*}"; [[ -z "$q" ]] && q=/
      if [[ "$q" != "$2" ]] && _dir_is_main "$q"; then
        RET=main; RETP="$q"; RETWHY=" (its unresolvable part is under a main checkout)"; return 0
      fi
    fi
    # A name poisoned on this line may hold a value the line gave it
    # (`if …; then D=<dir>/ma; fi; > "${D}in/f"`): judge those readings too.
    if (( ! CAND_BUSY )) && _cand_readings "$1"; then
      local -a creads=("${CANDR[@]}")
      local cr sp="$p"
      CAND_BUSY=1
      for cr in "${creads[@]}"; do
        _dest_risk "$cr" "$2"
        if [[ "$RET" == main || "$RET" == danger ]]; then
          CAND_BUSY=0
          RET=main; RETWHY=" (a value this line may give its variable lands in a main checkout)"
          return 0
        fi
      done
      CAND_BUSY=0; RETP="$sp"
    fi
    RET=unres; return 0
  fi
  if _dir_is_main "$p"; then RET=main; return 0; fi
  RET=safe
}

# Values a name may hold after a change this guard could not follow exactly
# (an assignment that may not run, read <<<, printf -v, a case-pattern
# ${D:=w}, …), as two parallel arrays. _var_poison records them; only a
# definite binding (_var_set) drops them. _dest_risk substitutes them into a
# word that is otherwise unresolvable, so a value the line itself supplies is
# judged even when the variable is concatenated (`"${D}in/f"`).
CAND_K=()
CAND_V=()
CAND_BUSY=0
CANDR=()
_cand_add() { # $1 name, $2 value
  local i
  [[ -z "$2" ]] && return 0
  for ((i = 0; i < ${#CAND_K[@]}; i++)); do
    [[ "${CAND_K[i]}" == "$1" && "${CAND_V[i]}" == "$2" ]] && return 0
  done
  (( ${#CAND_K[@]} < 200 )) || return 0
  CAND_K+=("$1"); CAND_V+=("$2")
}
_cand_drop() { # $1 name
  local i
  for ((i = 0; i < ${#CAND_K[@]}; i++)); do
    [[ "${CAND_K[i]}" == "$1" ]] && CAND_K[i]="" && CAND_V[i]=""
  done
  return 0
}
# Readings of a word with each candidate value of each name it mentions
# ($N, ${N}, and ${N…} extended forms, approximated by the value itself).
_cand_readings() { # $1 word -> CANDR; return 1 when it mentions no candidate name
  local w="$1" i j n v r q found=1
  local -a names=() list nl
  CANDR=()
  for ((i = 0; i < ${#CAND_K[@]}; i++)); do
    n="${CAND_K[i]}"
    [[ -n "$n" ]] || continue
    [[ "$w" == *"\$$n"* || "$w" == *"\${$n"* || "$w" == *"\${#$n"* || "$w" == *"\${!$n"* ]] || continue
    q=0; for v in "${names[@]}"; do [[ "$v" == "$n" ]] && q=1; done
    (( q )) || names+=("$n")
  done
  (( ${#names[@]} )) || return 1
  list=("$w")
  for n in "${names[@]}"; do
    nl=()
    for r in "${list[@]}"; do
      nl+=("$r")
      for ((j = 0; j < ${#CAND_K[@]}; j++)); do
        [[ "${CAND_K[j]}" == "$n" ]] || continue
        v="${CAND_V[j]}"
        _cand_subst "$r" "$n" "$v"
        nl+=("$RET")
        (( ${#nl[@]} >= 32 )) && break 2
      done
    done
    list=("${nl[@]}")
  done
  CANDR=("${list[@]:1}")
  return 0
}
_cand_subst() { # $1 word, $2 name, $3 value -> RET with every $N / ${N…} replaced
  local s="$1" out="" re="^(.*)\\\$(\\{[#!]?$2([^A-Za-z0-9_}][^}]*)?\\}|$2([^A-Za-z0-9_]|\$))(.*)\$"
  while [[ "$s" =~ $re ]]; do
    out="${BASH_REMATCH[4]}${BASH_REMATCH[5]}$out"
    out="$3$out"
    s="${BASH_REMATCH[1]}"
  done
  RET="$s$out"
}

_value_risky() { # $1 value -> 0 when some reading of it may point into a main checkout
  local -a alts
  local a
  _alt_candidates "$1"; alts=("${ALTS[@]}")
  for a in "${alts[@]}"; do
    [[ -z "$a" ]] && continue
    _dest_risk "$a" "$CURDIR"
    [[ "$RET" == main || "$RET" == danger ]] && return 0
  done
  return 1
}

# ${NAME:=w} / ${NAME=w} assign NAME in this shell wherever they are expanded:
# an argument, a redirection target, a here-string, an unquoted heredoc body.
# ${!N:=w} assigns a variable named by N's value: drop every binding.
_scan_default_assigns() { # $@ words
  local wd rest bang nm val
  local re='\$\{(!?)([A-Za-z_][A-Za-z0-9_]*)(\[[^]]*\])?:?=([^}]*)\}?(.*)$'
  for wd in "$@"; do
    [[ "$wd" == *'${'* ]] || continue
    rest="$wd"
    while [[ "$rest" =~ $re ]]; do
      bang="${BASH_REMATCH[1]}" nm="${BASH_REMATCH[2]}" val="${BASH_REMATCH[4]}" rest="${BASH_REMATCH[5]}"
      if [[ -n "$bang" ]]; then _var_clear_all; continue; fi
      [[ "$nm" == HOME ]] && HOME_TAINT=1
      _var_poison "$nm" "$val"
      if [[ "$val" == *'${'* ]]; then
        # ${D:=${E:=w}}: the regex stopped at the inner `}`. E is assigned too,
        # and D may take any reading of the inner expansion (w included).
        local -a nalts
        local na
        _alt_candidates "$val}"; nalts=("${ALTS[@]}")
        for na in "${nalts[@]}"; do _var_poison "$nm" "$na"; done
        _scan_default_assigns "$val}"
      fi
    done
  done
  return 0
}

_unmodelled() { # $1 why -> remember the first reason this line can't be followed
  [[ -z "$UNMOD_WHY" ]] && UNMOD_WHY="$1"
  return 0
}

# A function definition, an alias or `enable` can change what any later command
# does, cd included: from here on the working directory is unknown (relative
# writes block) and no binding is trusted.
_fn_taint() {
  FN_SEEN=1; DIR_UNRESOLVED=1; DIR_DANGER=1; OLD_CUR="?"; DIRSTK_TAINT=1
  DIR_WHY="a function, alias, enable or set -r (cd may no longer be the builtin)"
  _var_clear_all
}

# A $'…' escape that shells decode differently (_ansi_decode) inside text that
# is re-parsed as code: what that code does is unknown, so the whole line
# blocks, wherever it runs. Holds the text shown in the message.
UNDECODED=""
_script_text() { # $1 lexed word -> RET: the text eval / bash -c / trap re-parse
  local s="$1" d='$'
  if [[ "$s" == *"$QLOST"* ]]; then
    [[ -z "$UNDECODED" ]] && { _shown "$s"; UNDECODED="$RET"; }
    # (QLOST stays: re-parsed, it is an unknown ${…} expansion.)
  fi
  s="${s//"$QMARK"/}"; s="${s//"$QTILDE"/\\}"
  RET="${s//"$LITD"/$d}"
}

# Code that runs LATER (a trap handler, an alias's text): judge its writes, but
# do not let its cd or assignments change the state the rest of the line is
# judged in. Trap handlers are judged again at the end, in the line's final
# state (an EXIT handler runs then).
DEFERRED=()
DEF_DST=0; DEF_OPT=0; DEF_AT=(); DEF_PHYS=0; DEF_SOT=0
_analyze_deferred() { # $1 shell text
  local sdir="$CURDIR" sunres="$DIR_UNRESOLVED" sdanger="$DIR_DANGER" swhy="$DIR_WHY"
  local salt="$DIR_ALT" sguard="$ALT_GUARD" sold="$OLD_CUR"
  local snc="$NEXT_COND" snp="$NEXT_PIPE" stcd="$TILDE_CD"
  local sdst="$DIRSTK_TAINT" sopt="$OLDPWD_TAINT" sphys="$PHYS" ssot="$SHOPTS_TAINT"
  local -a sstk=("${DIRSTK[@]}") svk=("${VAR_K[@]}") svv=("${VAR_V[@]}") sat=("${ATTR_N[@]}")
  # The body starts with the stack / OLDPWD as uncertain as they are now.
  NEXT_PIPE=0; NEXT_COND=0
  _analyze_text "$1"
  # What the body did to the stack / OLDPWD (a mid-line trap applies it).
  DEF_DST="$DIRSTK_TAINT"; DEF_OPT="$OLDPWD_TAINT"; DEF_AT=("${ATTR_N[@]}"); DEF_PHYS="$PHYS"; DEF_SOT="$SHOPTS_TAINT"
  DIRSTK_TAINT="$sdst"; OLDPWD_TAINT="$sopt"; ATTR_N=("${sat[@]}"); PHYS="$sphys"; SHOPTS_TAINT="$ssot"
  TILDE_CD="$stcd"
  CURDIR="$sdir"; DIR_UNRESOLVED="$sunres"; DIR_DANGER="$sdanger"; DIR_WHY="$swhy"
  DIR_ALT="$salt"; ALT_GUARD="$sguard"; OLD_CUR="$sold"
  NEXT_COND="$snc"; NEXT_PIPE="$snp"
  DIRSTK=("${sstk[@]}"); VAR_K=("${svk[@]}"); VAR_V=("${svv[@]}")
  return 0
}

_was_created_exact() { # $1 absolute path -> 0 when mkdir / git worktree add made exactly it
  local c
  for c in "${CREATED[@]}"; do [[ "$c" == "$1" ]] && return 0; done
  return 1
}

_was_created() { # $1 absolute path -> 0 when mkdir / git worktree add made it (or below it)
  local c
  for c in "${CREATED[@]}"; do
    [[ "$c" == "$1" || "$c" == "$1"/* ]] && return 0
  done
  return 1
}

_alt_active() { # -> 0 when a cd that may have failed could have left us in DIR_ALT
  [[ -n "$DIR_ALT" && "$ALT_GUARD" == "0" ]]
}

# Variables bash itself writes (BASH_REMATCH after =~, REPLY after read, PWD
# after cd, PIPESTATUS after every pipeline, …). Their value can change behind
# any command, so they are never bound.
_shell_managed() { # $1 name -> 0 when bash may write it implicitly
  case "$1" in
    BASH|BASH_*|BASHOPTS|BASHPID|COMP_*|COMPREPLY|READLINE_*|HIST*|PS[0-9]|\
    REPLY|MAPFILE|OPTARG|OPTIND|OPTERR|PWD|OLDPWD|DIRSTACK|PIPESTATUS|\
    RANDOM|SRANDOM|SECONDS|LINENO|EPOCHSECONDS|EPOCHREALTIME|FUNCNAME|\
    GROUPS|HOSTNAME|HOSTTYPE|MACHTYPE|OSTYPE|PPID|UID|EUID|SHELLOPTS|SHLVL|\
    COPROC|COPROC_*|LINES|COLUMNS|_)
      return 0 ;;
  esac
  return 1
}

_var_has_attr() { # $1 name -> 0 when declare/typeset/local gave it a transforming attribute
  local d
  for d in "${ATTR_N[@]}"; do [[ "$d" == "$1" ]] && return 0; done
  return 1
}

_var_set() { # $1 name, $2 raw value (already lexed: quotes removed)
  _var_poison "$1"
  # declare -l D; D=/X stores /x: the literal is not the value. Never bound,
  # always DANGER (its value may name a main checkout).
  if _var_has_attr "$1"; then _var_is_danger "$1" || VAR_D+=("$1"); return 0; fi
  # Never bound, but a main-checkout value still makes it DANGER.
  _shell_managed "$1" && { _var_poison "$1" "$2"; return 0; }
  # HOME is never bound either: the lexer drops quoting, so a command word
  # 'HOME=x' looks like an assignment, and ~ must keep its inherited reading.
  [[ "$1" == HOME ]] && { _var_poison "$1" "$2"; return 0; }
  # The lexer has dropped quoting, so `P='$D'` (literal) and `P=$D` (expanded)
  # look the same here, as do `'~/x'` and `~/x`. Bind only plain literals.
  case "$2" in *'$'*|'~'*|*':~'*) _var_poison "$1" "$2"; return 0 ;; esac
  # Quoting is gone too, so an unquoted $D may split on whitespace or glob:
  # D='/tmp/x <main>/f'; tee $D writes both. Bind neither; judge each field,
  # and a glob value may match anything (DANGER).
  case "$2" in
    *[[:space:]]*)
      local fld
      local -a flds=()
      IFS=$' \t\n' read -r -d '' -a flds <<< "$2"
      for fld in "${flds[@]}"; do _var_poison "$1" "$fld"; done
      _var_poison "$1" "$2"; return 0 ;;
    *[*?[]*)
      _var_poison "$1"; _var_is_danger "$1" || VAR_D+=("$1"); return 0 ;;
  esac
  _expand_path "$2"
  [[ "$RETUNRES" == "1" ]] && return 0
  VAR_K+=("$1"); VAR_V+=("$RET")
  _cand_drop "$1"
  # A definite assignment replaces whatever it held, so it is no longer DANGER.
  local -a keep=() d
  for d in "${VAR_D[@]}"; do [[ "$d" == "$1" ]] || keep+=("$d"); done
  VAR_D=("${keep[@]}")
}

# How an assignment in the command being inspected affects the parent shell:
# "bind" (it runs here, unconditionally), "skip" (it runs in a child: a
# pipeline member, a background job, or a prefix like `env X=1`), or "poison"
# (it may or may not run: after && / ||, or anywhere once a compound command
# such as if/while/case/{ … } has appeared on the line).
_assign_mode() { # -> RET
  if [[ "$LX_TERM" == "pipe" || "$LX_TERM" == "bg" ]]; then
    RET=skip
  elif [[ "$NEXT_PIPE" == "1" && "$IC_OPENED" == 0 ]]; then
    # A pipeline's last member runs in this shell under lastpipe (and always
    # in zsh / ksh): it may or may not assign here.
    RET=poison
  elif [[ "$NEXT_COND" == "1" || "$LINE_CTRL" == "1" ]] || (( DEPTH > 1 )); then
    RET=poison
  else
    RET=bind
  fi
}

# Bash has many ways to change a variable besides NAME=value: unset, read,
# for/select, printf -v, mapfile, getopts, NAME+=, NAME[i]=, a prefix before a
# special builtin (`D=x export D`), let/(( )), eval, bash -c. Rather than model
# each, any word that names a bound variable (bare `D`, or `D=…`, `D+=…`,
# `D[…`) poisons it; only the narrow binding paths below re-bind it.
HOMEWORD='(^|[^A-Za-z0-9_])HOME([^A-Za-z0-9_]|$)'
_poison_mentions() { # $@ words
  local wd nm i hw
  local -a all=()
  for wd in "$@"; do
    all+=("$wd")
    # An indirect name (`N=D; printf -v "$N"`) mentions D only after expansion.
    if [[ "$wd" == *'$'* ]]; then _subst_vars "$wd"; [[ "$RET" == "$wd" ]] || all+=("$RET"); fi
  done
  for wd in "${all[@]}"; do
    # Any mention: cd stops trusting the inherited CDPATH (a binding still wins).
    [[ "$wd" == *CDPATH* ]] && CDPATH_TAINT=1
    # cd - goes to $OLDPWD and popd to ${DIRSTACK[1]}: an assignment to either
    # (OLDPWD=…, DIRSTACK[1]=…, read OLDPWD, …) sends them anywhere.
    [[ "$wd" == *OLDPWD* ]] && OLDPWD_TAINT=1
    [[ "$wd" == *DIRSTACK* ]] && DIRSTK_TAINT=1
    [[ "$wd" == *SHELLOPTS* ]] && SHOPTS_TAINT=1
    # A bare HOME (HOME=…, read HOME, printf -v HOME, …), not a $HOME read:
    # ~ and $HOME may no longer hold the inherited value.
    hw="${wd//\$\{HOME/}"; hw="${hw//\$HOME/}"
    [[ "$hw" =~ $HOMEWORD ]] && HOME_TAINT=1
    if [[ "$wd" =~ ^([A-Za-z_][A-Za-z0-9_]*)\+=(.*)$ ]]; then
      nm="${BASH_REMATCH[1]}"
      # NAME+=lit: the new value is the old one with lit appended (or just lit
      # when NAME was unset).
      if _var_get "$nm"; then _var_poison "$nm" "$RET${BASH_REMATCH[2]}"
      elif ! _var_is_danger "$nm"; then _var_poison "$nm" "${BASH_REMATCH[2]}"; fi
    elif [[ "$wd" =~ ^([A-Za-z_][A-Za-z0-9_]*)\[([^]]*)\](\+?)=(.*)$ ]]; then
      nm="${BASH_REMATCH[1]}"
      # The subscript is arithmetic and can itself assign (a[D=1]=x).
      if [[ "${BASH_REMATCH[2]}" == *=* ]]; then _var_clear_all; continue; fi
      # D[0]=v writes scalar D; treat v as what D may now hold.
      if _var_get "$nm"; then
        if [[ -n "${BASH_REMATCH[3]}" ]]; then _var_poison "$nm" "$RET${BASH_REMATCH[4]}"
        else _var_poison "$nm" "${BASH_REMATCH[4]}"; fi
      elif _var_is_danger "$nm"; then :
      else _var_poison "$nm" "${BASH_REMATCH[4]}"; fi
    elif [[ "$wd" =~ ^([A-Za-z_][A-Za-z0-9_]*)(=|\[|$) ]]; then
      nm="${BASH_REMATCH[1]}"
      _var_get "$nm" && _var_poison "$nm"
    elif [[ "$wd" == -* ]]; then
      # Attached option argument naming a variable: printf -vD, read -aD,
      # wait -pD. Only those letters take a name, so `ls -la "$a"` leaves a alone.
      for ((i = 0; i < ${#VAR_K[@]}; i++)); do
        nm="${VAR_K[i]}"
        [[ -n "$nm" && "$wd" =~ ^-[A-Za-z]*[vap]$nm$ ]] && _var_poison "$nm"
      done
    fi
  done
  return 0
}

IC_CHILD=0    # the command being inspected certainly runs in a child shell
_var_clear_all() { # forget every binding and bind nothing more on this line
  local i
  for ((i = 0; i < ${#VAR_K[@]}; i++)); do
    [[ -n "${VAR_K[i]}" ]] && { _var_is_danger "${VAR_K[i]}" || VAR_D+=("${VAR_K[i]}"); }
  done
  VAR_K=(); VAR_V=(); LINE_CTRL=1
  # A child shell's HOME / OLDPWD / DIRSTACK changes stay there.
  (( IC_CHILD )) || { HOME_TAINT=1; OLDPWD_TAINT=1; DIRSTK_TAINT=1; }
}

_assign() { # $1 NAME=value word, $2 mode
  case "$2" in
    bind)   _var_set "${1%%=*}" "${1#*=}" ;;
    poison) _var_poison "${1%%=*}" "${1#*=}" ;;
  esac
}

_subst_vars() { # $1 string -> RET with known $NAME / ${NAME} substituted
  local s="$1" out="" name pre whole post
  # `set -- <main>` makes $1 / $@ / ${1} point into a main checkout.
  local posre='\$\{?[0-9@*]'
  if [[ "$POS_DANGER" == "1" && "$s" =~ $posre ]]; then RETDANGER=1; fi
  # Extended forms (${D%/}, ${D/x/y}, ${#D}, ${!D}, ${D:-x}) are not resolved;
  # they can rewrite a bound path anywhere, so one over a bound or DANGER name
  # is DANGER (blocks wherever the command runs).
  local ext='\$\{([#!]?)([A-Za-z_][A-Za-z0-9_]*)([^A-Za-z0-9_}][^}]*)?\}(.*)$' rest="$s" en
  while [[ "$rest" =~ $ext ]]; do
    en="${BASH_REMATCH[2]}"
    if [[ -n "${BASH_REMATCH[1]}${BASH_REMATCH[3]}" ]]; then
      if _var_get "$en" || _var_is_danger "$en"; then RETDANGER=1; fi
    fi
    rest="${BASH_REMATCH[4]}"
  done
  local re='^([^$]*)\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(.*)$'
  while [[ "$s" =~ $re ]]; do
    name="${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
    pre="${BASH_REMATCH[1]}" whole="\$${BASH_REMATCH[2]}" post="${BASH_REMATCH[5]}"
    if _var_get "$name"; then
      out="$out$pre$RET"
    elif [[ "$name" == HOME ]] && _home; then
      out="$out$pre$RET"
    else
      _var_is_danger "$name" && RETDANGER=1
      out="$out$pre$whole"
    fi
    s="$post"
  done
  RET="$out$s"
}

_abs_path() { # $1 path, $2 base dir -> RET absolute (unresolvable vars flagged)
  _expand_path "$1"
  local p="$RET"
  [[ "$p" != /* ]] && p="$2/$p"
  RET="$p"
}

_nearest_dir() { # $1 absolute path -> RET nearest existing ancestor directory
  local p="$1" q
  while [[ -n "$p" && ! -d "$p" ]]; do
    q="${p%/*}"
    [[ "$q" == "$p" ]] && { p=""; break; }   # no slash left: never loop
    p="$q"
  done
  [[ -z "$p" ]] && p="/"
  RET="$p"
}

# Cache of dir -> 1 (main checkout) / 0 (not), as two parallel arrays.
MC_KEYS=()
MC_VALS=()

_is_main_checkout() { # $1 dir -> 0 when it is a MAIN checkout
  local d="$1" i gd
  for ((i = 0; i < ${#MC_KEYS[@]}; i++)); do
    if [[ "${MC_KEYS[i]}" == "$d" ]]; then
      [[ "${MC_VALS[i]}" == "1" ]] && return 0
      return 1
    fi
  done
  local val=0
  # Physically, as the kernel resolves a write's path: <dir>/link/../f is in
  # link's target's parent. (The modelled cwd is kept logical-normalised, so
  # resolving it physically finds the directory bash is really in.)
  gd=$(cd -P "$d" 2>/dev/null && git rev-parse --git-dir 2>/dev/null)
  if [[ -n "$gd" ]]; then
    if [[ "$gd" != /* ]]; then
      gd=$(cd -P "$d" 2>/dev/null && cd -P "$gd" 2>/dev/null && pwd -P)
    fi
    if [[ -n "$gd" && "$gd" != *".git/worktrees/"* ]]; then
      val=1
    fi
  fi
  MC_KEYS+=("$d")
  MC_VALS+=("$val")
  [[ "$val" == "1" ]] && return 0
  return 1
}

_dir_is_main() { # $1 dir-ish path (may not exist) -> 0 when in a main checkout
  _nearest_dir "$1"
  _is_main_checkout "$RET"
}

# --- verdict ----------------------------------------------------------------

BLOCKED=0
BLOCK_WHAT=""
BLOCK_WHERE=""
BLOCK_KIND=""

_block() { # $1 what, $2 where, [$3 kind: nonliteral]
  [[ "$BLOCKED" == "1" ]] && return 0
  BLOCKED=1
  BLOCK_KIND="${3:-}"
  _shown "$1"; BLOCK_WHAT="$RET"
  BLOCK_WHERE="$2"
}

_shown() { # $1 text -> RET with the lexer's placeholders written back as shell text
  local s="$1" lit='\$'
  s="${s//"$LITD"/$lit}"; s="${s//"$QLOST"/…}"; s="${s//"$QMARK"/}"; s="${s//"$QTILDE"/\\}"
  RET="${s//"$CMDSUB"/\$(…)}"
}

# --- lexer state ------------------------------------------------------------

LINES=()
L=0
C=0
HD=()            # pending heredoc delimiters for the current line
# Working directory as tracked through `cd`, plus a flag for a `cd` target we
# could not resolve. Both are globals because _inspect_cmd — reached from deep
# inside the lexer — has to update them.
#
# A `cd` inside a SUBSHELL (`$( … )`, backticks, or `( … )`) cannot move the
# PARENT shell's working directory. _lex_context therefore saves this pair on
# entering a subshell context and restores it on leaving. Do not "simplify" that
# away: without it `OUT="$(cd /elsewhere && …)"` would leave CURDIR pointing at
# /elsewhere for the rest of the command line, and every later relative path
# would be judged against the wrong repo.
CURDIR="$PWD"
DIR_UNRESOLVED=0
DIR_DANGER=0     # the unresolved cd target was a DANGER variable
DIR_WHY=""       # why the directory is unresolved (for the block message)
# A `cd` whose target does not exist fails in bash, leaving the shell where it
# was. DIR_ALT is that earlier directory; ALT_GUARD=1 while the commands being
# inspected run only if the cd succeeded (`cd X && …`). OLD_CUR is what `cd -`
# returns to, DIRSTK what `popd` pops ("?" for an unknown directory).
DIR_ALT=""
ALT_GUARD=0
OLD_CUR=""
DIRSTK=()
PARSE_ERROR=0
DEPTH=0
STEPS=0
MAXSTEPS=400000

# Runs of "ordinary" characters are consumed in one go rather than one at a
# time — a long single-line command (an 8 KB `gh pr create --body …`) is
# otherwise quadratic in bash and takes seconds.
LX_SPECIALS=$'\\\'"`$#;|&()<> \t'
ORDRUN_RE="^([^${LX_SPECIALS}]*)"
DQRUN_RE=$'^([^"\\\\$`]*)'

_split_lines() {
  LINES=()
  local line
  while IFS= read -r line; do
    LINES+=("$line")
  done <<< "$1"
}

# Read a single-quoted string starting at C (just past the opening quote).
_read_sq() {
  local out="" line rest part
  while :; do
    if (( L >= ${#LINES[@]} )); then PARSE_ERROR=1; RET="$out"; return; fi
    line="${LINES[L]}"
    rest="${line:C}"
    if [[ "$rest" == *"'"* ]]; then
      part="${rest%%\'*}"
      out="$out$part"; C=$((C + ${#part} + 1))
      RET="$out"; return
    fi
    out="$out$rest"$'\n'
    L=$((L + 1)); C=0
  done
}

# Read a double-quoted string starting at C (just past the opening quote).
# Command substitutions inside it are lexed (their commands ARE inspected) but
# contribute nothing to the literal value.
_read_dq() {
  local out="" line ch nx rest run
  while :; do
    if (( L >= ${#LINES[@]} )); then PARSE_ERROR=1; RET="$out"; return; fi
    line="${LINES[L]}"
    while (( C < ${#line} )); do
      rest="${line:C}"
      if [[ "$rest" =~ $DQRUN_RE ]]; then
        run="${BASH_REMATCH[1]}"
        if [[ -n "$run" ]]; then
          out="$out$run"; C=$((C + ${#run})); continue
        fi
      fi
      ch="${line:C:1}"
      if [[ "$ch" == '\' ]]; then
        nx="${line:$((C + 1)):1}"
        if [[ -z "$nx" ]]; then
          C=$((C + 1)); break            # line continuation
        fi
        case "$nx" in
          '$')
            # A literal $ — except inside backticks, which strip the backslash
            # before the inner command is parsed (so it expands there).
            if (( BQ > 0 )); then out="$out$nx"; else out="$out$LITD"; fi
            C=$((C + 2)); continue ;;
          '"'|'\'|'`') out="$out$nx"; C=$((C + 2)); continue ;;
          *)           out="$out$ch"; C=$((C + 1)); continue ;;
        esac
      fi
      if [[ "$ch" == '"' ]]; then C=$((C + 1)); RET="$out"; return; fi
      if [[ "$ch" == '$' && "${line:$((C + 1)):1}" == '(' ]]; then
        local dq_arith=0; [[ "${line:$((C + 2)):1}" == '(' ]] && dq_arith=1
        C=$((C + 2)); _lex_context ')'; line="${LINES[L]}"; out="$out$CMDSUB"
        (( dq_arith )) && _var_clear_all
        continue
      fi
      if [[ "$ch" == '`' ]]; then
        C=$((C + 1)); BQ=$((BQ + 1)); _lex_context '`'; BQ=$((BQ - 1))
        line="${LINES[L]}"; out="$out$CMDSUB"; continue
      fi
      out="$out$ch"; C=$((C + 1))
    done
    if (( C >= ${#line} )); then
      out="$out"$'\n'
      L=$((L + 1)); C=0
    fi
  done
}

# Decode the body of a $'…' string. Only escapes that bash 3.2, bash 5 and zsh
# all decode the same way, to a byte other than NUL, are decoded: \a \b \e \E
# \f \n \r \t \v \\ \' \" \?, \xH / \xHH and octal \N / \NN / \NNN up to \377.
# Anything else reads differently in one of them (\u and \U: literal in bash
# 3.2; \c: no control character in zsh; an unknown escape such as \q or \/:
# zsh drops the backslash; \x with no digit: NUL in zsh; NUL itself; a
# backslash before a newline). Each such escape becomes $2, RETUNRES=1, and
# decoding goes on past it: the rest of the string is never dropped. A `$` in
# the decoded text becomes $3 when given (never one inside $2).
_ansi_decode() { # $1 body, $2 stand-in for an uncertain escape, [$3 for a `$`] -> RET, RETUNRES
  local s="$1" out="" part c d o dl="${3:-\$}"
  RETUNRES=0
  while [[ "$s" == *'\'* ]]; do
    part="${s%%\\*}"; out="$out${part//\$/$dl}"; s="${s:$((${#part} + 1))}"
    c="${s:0:1}"; s="${s:1}"
    case "$c" in
      a) out="$out"$'\a' ;;
      b) out="$out"$'\b' ;;
      e|E) out="$out"$'\033' ;;
      f) out="$out"$'\f' ;;
      n) out="$out"$'\n' ;;
      r) out="$out"$'\r' ;;
      t) out="$out"$'\t' ;;
      v) out="$out"$'\v' ;;
      '\'|"'"|'"'|'?') out="$out$c" ;;
      x|[0-7])
        if [[ "$c" == x ]]; then
          d=""
          if [[ "${s:0:1}" == [0-9A-Fa-f] ]]; then
            d="${s:0:1}"; [[ "${s:1:1}" == [0-9A-Fa-f] ]] && d="${s:0:2}"
          fi
          s="${s:${#d}}"; o=0; [[ -n "$d" ]] && o=$((16#$d))
        else
          d="$c"
          if [[ "${s:0:1}" == [0-7] ]]; then
            d="$d${s:0:1}"; [[ "${s:1:1}" == [0-7] ]] && d="$d${s:1:1}"
          fi
          s="${s:$((${#d} - 1))}"; o=$((8#$d))
        fi
        if (( o > 0 && o < 256 )); then
          printf -v d '%03o' "$o"; printf -v d "\\$d"; out="$out${d//\$/$dl}"
        else
          out="$out$2"; RETUNRES=1
        fi ;;
      *) out="$out$2"; RETUNRES=1 ;;
    esac
  done
  RET="$out${s//\$/$dl}"
}

# Read a $'…' string starting at C (just past the opening quote). Unlike '…',
# a backslash escapes the quote ($'it\'s'). The body is decoded by
# _ansi_decode; an escape it cannot decode with certainty becomes QLOST, and
# the text after it is still decoded. The result always ends in QMARK, so as a
# path it stays unresolvable: its literal start (all of it, when every escape
# decoded) is what gets judged.
ANSIRUN_RE=$'^([^\\\\\']*)'
_read_ansi() {
  local raw="" line rest
  while :; do
    if (( L >= ${#LINES[@]} )); then
      PARSE_ERROR=1
      _ansi_decode "$raw" "$QLOST" "$LITD"; RET="$RET$QLOST$QMARK"; return
    fi
    line="${LINES[L]}"
    while (( C < ${#line} )); do
      rest="${line:C}"
      [[ "$rest" =~ $ANSIRUN_RE ]]
      raw="$raw${BASH_REMATCH[1]}"; C=$((C + ${#BASH_REMATCH[1]}))
      (( C < ${#line} )) || break
      if [[ "${line:C:1}" == "'" ]]; then
        C=$((C + 1))
        _ansi_decode "$raw" "$QLOST" "$LITD"; RET="$RET$QMARK"
        return
      fi
      raw="$raw${line:C:2}"; C=$((C + 2))   # an escape (a lone \ at the end: before the newline)
    done
    raw="$raw"$'\n'
    L=$((L + 1)); C=0
  done
}

# Read a heredoc delimiter word starting at C; push it onto HD.
_read_heredoc_delim() {
  local line="${LINES[L]}" ch delim="" q quoted=0
  while [[ "${line:C:1}" == " " || "${line:C:1}" == $'\t' ]]; do C=$((C + 1)); done
  while (( C < ${#line} )); do
    ch="${line:C:1}"
    case "$ch" in
      "'"|'"')
        q="$ch"; quoted=1; C=$((C + 1))
        while (( C < ${#line} )) && [[ "${line:C:1}" != "$q" ]]; do
          delim="$delim${line:C:1}"; C=$((C + 1))
        done
        C=$((C + 1))
        ;;
      '\')
        quoted=1; C=$((C + 1)); delim="$delim${line:C:1}"; C=$((C + 1))
        ;;
      ' '|$'\t'|';'|'&'|'|'|')'|'<'|'>')
        break
        ;;
      *)
        delim="$delim$ch"; C=$((C + 1))
        ;;
    esac
  done
  if [[ -n "$delim" ]]; then
    if (( quoted )); then HD+=("Q$delim"); else HD+=("U$delim"); fi
  fi
}

# At end of a line that opened heredocs: swallow their bodies.
_consume_heredocs() {
  local i=$((L + 1)) entry d kind ln trimmed esc
  local n=${#LINES[@]}
  local -a pending=("${HD[@]}") bodies=()
  for entry in "${pending[@]}"; do
    kind="${entry:0:1}"; d="${entry:1}"
    while (( i < n )); do
      ln="${LINES[i]}"
      trimmed="$ln"
      while [[ "$trimmed" == $'\t'* ]]; do trimmed="${trimmed#	}"; done
      i=$((i + 1))
      if [[ "$ln" == "$d" || "$trimmed" == "$d" ]]; then break; fi
      # An UNQUOTED delimiter means the body expands: $(…) and `…` in it RUN.
  # (_end_word keeps here-strings and input redirections for the same reason.)
      # Queue those lines to be lexed like a double-quoted string.
      # ${D:=…} in such a body assigns D, so those lines are lexed too.
      if [[ "$kind" == "U" && ( "$ln" == *'$('* || "$ln" == *'`'* || "$ln" == *'${'* ) ]]; then
        bodies+=("$ln")
      fi
    done
  done
  HD=()
  L=$((i - 1))
  for ln in "${bodies[@]}"; do
    # a heredoc body treats \$ \` \\ like a double-quoted string does, so only the
    # double quote itself needs escaping to lex the line as one
    esc="${ln//\"/\\\"}"
    _analyze_text ": \"$esc\""
  done
}

# --- command inspection -----------------------------------------------------

IC_WORDS=()
IC_REDIRS=()
IC_OTHER=()      # input redirection targets (`< file`): read, but still expanded
IC_HSTR=()       # here-string words (`<<< word`)
IC_WQ=()         # per word: 1 when quoted before its first `=` (not an assignment)

# Stands in for a $(…) / `…` inside a word. Its value is only known at run time,
# so the word must read as unresolvable (it contains a '$'), never as the empty
# string it would otherwise collapse to.
CMDSUB='${__command_substitution__}'

# Check one write destination; block when it lands inside a main checkout.
_check_dest() { # $1 destination, $2 kind: redir | remote | (empty: a file argument)
  local raw="$1" kind="${2:-}"
  [[ -z "$raw" ]] && return 0
  case "$raw" in
    /dev/null|/dev/stdout|/dev/stderr|/dev/tty|/dev/fd/*) return 0 ;;
  esac
  if [[ "$kind" == "redir" ]]; then
    [[ "$raw" == '&'* ]] && return 0          # >&2, 2>&1: an fd, not a file
    [[ "$raw" =~ ^[0-9]+$ ]] && return 0      # fd number left over from N>&M
  fi
  _check_literal "$raw" && return 0
  if [[ "$kind" == "remote" && "$raw" =~ ^[^/]*: ]]; then
    return 0                                  # host:path — not this machine
  fi
  _expand_path "$raw"
  if [[ "$RETDANGER" == "1" ]]; then
    _block "write to '$raw', whose variable may point into a main checkout" "$CURDIR"
    return 0
  fi
  # After a cd this guard cannot resolve, the working directory is unknown: a
  # destination that is (or may be) relative blocks wherever the line runs.
  # One that resolves to an absolute or ~ path does not depend on it.
  # ('~x' quoted, or ~user that does not resolve, is a relative name: only an
  # absolute destination is independent of the working directory.)
  if [[ "$DIR_UNRESOLVED" == "1" ]]; then
    case "$RET" in
      /*) ;;
      *) _block "relative write to '$raw' after $DIR_WHY" "$CURDIR" unresolved
         return 0 ;;
    esac
  fi
  # Judge every reading of the word (defaults like ${D:-<main>} included),
  # against the working directory and, after a cd that may have failed,
  # against the directory the shell may still be in.
  local -a alts bases
  local a b
  _alt_candidates "$raw"; alts=("${ALTS[@]}")
  bases=("$CURDIR"); _alt_active && bases+=("$DIR_ALT")
  for a in "${alts[@]}"; do
    for b in "${bases[@]}"; do
      _dest_risk "$a" "$b"
      case "$RET" in
        danger)
          _block "write to '$raw', whose variable may point into a main checkout" "$CURDIR"
          return 0 ;;
        main)
          if [[ "$b" == "$CURDIR" ]]; then
            _block "write to '$raw'$RETWHY" "$RETP"
          else
            _block "write to '$raw' after a cd that may have failed (its target does not exist)$RETWHY" "$RETP"
          fi
          return 0 ;;
      esac
    done
  done
  # An unresolvable reading is only a risk from a main checkout, where
  # _check_literal has already blocked it.
  return 0
}

# Non-option words of a write command (touch, mkdir, rm, chmod, …), skipping
# the values of the options in $1 (space-separated; also the last letter of a
# cluster such as -pm). Every word after -- is an operand.
OPERANDS=()
_operands() { # $1 options that take a value, $@ words -> OPERANDS
  local takes=" $1 " a dd=0 skip=0
  shift
  OPERANDS=()
  for a in "$@"; do
    if (( skip )); then skip=0; continue; fi
    if (( ! dd )); then
      [[ "$a" == -- ]] && { dd=1; continue; }
      if [[ "$a" == -?* ]]; then
        [[ "$takes" == *" $a "* ]] && skip=1
        [[ "$a" =~ ^-[A-Za-z]+$ && "$takes" == *" -${a: -1} "* ]] && skip=1
        continue
      fi
    fi
    OPERANDS+=("$a")
  done
}
_check_operands() { # $1 options that take a value, $@ words: each operand is a destination
  local o
  _operands "$@"
  for o in "${OPERANDS[@]}"; do _check_dest "$o"; done
}

# The files sort -o, curl -o / -O and wget -O / -P (or by default) write.
_check_outputs() { # $1 command, $@ its words
  local cmd="$1" k a nx wout=0
  shift
  local -a w=("$@")
  for ((k = 0; k < ${#w[@]}; k++)); do
    a="${w[k]}"; nx="${w[$((k + 1))]:-}"
    case "$cmd:$a" in
      sort:-o|sort:--output|curl:--output) _check_dest "$nx" ;;
      sort:--output=*|curl:--output=*) _check_dest "${a#*=}" ;;
      sort:-o?*) _check_dest "${a#-o}" ;;
      curl:--remote-name|curl:--remote-name-all|curl:-J|curl:--remote-header-name) _check_dest . ;;
      curl:--*|sort:*) ;;
      curl:-*)
        if [[ "$a" =~ ^-[A-Za-z0-9]*o$ ]]; then _check_dest "$nx"
        elif [[ "$a" =~ ^-[A-Za-np-z0-9]*o(.+)$ ]]; then _check_dest "${BASH_REMATCH[1]}"; fi
        [[ "$a" =~ ^-[A-Za-z0-9]*O ]] && _check_dest . ;;
      wget:-O|wget:--output-document|wget:-P|wget:--directory-prefix) wout=1; [[ "$nx" == - ]] || _check_dest "$nx" ;;
      wget:--output-document=*|wget:--directory-prefix=*) wout=1; [[ "${a#*=}" == - ]] || _check_dest "${a#*=}" ;;
      wget:-O?*|wget:-P?*) wout=1; [[ "${a:2}" == - ]] || _check_dest "${a:2}" ;;
    esac
  done
  [[ "$cmd" == wget ]] && (( ! wout )) && _check_dest .
  return 0
}

_block_if_cwd_main() { # $1 what — a content-introducing command run in CWD
  local what="$1"
  (( TILDE_CD )) && TILDE_SEEN=1
  if [[ "$DIR_UNRESOLVED" == "1" ]]; then
    _block "$what after $DIR_WHY" "$CURDIR" unresolved
    return 0
  fi
  if _dir_is_main "$CURDIR"; then
    _block "$what" "$CURDIR"
  elif _alt_active && _dir_is_main "$DIR_ALT"; then
    _block "$what (after a cd that may have failed: its target does not exist)" "$DIR_ALT"
  fi
}

# The working directory is now unknown (a cd this guard cannot follow). The
# cd may have failed, leaving OLDPWD as it was, so `cd -` returns to a known
# directory only when both outcomes agree.
_dir_unknown() { # $1 why
  local old="$CURDIR"
  CD_COUNT=$((CD_COUNT + 1))
  if [[ "$DIR_UNRESOLVED" == "1" || "$OLD_CUR" != "$old" ]]; then OLD_CUR="?"; fi
  DIR_UNRESOLVED=1; DIR_DANGER=1; DIR_WHY="$1"
  return 0
}

# After && / || or inside if / while / until / for / select / case (or a
# { … } group entered after && / ||), a directory change may not run at all.
_cd_maybe() { [[ "$NEXT_COND" == "1" ]] || (( CTRL_DEPTH > 0 )); }

_fn_dir() { # a function / alias / enable / set -r may have redefined cd
  DIR_UNRESOLVED=1; DIR_DANGER=1
  DIR_WHY="a function, alias, enable or set -r (cd may no longer be the builtin)"
}

# Remember a directory the shell may still be in. There is one slot: when two
# candidates compete, keep a main checkout (fail closed).
_alt_add() { # $1 directory
  if [[ -z "$DIR_ALT" ]]; then DIR_ALT="$1"
  elif [[ "$DIR_ALT" != "$1" ]] && ! _dir_is_main "$DIR_ALT" && _dir_is_main "$1"; then DIR_ALT="$1"
  fi
  return 0
}

# A compound command (if / while / for / case / select / { … }) that is a
# pipeline member or a background job runs in a child shell (at the END of a
# pipeline it may instead run in this shell: lastpipe; always in zsh / ksh).
# Inside it, a cd or assignment applies to the rest of its body. When it
# closes, nothing is restored (a misread closer must never undo a real cd):
# if it changed directory, the directory is unknown, and bindings it changed
# are no longer trusted. The state it opened with is saved for that check.
FS1=$'\x1e'; FS2=$'\x1f'
_join() { # $@ -> RET: each element prefixed by FS2 (keeps empty elements)
  local out="" e
  for e in "$@"; do out="$out$FS2$e"; done
  RET="$out"
}
_split() { # $1 _join output -> SPLIT
  SPLIT=()
  local s="$1"
  [[ -z "$s" ]] && return 0
  s="${s#"$FS2"}"
  while [[ "$s" == *"$FS2"* ]]; do SPLIT+=("${s%%"$FS2"*}"); s="${s#*"$FS2"}"; done
  SPLIT+=("$s")
}
SPLIT=()
_ctrl_open() { # $1 kind: if | loop | case | brace
  local c=0 snap stk vk vv at
  # Only the outermost compound this command opens is the pipeline member:
  # in `true | { if …`, the if runs inside the group's child shell.
  [[ "$NEXT_PIPE" == "1" && "$IC_OPENED" == 0 ]] && c=1
  _join "${DIRSTK[@]}"; stk="$RET"
  _join "${VAR_K[@]}"; vk="$RET"
  _join "${VAR_V[@]}"; vv="$RET"
  _join "${ATTR_N[@]}"; at="$RET"
  snap="$CURDIR$FS1$DIR_UNRESOLVED$FS1$DIR_DANGER$FS1$DIR_WHY$FS1$DIR_ALT$FS1$ALT_GUARD$FS1$OLD_CUR$FS1$TILDE_CD$FS1$stk$FS1$vk$FS1$vv$FS1$CD_COUNT$FS1$DIRSTK_TAINT$FS1$OLDPWD_TAINT$FS1$at"
  CTRL_STK+=("$c:$1"); CTRL_SNAP+=("$snap")
}
# Only a closer that matches the innermost open compound closes it (fi an if,
# done a loop, esac a case, } a group); anything else is not a closer here
# (a case pattern such as `fi|y)`, a stray word). RET: the entry closed.
_ctrl_close() { # $1 kind -> 1 when it closes nothing
  local n=${#CTRL_STK[@]} c snap ent
  RET=""
  (( n == 0 )) && return 1
  ent="${CTRL_STK[$((n - 1))]}"
  [[ "${ent#*:}" == "$1" || "${ent#*:}" == "$1":* ]] || return 1
  RET="$ent"
  c="${ent%%:*}"; snap="${CTRL_SNAP[$((n - 1))]}"
  unset "CTRL_STK[$((n - 1))]" "CTRL_SNAP[$((n - 1))]"
  CTRL_STK=("${CTRL_STK[@]}"); CTRL_SNAP=("${CTRL_SNAP[@]}")
  [[ "$c" == 1 || "$LX_TERM" == pipe || "$LX_TERM" == bg ]] || return 0
  # It ran in a child shell (before a `|` or `&`), or may have (at the end of
  # a pipeline). Its changes are never undone: a misread closer must not make
  # this guard surer of anything. A directory change inside it leaves the
  # directory, OLDPWD and the stack unknown; a binding it changed is no
  # longer trusted.
  local -a f=()
  local rest="$snap$FS1"
  while [[ -n "$rest" ]]; do f+=("${rest%%"$FS1"*}"); rest="${rest#*"$FS1"}"; done
  if [[ "$CD_COUNT" != "${f[11]}" ]]; then
    _dir_lost "a cd inside a compound command in a pipeline or background job"
  fi
  local -a ok ov
  local k nm same
  _split "${f[9]}"; ok=("${SPLIT[@]}")
  _split "${f[10]}"; ov=("${SPLIT[@]}")
  for nm in "${VAR_K[@]}" "${ok[@]}"; do
    [[ -n "$nm" ]] || continue
    same=0
    for ((k = ${#ok[@]} - 1; k >= 0; k--)); do
      if [[ "${ok[k]}" == "$nm" ]]; then
        _var_get "$nm" && [[ "$RET" == "${ov[k]}" ]] && same=1
        break
      fi
    done
    (( same )) && continue
    _var_is_danger "$nm" || VAR_D+=("$nm")
    _forget "$nm"
  done
  return 0
}

# Something that may run any number of cd / pushd / popd (a sourced file, a
# command named by an expansion, a trap handler, a function, a compound or eval
# at the end of a pipeline): the directory, OLDPWD and the stack are all lost.
_dir_lost() { # $1 why
  _dir_unknown "$1"
  OLD_CUR="?"; DIRSTK_TAINT=1
  return 0
}

# A logical cd (the default, -L) drops . and .. textually before following
# symlinks: /repo/link/.. is /repo, whatever link points to.
_lexnorm() { # $1 absolute path -> RET
  local -a parts=() out=()
  local part n rest="$1/"
  # Split on / by hand: read would stop at a newline inside a name.
  while [[ -n "$rest" ]]; do parts+=("${rest%%/*}"); rest="${rest#*/}"; done
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.) ;;
      ..) n=${#out[@]}; (( n > 0 )) && unset "out[$((n - 1))]"; out=("${out[@]}") ;;
      *) out+=("$part") ;;
    esac
  done
  RET=""
  for part in "${out[@]}"; do RET="$RET/$part"; done
  [[ -z "$RET" ]] && RET=/
  return 0
}

# Remember a directory mkdir / git worktree add makes. . and // are dropped
# (exact); a path with .. is not recorded at all: the kernel resolves .. through
# symlinks (mkdir -p <x>/link/../new makes it beside link's target), so a later
# cd to its lexical spelling stays a cd that may fail.
_record_created() { # $1 absolute path
  case "$1/" in */../*) return 0 ;; esac
  _lexnorm "$1"; CREATED+=("$RET")
  return 0
}

# The physical directory a path resolves to (RET; empty when it does not).
# A sentinel keeps trailing newlines that $(…) would strip from a name.
_phys() { # $1 path, $2 L to resolve it logically first
  local opt=-P
  [[ "${2:-}" == L ]] && opt=-L
  RET=$(cd "$opt" -- "$1" 2>/dev/null && pwd -P && echo .) || { RET=""; return 0; }
  RET="${RET%.}"; RET="${RET%$'\n'}"
  return 0
}

# A logical cd succeeds only if every prefix before a .., normalised, is a
# directory (bash's check), or was made by mkdir / git worktree add on this line.
_walk_ok() { # $1 absolute path as written
  local rest="$1/" comp cur=""
  while [[ -n "$rest" ]]; do
    comp="${rest%%/*}"; rest="${rest#*/}"
    if [[ "$comp" == .. ]]; then
      _lexnorm "${cur:-/}"
      [[ -d "$RET" ]] || _was_created "$RET" || return 1
    fi
    [[ -n "$comp" ]] && cur="$cur/$comp"
  done
  return 0
}

# Change the modelled working directory the way `cd <target>` / `pushd <target>`
# would. The caller has already refused computed targets (_dir_unknown).
_cd_to() { # $1 target word (literal), $2 L / P (cd -L / -P) or empty
  local mode="${2:-}" target="$1" old="$CURDIR" oldun="$DIR_UNRESOLVED" olddg="$DIR_DANGER" prevold="$OLD_CUR"
  CD_COUNT=$((CD_COUNT + 1))
  local e unres p viacdp="" cdp known ent maybe=0
  local -a ents
  if _nonliteral "$target"; then _dir_unknown "cd '$target'"; return 0; fi
  local tcd=0
  case "$target" in '~'|'~/'*) tcd=1 ;; esac
  _expand_path "$target"; e="$RET"; unres="$RETUNRES"
  # After && / || or inside if / while / until / for / select / case, the cd
  # may not run at all: the shell may still be where it was (like a cd that
  # fails). A { … } group always runs.
  _cd_maybe && maybe=1
  # A relative target from a directory that is already unknown stays unknown,
  # and so does any cd from there that may not run.
  if [[ "$oldun" == "1" ]] && (( maybe )) || [[ "$oldun" == "1" && "$e" != /* ]]; then
    OLD_CUR="?"
    (( tcd )) && { TILDE_CD=1; TILDE_CD_EVER=1; }
    return 0
  fi
  # CDPATH applies to a relative target that does not start with . or ..
  if [[ "$unres" == "0" && "$e" != /* && "$e" != . && "$e" != .. && "$e" != ./* && "$e" != ../* ]]; then
    known=1; cdp=""
    if _var_get CDPATH; then cdp="$RET"
    elif [[ "$CDPATH_TAINT" == "1" ]] || _var_is_danger CDPATH; then known=0
    else cdp="${CDPATH:-}"
    fi
    if (( ! known )); then
      _dir_unknown "cd '$target' (CDPATH may have changed on this line)"; return 0
    elif [[ -n "$cdp" ]]; then
      # Split on : by hand (read would stop at a newline inside an entry).
      local crest="$cdp:"; ents=()
      while [[ -n "$crest" ]]; do ents+=("${crest%%:*}"); crest="${crest#*:}"; done
      for ent in "${ents[@]}"; do
        [[ -z "$ent" ]] && ent="$CURDIR"
        [[ "$ent" != /* ]] && ent="$CURDIR/$ent"
        if [[ -d "$ent/$e" ]]; then viacdp="$ent/$e"; break; fi
      done
    fi
  fi
  if [[ "$unres" == "1" ]]; then _dir_unknown "cd '$target'"; return 0; fi
  if [[ -n "$viacdp" ]]; then p="$viacdp"; else p="$e"; [[ "$p" != /* ]] && p="$CURDIR/$p"; fi
  # p as written (a physical cd resolves its .. through symlinks); plog the
  # logical result (.. dropped textually, as cd -L does). CURDIR is always
  # kept logical-normalised, so either reading starts from the right place.
  local praw="$p" plog
  _lexnorm "$p"; plog="$RET"; p="$plog"
  # cd -P (or physical mode) resolves .. through symlinks: <wt>/link/.. may be
  # in another checkout. With physical mode merely possible, a target whose
  # logical and physical readings differ is not followed.
  if [[ "$mode" == P ]] || { [[ "$mode" != L && "$PHYS" == 1 ]]; }; then
    local pq lq
    _phys "$praw"; pq="$RET"
    if [[ "$mode" == P ]]; then
      [[ -n "$pq" ]] && p="$pq"
    else
      _phys "$plog" L; lq="$RET"
      if [[ "$pq" != "$lq" ]]; then
        _dir_unknown "cd '$target' (physical mode may resolve it elsewhere)"; return 0
      fi
    fi
  fi
  # Whether the cd succeeds, and where it lands, the way bash decides:
  # - cd -P: the target as written, resolved physically (p is already that);
  # - cd -L (default): logically when every normalised prefix before a .. is
  #   a directory and the normalised result is one; otherwise bash falls
  #   back to chdir() on the target as written, which the kernel resolves
  #   physically (cd -L <x>/link/../foo/.. can land beside link's target);
  # - otherwise it fails (cd <x>/missing/..), unless mkdir / git worktree add
  #   made the directories on this line.
  local reach=0
  if [[ "$mode" == P ]]; then
    if [[ -d "$praw" ]] || _was_created "$p"; then reach=1; fi
  elif _walk_ok "$praw" && { [[ -d "$p" ]] || _was_created "$p"; }; then
    reach=1
  elif [[ -d "$praw" ]]; then
    _phys "$praw"; [[ -n "$RET" ]] && { p="$RET"; reach=1; }
  fi
  if (( ! maybe && reach )); then
    _nearest_dir "$p"; CURDIR="$RET"; DIR_UNRESOLVED=0; DIR_DANGER=0; DIR_WHY=""
    # Only an absolute target settles where we are; a relative one may be
    # relative to DIR_ALT. Settling also ends a dependency on an earlier cd ~
    # (a cd that may fail does not).
    [[ "$e" == /* ]] && { DIR_ALT=""; TILDE_CD=0; }
    if [[ "$oldun" == "1" ]]; then OLD_CUR="?"; else OLD_CUR="$old"; fi
  else
    # bash's cd fails here unless something this guard does not model creates
    # the directory first (or it may not run); the shell may then still be
    # where it was, and OLDPWD keeps its earlier value.
    _alt_add "$old"
    ALT_GUARD=0; [[ "$LX_TERM" == and ]] && ALT_GUARD=1
    _nearest_dir "$p"; CURDIR="$RET"
    DIR_UNRESOLVED="$oldun"; DIR_DANGER="$olddg"
    if [[ "$oldun" == "1" || "$prevold" != "$old" ]]; then OLD_CUR="?"; else OLD_CUR="$old"; fi
  fi
  (( FN_SEEN )) && _fn_dir
  (( tcd )) && { TILDE_CD=1; TILDE_CD_EVER=1; }
  return 0
}

# Return to a directory the line visited earlier (`cd -`, `popd`). The old
# model ignored these, so a main checkout we are leaving stays a possibility.
_cd_back() { # $1 directory, or "?" when unknown
  local old="$CURDIR" oldun="$DIR_UNRESOLVED"
  CD_COUNT=$((CD_COUNT + 1))
  if _cd_maybe; then
    # It may not run: from an unknown directory we stay unknown; otherwise the
    # shell may still be here, and OLDPWD / the stack are no longer certain.
    OLD_CUR="?"; DIRSTK_TAINT=1
    (( TILDE_CD_EVER )) && TILDE_CD=1
    [[ "$oldun" == "1" ]] && return 0
    if [[ "$1" == "?" || -z "$1" ]]; then
      DIR_UNRESOLVED=1; DIR_DANGER=1
      DIR_WHY="cd - / pushd / popd to a directory this guard cannot tell"
    else
      _alt_add "$old"; ALT_GUARD=0; [[ "$LX_TERM" == and ]] && ALT_GUARD=1
      CURDIR="$1"
    fi
    (( FN_SEEN )) && _fn_dir
    return 0
  fi
  # The directory returned to may be one a cd ~ reached (not tracked per entry).
  (( TILDE_CD_EVER )) && TILDE_CD=1
  if [[ "$1" == "?" || -z "$1" ]]; then
    DIR_UNRESOLVED=1; DIR_DANGER=1
    DIR_WHY="cd - / pushd / popd to a directory this guard cannot tell"
  else
    CURDIR="$1"; DIR_UNRESOLVED=0; DIR_DANGER=0; DIR_WHY=""
    if _dir_is_main "$old"; then _alt_add "$old"; ALT_GUARD=0; fi
  fi
  (( FN_SEEN )) && _fn_dir
  if [[ "$oldun" == "1" ]]; then OLD_CUR="?"; else OLD_CUR="$old"; fi
  return 0
}

_has_inplace_flag() { # $@ args -> 0 when a sed/perl in-place flag is present
  local a
  for a in "$@"; do
    case "$a" in
      --in-place*) return 0 ;;
      --) return 1 ;;
      -*) [[ "$a" =~ ^-[A-Za-z]*i ]] && return 0 ;;
    esac
  done
  return 1
}

_last_nonflag() { # $@ -> RET last non-option argument, RETCOUNT how many there were
  local a last=""
  RETCOUNT=0
  for a in "$@"; do
    case "$a" in -*) ;; *) last="$a"; RETCOUNT=$((RETCOUNT + 1)) ;; esac
  done
  RET="$last"
}

_inspect_cmd() {
  local -a w
  local -a r o h
  w=("${IC_WORDS[@]}")
  r=("${IC_REDIRS[@]}")
  o=("${IC_OTHER[@]}")
  h=("${IC_HSTR[@]}")
  local -a wq
  wq=("${IC_WQ[@]}")
  local n=${#w[@]}
  local i=0 x base t j a prefixed=0 extprefix=0 mode kwok=1 iskw=0 cop=0
  IC_OPENED=0

  # ${D:=…} / ${D=…} anywhere in the command assign D before anything is judged.
  _scan_default_assigns "${r[@]}" "${o[@]}" "${h[@]}" "${w[@]}"

  # Redirection targets are writes wherever the command runs.
  for t in "${r[@]}"; do
    _check_dest "$t" redir
  done

  (( n == 0 )) && return 0

  # Shell-state taints a mention sets; put back below if the command turns out
  # to run in a child (before a | or &, after env / sudo / …).
  local sv_opt="$OLDPWD_TAINT" sv_dst="$DIRSTK_TAINT" sv_cdp="$CDPATH_TAINT" sv_home="$HOME_TAINT" sv_sot="$SHOPTS_TAINT"
  _poison_mentions "${w[@]}"

  # Strip variable assignments and command prefixes (env, sudo, xargs, …).
  while (( i < n )); do
    x="${w[i]}"
    # In a shell assignment position a quoted "D=x" is the command name (bash
    # looks up a command "D=x"); D keeps its value, though _poison_mentions has
    # already stopped trusting it. After env / sudo / …, quoting does not
    # matter: env "D=x" cmd still sets D and runs cmd.
    # NAME=…, NAME+=…, NAME[i]=… are all assignment words.
    if [[ "$x" =~ ^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?= ]] && { (( prefixed )) || [[ "${wq[i]:-0}" != 1 ]]; }; then
      kwok=0; i=$((i + 1)); continue
    fi
    base="${x##*/}"
    # A reserved word is one only when unquoted, without a path, and first in
    # the command (after ! or time, or another reserved word): "if", \fi,
    # `command if` and `D=1 if` are ordinary command names.
    iskw=0
    [[ "$kwok" == 1 && "${wq[i]:-0}" != 1 && "$x" == "$base" ]] && iskw=1
    case "$base" in
      then|do|else|elif|if|while|until|'{'|'}')
        (( iskw )) || break
        case "$base" in
          if) CTRL_DEPTH=$((CTRL_DEPTH + 1)); _ctrl_open if; IC_OPENED=1 ;;
          while|until) CTRL_DEPTH=$((CTRL_DEPTH + 1)); _ctrl_open loop; IC_OPENED=1 ;;
          '{')
            # After && / ||, the whole group may not run, not just its first command.
            if [[ "$NEXT_COND" == "1" && "$IC_OPENED" == 0 ]]; then
              CTRL_DEPTH=$((CTRL_DEPTH + 1)); _ctrl_open brace; CTRL_STK[${#CTRL_STK[@]}-1]+=":d"
            else
              _ctrl_open brace
            fi
            IC_OPENED=1 ;;
          '}')
            if _ctrl_close brace && [[ "$RET" == *:d ]] && (( CTRL_DEPTH > 0 )); then
              CTRL_DEPTH=$((CTRL_DEPTH - 1))
            fi ;;
        esac
        LINE_CTRL=1; i=$((i + 1)); continue ;;
      fi|done|esac)
        # A closer may be followed by another reserved word with no separator
        # (`if while …; done then cd X; fi`, `case x in esac then …`): what
        # follows it is still in command position, and is inspected.
        (( iskw )) || break
        local ck=if
        [[ "$base" == done ]] && ck=loop
        [[ "$base" == esac ]] && ck=case
        if _ctrl_close "$ck" && (( CTRL_DEPTH > 0 )); then CTRL_DEPTH=$((CTRL_DEPTH - 1)); fi
        LINE_CTRL=1; i=$((i + 1)); continue ;;
      case)
        # `case WORD in esac` is a whole (empty) case statement, after any
        # prefix (`! case x in esac`, `time -p case …`, `if case … esac then`):
        # what follows esac is a command, never a pattern list.
        (( iskw )) || break
        if [[ "${w[$((i + 2))]:-}" == in && "${wq[$((i + 2))]:-0}" != 1 \
              && "${w[$((i + 3))]:-}" == esac && "${wq[$((i + 3))]:-0}" != 1 ]]; then
          LINE_CTRL=1; i=$((i + 4)); continue
        fi
        break ;;
      coproc)
        # coproc [NAME] COMMAND runs COMMAND in a child shell; the word after
        # it is still in command position (a reserved word stays one).
        (( iskw )) || break
        prefixed=1; cop=1; i=$((i + 1))
        if [[ "${w[i]:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
          case "${w[$((i + 1))]:-}" in
            '{'|if|while|until|for|select|case) i=$((i + 1)) ;;
          esac
        fi
        continue ;;
      env|sudo|doas|nohup|nice|ionice|stdbuf|setsid)
        # These run the command as a new process: a cd there moves nothing here.
        prefixed=1; extprefix=1; kwok=0; i=$((i + 1)); continue ;;
      time|'!'|'('|')')
        # The reserved words time and ! keep the next word in command position;
        # a quoted / pathed "time" is the program (a separate process), and a
        # quoted "!" is an ordinary command name.
        if (( iskw )) || [[ "$base" == '(' || "$base" == ')' ]]; then
          prefixed=1; i=$((i + 1))
          # The reserved word time takes -p (and --): the next word is still
          # in command position (`time -p case x in esac`).
          if [[ "$base" == time ]] && (( iskw )); then
            while [[ "${w[i]:-}" == -p || "${w[i]:-}" == -- ]]; do i=$((i + 1)); done
          fi
          continue
        fi
        if [[ "$base" == time ]]; then prefixed=1; extprefix=1; kwok=0; i=$((i + 1)); continue; fi
        break ;;
      command|builtin|exec)
        prefixed=1; kwok=0; i=$((i + 1)); continue ;;
      timeout)
        prefixed=1; extprefix=1; kwok=0; i=$((i + 1))
        while (( i < n )) && [[ "${w[i]}" == -* ]]; do i=$((i + 1)); done
        i=$((i + 1)); continue ;;
      xargs)
        prefixed=1; extprefix=1; kwok=0; i=$((i + 1))
        while (( i < n )) && [[ "${w[i]}" == -* ]]; do
          case "${w[i]}" in
            -n|-I|-P|-L|-s|-a|-d|-E) i=$((i + 2)) ;;
            *) i=$((i + 1)) ;;
          esac
        done
        continue ;;
    esac
    break
  done
  # A command made only of assignments sets them in this shell (see
  # _assign_mode). Prefix assignments (`X=1 cmd`, `env X=1`) are never bound:
  # bash expands the command's own words before X is set, and X does not
  # outlive the command.
  _assign_mode; mode="$RET"
  (( prefixed )) && mode=skip
  if (( i >= n )); then
    # Only assignments: in a child (before a | or &, or env X=…), none of
    # them, nor the taints their mention set, reach this shell.
    if [[ "$LX_TERM" == pipe || "$LX_TERM" == bg ]] || (( extprefix || cop )); then
      OLDPWD_TAINT="$sv_opt"; DIRSTK_TAINT="$sv_dst"; CDPATH_TAINT="$sv_cdp"; HOME_TAINT="$sv_home"; SHOPTS_TAINT="$sv_sot"
    fi
    for ((j = 0; j < n; j++)); do
      [[ "${w[j]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && _assign "${w[j]}" "$mode"
    done
    return 0
  fi

  local name="${w[i]}"
  base="${name##*/}"
  local -a args
  args=("${w[@]:$((i + 1))}")

  # With lastpipe, the last member of a pipeline runs in this shell.
  # child: certainly not this shell (a pipeline member before a `|`, a
  # background job, a separate program). lastm: a pipeline's last member,
  # which runs in this shell under lastpipe (always in zsh / ksh) and in a
  # child otherwise — not followed, so a cd there leaves the directory unknown.
  local child=0 lastm=0
  if [[ "$LX_TERM" == pipe || "$LX_TERM" == bg ]]; then child=1
  elif [[ "$NEXT_PIPE" == "1" && "$IC_OPENED" == 0 ]]; then lastm=1
  fi
  (( extprefix || cop )) && child=1
  # A command name with a slash (/usr/bin/cd, $X/cd) is a program, not the
  # builtin: it cannot move this shell.
  [[ "$name" == */* ]] && child=1
  (( child )) && lastm=0
  if (( child )); then
    OLDPWD_TAINT="$sv_opt"; DIRSTK_TAINT="$sv_dst"; CDPATH_TAINT="$sv_cdp"; HOME_TAINT="$sv_home"; SHOPTS_TAINT="$sv_sot"
  fi
  IC_CHILD="$child"

  # Prefix assignments before a POSIX special builtin can persist in this
  # shell (`D=x export D`). Never bind them, but track their danger.
  case "$base" in
    export|readonly|eval|set|unset|shift|trap|exec|.|:|return|exit|break|continue|times)
      for ((j = 0; j < i; j++)); do
        [[ "${w[j]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && _var_poison "${w[j]%%=*}" "${w[j]#*=}"
      done ;;
  esac

  # Builtins that write a variable no argument names (bash 3.2 has no ;;&).
  # A here-string gives read / mapfile a value we can see: judge the names it
  # fills against it (read -r D <<< <main>).
  if (( ${#h[@]} > 0 )); then
    case "$base" in
      read|mapfile|readarray)
        local -a rnames=()
        local hv first skipnext=0
        for ((j = 0; j < ${#args[@]}; j++)); do
          a="${args[j]}"
          if (( skipnext )); then skipnext=0; continue; fi
          case "$a" in
            -a) rnames+=("${args[$((j + 1))]}"); j=$((j + 1)) ;;
            -[dinNptuOsCc]) skipnext=1 ;;
            -*) : ;;
            *) rnames+=("$a") ;;
          esac
        done
        [[ "$base" == read ]] && rnames+=(REPLY)
        [[ "$base" != read ]] && rnames+=(MAPFILE)
        for x in "${rnames[@]}"; do
          [[ "$x" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
          for hv in "${h[@]}"; do
            first="${hv#"${hv%%[![:space:]]*}"}"; first="${first%%[[:space:]]*}"
            _var_poison "$x" "$hv"; _var_poison "$x" "$first"
          done
        done ;;
    esac
  fi

  case "$base" in
    read|select)       _var_get REPLY && _var_poison REPLY ;;
    mapfile|readarray) _var_get MAPFILE && _var_poison MAPFILE ;;
    getopts)
      _var_get OPTARG && _var_poison OPTARG
      _var_get OPTIND && _var_poison OPTIND ;;
  esac

  case "$base" in
    export|declare|typeset|local|readonly)
      # readonly / declare -r: a later assignment to the name fails in bash,
      # but would look like a re-binding here.
      local ro=0
      [[ "$base" == readonly ]] && ro=1
      for a in "${args[@]}"; do
        [[ "$base" != export && "$a" =~ ^[-+][A-Za-z]*r ]] && ro=1
        # declare -n makes a nameref: later writes to it land in another variable.
        if [[ "$a" =~ ^-[A-Za-z]*n ]]; then _var_clear_all; return 0; fi
        # `declare "$N=…"`: the target name itself is an expansion.
        _subst_vars "${a%%=*}"
        if [[ "$RET" == *'$'* ]]; then _var_clear_all; return 0; fi
        # Options can transform the stored value (-l lowercases, -u uppercases,
        # -i evaluates arithmetic, -a/-A make arrays): don't cache the literal.
        [[ "$a" == [-+]* && "$mode" == bind ]] && mode=poison
      done
      # `local` outside a function fails and leaves the old value in place.
      [[ "$base" == local && "$mode" == bind ]] && mode=poison
      for a in "${args[@]}"; do
        [[ "$a" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && _assign "$a" "$mode"
      done
      # -l / -u / -c change case, -i evaluates arithmetic, -a / -A make arrays:
      # what bash stores is not the literal assigned, now or later on the line.
      # Such a name is never bound again and is DANGER (any use of it blocks).
      local xattr=0
      for a in "${args[@]}"; do
        # (+l etc. removes an attribute: no transform from it.)
        [[ "$base" != export && "$a" =~ ^-[A-Za-z]*[luciaA] ]] && xattr=1
      done
      (( child )) && xattr=0    # before a | or &: a child shell's attributes
      # -p only displays (declare -ip D); -f / -F name functions, not variables.
      # Options end at the first operand or --: `declare -l D -p` is -l.
      for a in "${args[@]}"; do
        [[ "$a" == -- || "$a" != [-+]* ]] && break
        [[ "$a" =~ ^-[A-Za-z]*[pfF] ]] && xattr=0
      done
      if (( xattr )); then
        for a in "${args[@]}"; do
          [[ "$a" == [-+]* ]] && continue
          x="${a%%=*}"
          [[ "$x" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
          _var_has_attr "$x" || ATTR_N+=("$x")
          _var_is_danger "$x" || VAR_D+=("$x")
          _forget "$x"
        done
      fi
      if (( ro )); then
        _unmodelled "$base${args[0]:+ ${args[0]}} (a read-only variable: later assignments to it fail)"
        _var_clear_all
      fi
      return 0
      ;;
    fi|done|esac|for|case|select|function)
      (( iskw )) || return 0    # quoted / prefixed: an ordinary command name
      LINE_CTRL=1
      case "$base" in
        for|select) CTRL_DEPTH=$((CTRL_DEPTH + 1)); _ctrl_open loop; IC_OPENED=1 ;;
        case) CTRL_DEPTH=$((CTRL_DEPTH + 1)); _ctrl_open case; IC_OPENED=1; CASE_OPENED=1 ;;
        fi|done|esac)
          local ck=if
          [[ "$base" == done ]] && ck=loop
          [[ "$base" == esac ]] && ck=case
          if _ctrl_close "$ck" && (( CTRL_DEPTH > 0 )); then CTRL_DEPTH=$((CTRL_DEPTH - 1)); fi ;;
      esac
      case "$base" in
        for|select)
          # After the loop the variable holds one of the listed words (or of
          # "$@" when there is no `in`).
          if [[ "${args[0]}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            if [[ "${args[1]}" == in ]]; then
              for ((j = 2; j < ${#args[@]}; j++)); do _var_poison "${args[0]}" "${args[j]}"; done
            elif [[ "$POS_DANGER" == "1" ]]; then
              _var_is_danger "${args[0]}" || VAR_D+=("${args[0]}")
            fi
          fi ;;
        function)
          _unmodelled "a function definition"
          _fn_taint ;;
      esac
      ;;
    alias)
      # With expand_aliases, a later line runs the alias's text instead. In a
      # child shell (before a | or &) there is no later line.
      (( child )) && return 0
      for a in "${args[@]}"; do
        if [[ "$a" == *=* ]]; then
          _unmodelled "alias"
          _script_text "${a#*=}"; _analyze_deferred "$RET"
          _fn_taint
        fi
      done
      return 0 ;;
    enable)
      (( child )) && return 0
      _unmodelled "enable (it can disable builtins such as cd)"
      _fn_taint
      return 0 ;;
    shopt)
      (( child )) && return 0
      # cdable_vars lets `cd NAME` go to $NAME's value.
      for a in "${args[@]}"; do
        if [[ "$a" == cdable_vars ]]; then _unmodelled "shopt cdable_vars"; _fn_taint; fi
        # A computed option name ({cdable_vars,x}, cdable*, $X) may be it.
        if [[ "$a" != -* ]] && _nonliteral "$a"; then
          _unmodelled "shopt with a computed option name"; _fn_taint
        fi
      done
      return 0 ;;
    trap)
      # trap 'CMD' SIG… runs CMD later, in this shell.
      local -a targs=()
      for ((j = 0; j < ${#args[@]}; j++)); do
        case "${args[j]}" in
          --) targs=("${args[@]:$((j + 1))}"); break ;;
          -[lpP]) ;;
          *) targs=("${args[@]:j}"); break ;;
        esac
      done
      if (( ${#targs[@]} >= 2 )) && [[ "${targs[0]}" != - && -n "${targs[0]}" ]] && (( child )); then
        # In a child shell the handler runs there (on its exit, in this state):
        # judge its writes, nothing it does reaches this shell.
        local tcdc="$CD_COUNT"
        _script_text "${targs[0]}"; _analyze_deferred "$RET"
        CD_COUNT="$tcdc"
        return 0
      fi
      if (( ${#targs[@]} >= 2 )) && [[ "${targs[0]}" != - && -n "${targs[0]}" ]]; then
        _unmodelled "trap (its command runs later in this shell)"
        local cdc="$CD_COUNT"
        _script_text "${targs[0]}"; _analyze_deferred "$RET"
        # A DEBUG / RETURN / ERR handler (or a signal) can run before any later
        # command on the line: if it changes directory, the directory is unknown.
        # An EXIT handler runs only when the shell exits (judged again then).
        local midline=0 sg
        for sg in "${targs[@]:1}"; do
          case "$sg" in EXIT|exit|SIGEXIT|0) ;; *) midline=1 ;; esac
        done
        # An EXIT-only handler's directory changes do not count as changes now.
        (( midline )) || CD_COUNT="$cdc"
        if (( midline )); then
          [[ "$CD_COUNT" != "$cdc" ]] && _dir_lost "trap '${targs[0]}' (its handler changes directory)"
          [[ "$DEF_DST" == 1 ]] && DIRSTK_TAINT=1
          [[ "$DEF_OPT" == 1 ]] && OLDPWD_TAINT=1
          [[ "$DEF_PHYS" == 1 ]] && PHYS=1
          [[ "$DEF_SOT" == 1 ]] && SHOPTS_TAINT=1
          for x in "${DEF_AT[@]}"; do
            _var_has_attr "$x" || ATTR_N+=("$x")
            _var_is_danger "$x" || VAR_D+=("$x")
          done
        fi
        (( DEPTH == 1 )) && DEFERRED+=("$RET")
      fi
      return 0 ;;
    set)
      # set -r: restricted mode, where cd fails. Non-option words replace the
      # positional parameters. In a child shell, none of it reaches here.
      (( child )) && return 0
      local pos=0
      for ((j = 0; j < ${#args[@]}; j++)); do
        a="${args[j]}"
        if (( pos )); then _value_risky "$a" && POS_DANGER=1; continue; fi
        case "$a" in
          --|-|+) pos=1 ;;
          -o|+o)
            j=$((j + 1))
            # -o physical turns it on (+o turns it off); a computed name may be either.
            { [[ "$a" == -o && "${args[j]:-}" == physical ]] || _nonliteral "${args[j]:-}"; } && PHYS=1
            [[ "$a" == +o && "${args[j]:-}" == physical ]] && ! _cd_maybe && PHYS=0 ;;
          -*r*) _unmodelled "set -r (restricted mode: cd fails)"; _fn_taint ;;
          -*P*) PHYS=1 ;;
          +*P*) _cd_maybe || PHYS=0 ;;   # off, unless it may not run
          [-+]*) : ;;
          *) pos=1; _value_risky "$a" && POS_DANGER=1 ;;
        esac
      done
      return 0 ;;
    touch)
      # From main, ANY computed argument blocks (rule 4): which words are
      # option values depends on GNU option grammar (clusters, --,
      # abbreviations, POSIXLY_CORRECT), which is not modelled. Its operands
      # are destinations, judged like a redirection's (relative ones against
      # the tracked directory).
      for a in "${args[@]}"; do _check_literal "$a"; done
      _check_operands "-d -r -t --date --reference" "${args[@]}"
      return 0 ;;
    dd)
      for a in "${args[@]}"; do
        case "$a" in of=*) _check_literal "${a#of=}"; _check_dest "${a#of=}" ;; esac
      done
      return 0 ;;
    rmdir|rm|unlink)
      _check_operands "" "${args[@]}"
      return 0 ;;
    truncate|shred)
      _check_operands "-s -r -n --size --reference --iterations --random-source" "${args[@]}"
      return 0 ;;
    chmod|chown|chgrp)
      # The first operand is the mode / owner, unless --reference or a mode
      # written like an option (chmod -x f).
      local cfirst=1
      for a in "${args[@]}"; do
        [[ "$a" == --reference* || ( "$base" == chmod && "$a" =~ ^-[rwxXstugoa]+$ ) ]] && cfirst=0
      done
      _operands "" "${args[@]}"
      for ((j = cfirst; j < ${#OPERANDS[@]}; j++)); do _check_dest "${OPERANDS[j]}"; done
      return 0 ;;
    sort|curl|wget)
      _check_outputs "$base" "${args[@]}"
      return 0 ;;
    mkdir)
      # A directory created here makes a later cd into it succeed. From main,
      # any computed argument blocks, as for touch; its operands are
      # destinations.
      local skipm=0 mp=0
      for a in "${args[@]}"; do _check_literal "$a"; done
      _check_operands "-m --mode" "${args[@]}"
      for a in "${args[@]}"; do
        [[ "$a" == --parents || "$a" =~ ^-[A-Za-z]*p ]] && mp=1
      done
      # Only a mkdir that certainly runs counts (not after && / || or in an
      # if / loop), and a relative one only from a known directory.
      _cd_maybe && return 0
      for a in "${args[@]}"; do
        if (( skipm )); then skipm=0; continue; fi
        case "$a" in
          -m) skipm=1 ;;
          -*) : ;;
          *) _expand_path "$a"
             if [[ "$RETUNRES" == "0" ]]; then
               x="$RET"
               if [[ "$x" != /* ]]; then
                 [[ "$DIR_UNRESOLVED" == 1 ]] && continue
                 x="$CURDIR/$x"
               fi
               # Without -p, mkdir fails unless the parent exists already.
               if (( ! mp )); then
                 _lexnorm "$x/.."
                 [[ -d "$RET" ]] || _was_created_exact "$RET" || continue
               fi
               _record_created "$x"
             fi ;;
        esac
      done
      return 0 ;;
    printf|read|readarray|mapfile|unset|getopts|let|wait)
      # These can write a variable named by an argument (printf and wait only
      # with -v / -p). If an argument still holds an unresolved expansion, the
      # target is unknown: drop everything.
      local writes=1
      if [[ "$base" == printf || "$base" == wait ]]; then
        writes=0
        for a in "${args[@]}"; do
          [[ "$a" == --* ]] && break
          [[ "$a" =~ ^-[A-Za-z]*[vp] ]] && writes=1
        done
      fi
      (( writes )) && for a in "${args[@]}"; do
        _subst_vars "$a"
        if [[ "$RET" == *'$'* ]]; then _var_clear_all; break; fi
      done
      # printf -v NAME FMT ARGS…: NAME may hold any argument, or FMT with its
      # %s filled in (printf -v D '%s/%s' /path repo).
      if [[ "$base" == printf ]]; then
        local pv="" k=0
        while (( k < ${#args[@]} )); do
          a="${args[k]}"
          case "$a" in
            --) k=$((k + 1)); break ;;
            -v) pv="${args[$((k + 1))]}"; k=$((k + 2)) ;;
            -v*) pv="${a#-v}"; k=$((k + 1)) ;;
            -*) k=$((k + 1)) ;;
            *) break ;;
          esac
        done
        _subst_vars "$pv"; pv="${RET%%\[*}"   # printf -v "$N": the name N holds
        if [[ "$pv" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
          local -a pa=("${args[@]:k}")
          local built="${pa[0]}" pi=1
          for x in "${pa[@]}"; do _var_poison "$pv" "$x"; done
          while [[ "$built" == *%s* ]] && (( pi < ${#pa[@]} )); do
            built="${built/\%s/${pa[pi]}}"; pi=$((pi + 1))
          done
          _var_poison "$pv" "$built"
        fi
      fi
      ;;
    source|.)
      _var_clear_all   # a sourced file can set anything
      # It runs in this shell and may cd anywhere.
      (( child )) || _dir_lost "$base ${args[0]:-} (a sourced file may cd anywhere)"
      ;;
    cd|pushd|popd)
      # Before a `|` or `&` the cd runs in a child shell, and after env / sudo
      # / xargs / … it is a separate process: this shell does not move.
      (( child )) && return 0
      if (( lastm )); then
        # It may run here: the directory, OLDPWD and the stack are uncertain.
        _dir_lost "$base at the end of a pipeline (it may run in this shell or a child)"
        return 0
      fi
      ;;
  esac
  # A command name built from an expansion ($X, "$(…)") may itself be cd.
  if (( ! child )) && [[ "$name" == *'$'* || "$name" == *'`'* ]]; then
    _shown "$name"
    _dir_lost "a command named by an expansion ('$RET'): it may be cd"
  fi
  case "$base" in
    cd|pushd)
      # bash's cd takes -L -P -e -@; pushd takes -n. Option parsing stops at
      # the first operand (or --); every word after that is an operand.
      local target="" ntgt=0 dashdash=0 bad="" sawopt=0 nocd=0 rot=0 lp=""
      for a in "${args[@]}"; do
        if (( dashdash )); then
          ntgt=$((ntgt + 1)); (( ntgt == 1 )) && target="$a"; continue
        fi
        case "$a" in
          --) dashdash=1; sawopt=1 ;;
          -) ntgt=1; target=-; dashdash=1 ;;
          [-+][0-9]*)
            if [[ "$base" == pushd ]]; then rot=1
            elif [[ "$a" == -* ]]; then bad="$a"
            else ntgt=1; target="$a"; dashdash=1; fi ;;
          -*)
            sawopt=1
            if [[ "$base" == cd ]]; then
              [[ "$a" =~ ^-[LPe@]+$ ]] || bad="$a"
              # The last of -L / -P wins.
              local lpx="${a//[^LP]/}"; [[ -n "$lpx" ]] && lp="${lpx: -1}"
            else [[ "$a" =~ ^-n+$ ]] && nocd=1 || bad="$a"; fi ;;
          *) ntgt=1; target="$a"; dashdash=1 ;;
        esac
      done
      # Anything bash's cd refuses, or that this guard cannot follow, leaves
      # the directory unknown: never resolve it, fail closed (2026-11-23).
      # A pushd this guard cannot follow, or one that may fail (a relative or
      # missing directory), may or may not have pushed: the stack is uncertain.
      if [[ "$base" == pushd ]] && (( ! nocd && ! rot )); then
        if [[ -n "$bad" ]] || (( ntgt != 1 )) || [[ -z "$target" ]] || _nonliteral "$target" \
           || ! { [[ "$target" == /* && -d "$target" ]] || _was_created "${target%/}"; }; then
          DIRSTK_TAINT=1
        fi
      fi
      if [[ -n "$bad" ]]; then
        _dir_unknown "$base $bad (an option $base does not take: it fails)"; return 0
      fi
      if (( ntgt > 1 )); then
        _dir_unknown "$base with more than one directory (it fails)"; return 0
      fi
      if [[ "$base" == pushd ]]; then
        # pushd -n only edits the stack; +N / -N or no directory rotates it.
        # -n edits the stack without changing directory (inserting DIR, or
        # rotating with +N / -N): the stack is uncertain from here on.
        if (( nocd )); then DIRSTK+=("?"); DIRSTK_TAINT=1; return 0; fi
        # Rotation / a swap reorders the stack too.
        if (( rot || ntgt == 0 )); then DIRSTK_TAINT=1; _cd_back "?"; return 0; fi
      fi
      if (( ntgt == 0 )); then
        # A bare cd goes to $HOME; cd -L / cd -- (options only) are not followed.
        if (( sawopt )); then _dir_unknown "$base with options but no directory"; return 0; fi
        target='~'
      elif [[ -z "$target" ]]; then
        _dir_unknown "$base '' (an empty directory: bash refuses it)"; return 0
      fi
      if [[ "$target" == "-" && "$base" == cd ]]; then
        if [[ -n "$OLD_CUR" && "$OLDPWD_TAINT" == 0 ]]; then _cd_back "$OLD_CUR"; else _cd_back "?"; fi
        return 0
      fi
      if _nonliteral "$target"; then
        # Built from an expansion, a glob, brace expansion or ~user: never
        # resolved, not even from bindings on this line.
        _shown "$target"
        _dir_unknown "$base '$RET' (a directory built from an expansion, a glob or ~user)"
        return 0
      fi
      if [[ "$base" == pushd ]]; then
        if [[ "$DIR_UNRESOLVED" == "1" ]]; then DIRSTK+=("?"); else DIRSTK+=("$CURDIR"); fi
        _cd_maybe && DIRSTK_TAINT=1     # it may not run: the stack is uncertain
      fi
      _cd_to "$target" "$lp"
      return 0 ;;

    dirs)
      (( child )) && return 0   # before a | or &: a child shell's stack
      # dirs -c clears the stack: popd may then fail and stay put. The other
      # options (-l -p -v, +N / -N) only display it. A computed argument may
      # be -c.
      for a in "${args[@]}"; do
        if [[ "$a" =~ ^-[A-Za-z]*c ]] || _nonliteral "$a"; then DIRSTK_TAINT=1; fi
      done
      return 0 ;;

    popd)
      local pn=0
      for a in "${args[@]}"; do
        case "$a" in
          -n) pn=1 ;;                           # stack only, no cd
          [-+][0-9]*) DIRSTK_TAINT=1; _cd_back "?"; return 0 ;;   # removes the Nth entry
          *)
            # Not -n / +N / -N as written: invalid (popd fails), or computed
            # ("$N"), which may expand to -n or +N and edit the stack.
            DIRSTK_TAINT=1
            _dir_unknown "popd $a (an argument this guard cannot follow)"; return 0 ;;
        esac
      done
      if (( pn )); then
        # popd -n drops the next entry without changing directory.
        local nn=${#DIRSTK[@]}
        if _cd_maybe; then DIRSTK_TAINT=1
        elif (( nn > 0 )); then unset "DIRSTK[$((nn - 1))]"; DIRSTK=("${DIRSTK[@]}"); fi
        return 0
      fi
      if [[ "$DIRSTK_TAINT" == 1 ]]; then _cd_back "?"; return 0; fi
      local nd=${#DIRSTK[@]}
      (( nd == 0 )) && return 0                 # empty stack: popd fails, no cd
      _cd_back "${DIRSTK[$((nd - 1))]}"
      unset "DIRSTK[$((nd - 1))]"
      DIRSTK=("${DIRSTK[@]}")
      return 0 ;;

    eval)
      # eval re-parses its arguments, quoting and all: analyse the text, but a
      # main checkout in play blocks regardless (fail closed).
      _unmodelled "eval"
      _script_text "${args[*]}"
      if (( child )); then
        # Before a `|` or `&`, eval runs in a child shell: nothing it does,
        # its directory changes included, persists here.
        local ccdc="$CD_COUNT"
        _analyze_deferred "$RET"
        CD_COUNT="$ccdc"; IC_CHILD=1
      elif (( lastm )); then
        # At the end of a pipeline it may run here or in a child.
        local lcdc="$CD_COUNT"
        _analyze_text "$RET"
        if [[ "$CD_COUNT" != "$lcdc" ]]; then
          _dir_lost "eval at the end of a pipeline (it may run in this shell or a child)"
        fi
      else
        local edir="$CURDIR" ecdc="$CD_COUNT" econd=0
        [[ "$NEXT_COND" == "1" ]] || (( CTRL_DEPTH > 0 )) && econd=1
        _analyze_text "$RET"
        # A conditional eval may not run: if it changed directory, the shell
        # may still be where it was.
        if (( econd )) && [[ "$CD_COUNT" != "$ecdc" ]]; then _alt_add "$edir"; ALT_GUARD=0; fi
      fi
      _var_clear_all
      return 0 ;;

    bash|sh|zsh|dash|ksh)
      # `bash -c` is a child process, so like a subshell its `cd` cannot move
      # this shell — analyse the script, then put the working directory back.
      # (`eval` above is deliberately NOT restored: it runs in the same shell,
      # so its `cd` really does persist.)
      # Find the command string: the first operand after a c option (-c, or a
      # cluster such as -ec). -O / -o / --rcfile take an argument.
      # A new shell starts logical unless an exported SHELLOPTS or its own
      # invocation (-P, -o physical) says otherwise.
      local cseen=0 sidx=-1 ddash=0 m cphys=0 cbase=0
      [[ "$PHYS_ENV" == 1 || "$SHOPTS_TAINT" == 1 ]] && cbase=1
      for ((j = 0; j < ${#args[@]}; j++)); do
        a="${args[j]}"
        if (( ! ddash )); then
          case "$a" in
            -O|+O|-o|+o|--rcfile|--init-file)
              j=$((j + 1))
              # In order: the last of -o / +o physical wins (a computed name may be it).
              if [[ "$a" == -o ]] && { [[ "${args[j]:-}" == physical ]] || _nonliteral "${args[j]:-}"; }; then cphys=1
              elif [[ "$a" == +o && "${args[j]:-}" == physical ]]; then cphys=0; fi
              continue ;;
            --) ddash=1; continue ;;
            --*) continue ;;
            [-+]*)
              [[ "$a" == -*c* ]] && cseen=1
              [[ "$a" == -*P* ]] && cphys=1
              [[ "$a" == +*P* ]] && cphys=0
              continue ;;
          esac
        fi
        (( cseen )) && sidx=$j
        break
      done
      if (( sidx >= 0 )); then
        local sdir="$CURDIR" sunres="$DIR_UNRESOLVED" sddanger="$DIR_DANGER" swhy="$DIR_WHY"
        local salt="$DIR_ALT" sguard="$ALT_GUARD" sold="$OLD_CUR" stcd="$TILDE_CD" scdc="$CD_COUNT"
        local sdst="$DIRSTK_TAINT" sopt="$OLDPWD_TAINT"
        local -a sat=("${ATTR_N[@]}")
        local sphys="$PHYS" ssot="$SHOPTS_TAINT"
        local -a sstk=("${DIRSTK[@]}")
        # A new shell does not inherit unexported variables. Rather than
        # track export state, hide every binding while analysing the child,
        # so its expansions are unresolved (fail closed) as without bindings.
        local -a svk=("${VAR_K[@]}") svv=("${VAR_V[@]}")
        # An exported binding IS inherited: one holding a main-checkout path
        # must stay dangerous in the child, where it is hidden.
        for ((m = 0; m < ${#VAR_K[@]}; m++)); do
          [[ -n "${VAR_K[m]}" ]] && _mark_danger_if_main "${VAR_K[m]}" "${VAR_V[m]}"
        done
        # Prefix assignments (`D=x bash -c …`, `env D=x bash -c …`) are
        # exported to the child too.
        for ((m = 0; m < i; m++)); do
          if [[ "${w[m]}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            local pn="${BASH_REMATCH[1]}" pv="${BASH_REMATCH[2]}"
            # Known variables in the value count (D=$ROOT bash -c …).
            RETDANGER=0; _subst_vars "$pv"; pv="$RET"
            if [[ "$RETDANGER" == "1" ]]; then
              _var_is_danger "$pn" || VAR_D+=("$pn")
            else
              case "$pv" in
                *'$'*|'~'*|*':~'*) ;;
                *) _mark_danger_if_main "$pn" "$pv" ;;
              esac
            fi
          fi
        done
        VAR_K=(); VAR_V=()
        local snc="$NEXT_COND" snp="$NEXT_PIPE"
        # An inherited physical mode (exported SHELLOPTS) is not undone here.
        (( cbase )) && cphys=1
        NEXT_PIPE=0; NEXT_COND=0; PHYS="$cphys"
        _script_text "${args[sidx]}"; _analyze_text "$RET"
        VAR_K=("${svk[@]}"); VAR_V=("${svv[@]}")
        CURDIR="$sdir"; DIR_UNRESOLVED="$sunres"; DIR_DANGER="$sddanger"; DIR_WHY="$swhy"
        DIR_ALT="$salt"; ALT_GUARD="$sguard"; OLD_CUR="$sold"; DIRSTK=("${sstk[@]}")
        TILDE_CD="$stcd"; CD_COUNT="$scdc"; NEXT_COND="$snc"; NEXT_PIPE="$snp"
        DIRSTK_TAINT="$sdst"; OLDPWD_TAINT="$sopt"; ATTR_N=("${sat[@]}"); PHYS="$sphys"; SHOPTS_TAINT="$ssot"
        return 0
      fi
      return 0 ;;

    devcontainer-exec)
      _block_if_cwd_main "bin/devcontainer-exec"
      return 0 ;;

    rsync)
      _block_if_cwd_main "rsync"
      # `rsync SRC` with no destination LISTS src — it writes nothing, so the
      # lone argument must not be judged as a write target. Only treat the last
      # non-flag argument as a destination when there is something before it.
      _last_nonflag "${args[@]}"
      (( RETCOUNT >= 2 )) && _check_dest "$RET" remote
      return 0 ;;

    patch)
      _block_if_cwd_main "patch"
      return 0 ;;

    sed|gsed|perl)
      if _has_inplace_flag "${args[@]}"; then
        _block_if_cwd_main "$base -i (in-place edit)"
        local skip=0
        for a in "${args[@]}"; do
          if (( skip )); then skip=0; continue; fi
          case "$a" in
            -e|-f|-E|--expression|--file) skip=1; continue ;;
            -*) continue ;;
          esac
          _check_dest "$a"
        done
      fi
      return 0 ;;

    cp|mv|install|ln)
      # -t DIR / -tDIR / clustered -vt DIR / --target-directory[=]DIR name the
      # destination; every non-flag argument is then a source. Otherwise the
      # destination is the last non-flag argument.
      local tdir="" tset=0 k=0 m=${#args[@]}
      while (( k < m )); do
        a="${args[k]}"
        case "$a" in
          --) break ;;
          --target-directory=*) tdir="${a#*=}"; tset=1 ;;
          --target-directory) tdir="${args[$((k + 1))]}"; tset=1; k=$((k + 1)) ;;
          --*) : ;;
          -*)
            if [[ "$a" =~ ^-[A-Za-z]*t$ ]]; then
              tdir="${args[$((k + 1))]}"; tset=1; k=$((k + 1))
            elif [[ "$a" =~ ^-[A-Za-z]*t(.+)$ ]]; then
              tdir="${BASH_REMATCH[1]}"; tset=1
            fi ;;
        esac
        k=$((k + 1))
      done
      if (( tset )); then
        _check_dest "$tdir"
      else
        _last_nonflag "${args[@]}"
        _check_dest "$RET"
      fi
      return 0 ;;

    tee)
      for a in "${args[@]}"; do
        case "$a" in -*) continue ;; esac
        _check_dest "$a"
      done
      return 0 ;;

    git)
      local gdir="$CURDIR" gunres="$DIR_UNRESOLVED" sub="" sub2="" k=0 galt="" gcomp="" gtilde=0 gcwd=1
      local m=${#args[@]}
      _alt_active && galt="$DIR_ALT"
      while (( k < m )); do
        case "${args[k]}" in
          -C)
            [[ -z "$gcomp" ]] && _nonliteral "${args[$((k + 1))]}" && _main_in_play && gcomp="${args[$((k + 1))]}"
            case "${args[$((k + 1))]}" in '~'|'~/'*) gtilde=1; gcwd=0 ;; /*) gtilde=0; gcwd=0 ;; esac
            _abs_path "${args[$((k + 1))]}" "$CURDIR"
            if [[ "$RETUNRES" == "1" ]]; then gunres=1
            elif [[ "$gunres" == 1 && "${args[$((k + 1))]}" != /* && "${args[$((k + 1))]}" != '~'* ]]; then
              :   # relative to a directory that is already unknown
            else gunres=0; gdir="$RET"; fi
            if [[ -n "$galt" ]]; then
              if [[ "${args[$((k + 1))]}" == /* ]]; then galt=""
              else _abs_path "${args[$((k + 1))]}" "$galt"; galt="$RET"; fi
            fi
            k=$((k + 2)) ;;
          -c|--git-dir|--work-tree|--namespace|--exec-path)
            k=$((k + 2)) ;;
          -*)
            k=$((k + 1)) ;;
          *)
            sub="${args[k]}"; sub2="${args[$((k + 1))]}"; break ;;
        esac
      done
      local mutating=0
      case "$sub" in
        apply|am|cherry-pick|revert) mutating=1 ;;
        stash) [[ "$sub2" == "pop" || "$sub2" == "apply" ]] && mutating=1 ;;
        worktree)
          # git worktree add <path> creates <path>; a later cd into it succeeds.
          if [[ "$sub2" == add ]]; then
            local wk=$((k + 2)) wa
            while (( wk < m )); do
              wa="${args[wk]}"
              case "$wa" in
                -b|-B|--reason) wk=$((wk + 2)); continue ;;
                -*) wk=$((wk + 1)); continue ;;
              esac
              _abs_path "$wa" "$gdir"
              [[ "$RETUNRES" == "0" && "$gunres" == "0" ]] && _record_created "$RET"
              break
            done
          fi ;;
      esac
      if (( mutating )); then
        (( TILDE_CD && gcwd )) && TILDE_SEEN=1
        [[ "$gtilde" == 1 ]] && TILDE_SEEN=1
        if [[ -n "$gcomp" ]]; then
          _main_dir
          _block "git -C '$gcomp' $sub, a directory built from an expansion" "$RET" nonliteral
        elif [[ "$gunres" == "1" && "$gcwd" == 1 ]]; then
          _block "git $sub after $DIR_WHY" "$gdir" unresolved
        elif [[ "$gunres" == "1" ]]; then
          _block "git $sub (unresolvable target directory — fail closed)" "$gdir"
        else
          _nearest_dir "$gdir"
          if _is_main_checkout "$RET"; then
            _block "git $sub" "$RET"
          elif [[ -n "$galt" ]] && _dir_is_main "$galt"; then
            _block "git $sub (after a cd that may have failed: its target does not exist)" "$galt"
          fi
        fi
      fi
      return 0 ;;
  esac
  return 0
}

# --- lexer ------------------------------------------------------------------

_end_word() {
  (( LX_HAVE )) || return 0
  case "$LX_PEND" in
    1) LX_REDIRS+=("$LX_CUR") ;;
    2) LX_OTHER+=("$LX_CUR") ;;
    3) LX_HSTR+=("$LX_CUR") ;;
    4)
      # `>& word`: an fd (2, 1-, -) — or, for anything else, a FILE that gets
      # both stdout and stderr.
      if [[ "$LX_CUR" =~ ^[0-9]*-?$ ]]; then LX_OTHER+=("$LX_CUR"); else LX_REDIRS+=("$LX_CUR"); fi ;;
    *) LX_WORDS+=("$LX_CUR"); LX_WQ+=("$LX_QN") ;;
  esac
  LX_PEND=0; LX_CUR=""; LX_HAVE=0; LX_QN=0
}

# A word quoted or escaped before its first `=` ("D=x", 'D'=x, D\=x) is a
# command name to bash, not an assignment. The lexer drops quoting, so it
# records that here (LX_WQ, parallel to LX_WORDS).
_note_quote() {
  [[ "$LX_CUR" == *=* ]] || LX_QN=1
}

_end_cmd() {
  _end_word
  local had=${#LX_WORDS[@]} pat=0 patok=0 cparen="$LX_CPAREN"
  LX_CPAREN=0
  # A pattern list ends at `)`, continues after `|` or a newline. A command
  # ended by ; && || & is never a pattern (fail closed: never skip a command).
  case "$LX_TERM" in pipe|rparen|seq) patok=1 ;; esac
  # A pattern list has no redirections, and only `in` (after `case WORD` and a
  # newline) may end at a newline. Anything else there is a command this guard
  # lost track of: inspect it rather than skip it (fail closed).
  if (( patok )) && [[ "$CASE_PAT" != 0 && "$LX_TERM" == seq ]] && (( had > 0 )) \
     && ! [[ "$had" == 1 && "${LX_WORDS[0]}" == in && "${LX_WQ[0]:-0}" != 1 && "$CASE_PAT" == 1 ]]; then
    patok=0
  fi
  (( ${#LX_REDIRS[@]} + ${#LX_OTHER[@]} + ${#LX_HSTR[@]} > 0 )) && patok=0
  if (( had > 0 || ${#LX_REDIRS[@]} + ${#LX_OTHER[@]} + ${#LX_HSTR[@]} > 0 )); then
    # In a case statement, the words after `in` or ;; up to `)` are patterns
    # (`a|cd|fi)`), not commands; an unquoted esac there ends the case.
    if (( patok )) && { [[ "$CASE_PAT" == 2 ]] || { [[ "$CASE_PAT" == 1 ]] && ! [[ "${LX_WORDS[0]:-}" == esac && "${LX_WQ[0]:-0}" != 1 ]]; }; }; then
      pat=1
      # A pattern is expanded when bash tries it: ${D:=…} / ${D=…} there may
      # assign D in this shell (whether it ran is unknown: poisoned).
      _scan_default_assigns "${LX_WORDS[@]}"
    else
      CASE_PAT=0; CASE_OPENED=0
      IC_WORDS=("${LX_WORDS[@]}")
      IC_REDIRS=("${LX_REDIRS[@]}")
      IC_OTHER=("${LX_OTHER[@]}")
      IC_HSTR=("${LX_HSTR[@]}")
      IC_WQ=("${LX_WQ[@]}")
      _inspect_cmd
      IC_CHILD=0
      # `case WORD in [first pattern…]`. (An empty `case WORD in esac`, after
      # any prefix, never sets CASE_OPENED: _inspect_cmd closes it.)
      if (( CASE_OPENED && patok )); then pat=1; fi
    fi
  fi
  LX_WORDS=(); LX_WQ=(); LX_REDIRS=(); LX_OTHER=(); LX_HSTR=(); LX_PEND=0
  if (( pat )); then
    # `)` ends the pattern list; `|` or a newline continues it. Neither starts
    # a pipeline or an and-list for the commands after it.
    if [[ "$LX_TERM" == rparen ]]; then CASE_PAT=0; NEXT_COND=0; NEXT_PIPE=0
    elif [[ "$CASE_PAT" != 2 ]]; then CASE_PAT=1; fi
    LX_TERM=seq
    return 0
  fi
  # The commands after `cd <missing> &&` run only if that cd succeeded; the
  # first one ending in ; / || / & closes that and-list.
  if (( had > 0 )); then
    case "$LX_TERM" in seq|semi|or|bg) ALT_GUARD=0 ;; esac
  fi
  # How the NEXT command is entered. An empty command ending at a newline (the
  # line after a trailing `&&`) leaves that state alone.
  case "$LX_TERM" in
    and|or) NEXT_COND=1; NEXT_PIPE=0 ;;
    pipe)   NEXT_PIPE=1 ;;
    *)      (( had > 0 )) && { NEXT_COND=0; NEXT_PIPE=0; } ;;
  esac
  LX_TERM=seq
}

# Is the `)` at C the end of a case pattern? Yes while in a pattern list (not
# at an unquoted esac outside a leading `(`), or on `case WORD in pattern)`.
_in_case_pattern() {
  local nw=${#LX_WORDS[@]} first="${LX_WORDS[0]:-}"
  [[ -z "$first" ]] && (( LX_HAVE )) && first="$LX_CUR"
  [[ "$CASE_PAT" == 2 ]] && return 0
  if [[ "$CASE_PAT" == 1 ]]; then
    [[ "$first" == esac ]] && return 1
    return 0
  fi
  _lx_case_k && (( nw >= RET + 3 ))
}

# Where the words being lexed open `case WORD in` (after reserved-word
# prefixes such as `!`, `time -p`, `if`, `then`, `coproc`): RET = the index of
# `case`; return 1 when they do not.
_lx_case_k() {
  local k=0 nw=${#LX_WORDS[@]} prev=""
  while (( k < nw )); do
    if [[ "${LX_WQ[k]:-0}" != 1 ]]; then
      case "${LX_WORDS[k]}" in
        case)
          if [[ "${LX_WORDS[$((k + 2))]:-}" == in && "${LX_WQ[$((k + 2))]:-0}" != 1 ]]; then RET=$k; return 0; fi
          return 1 ;;
        '!'|time|'{'|'}'|if|then|else|elif|do|while|until|fi|done|esac|coproc) prev="${LX_WORDS[k]}"; k=$((k + 1)); continue ;;
        -p|--) [[ "$prev" == time ]] && { k=$((k + 1)); continue; } ;;
      esac
    fi
    return 1
  done
  return 1
}

# Restore the working directory a subshell context was entered with. A `cd`
# inside `$( … )` / backticks / `( … )` is scoped to the child shell and must
# not follow the parent out. Dynamically scoped: reads `term` and the saved
# values from the _lex_context frame that calls it.
_leave_context() {
  # A case still in its pattern list, or a compound opened here and not
  # closed: this guard lost track of the syntax. Fail closed.
  if [[ "$CASE_PAT" != 0 ]] || (( ${#CTRL_STK[@]} > ${#LX_SAVED_CS[@]} )); then PARSE_ERROR=1; fi
  [[ -z "$term" ]] && return 0
  CURDIR="$LX_SAVED_DIR"
  DIR_UNRESOLVED="$LX_SAVED_UNRES"
  DIR_DANGER="$LX_SAVED_DDANGER"; DIR_WHY="$LX_SAVED_WHY"
  DIR_ALT="$LX_SAVED_ALT"; ALT_GUARD="$LX_SAVED_GUARD"; OLD_CUR="$LX_SAVED_OLD"
  DIRSTK=("${LX_SAVED_STK[@]}"); TILDE_CD="$LX_SAVED_TCD"
  # Assignments in a subshell are scoped to it too.
  VAR_K=("${LX_SAVED_VK[@]}")
  VAR_V=("${LX_SAVED_VV[@]}")
  NEXT_COND="$LX_SAVED_NC"; NEXT_PIPE="$LX_SAVED_NP"; LX_TERM=seq
  CTRL_DEPTH="$LX_SAVED_CD"; CTRL_STK=("${LX_SAVED_CS[@]}"); CTRL_SNAP=("${LX_SAVED_CSN[@]}")
  CD_COUNT="$LX_SAVED_CDC"; DIRSTK_TAINT="$LX_SAVED_DST"; OLDPWD_TAINT="$LX_SAVED_OPT"
  CASE_PAT="$LX_SAVED_CP"; ATTR_N=("${LX_SAVED_AT[@]}"); PHYS="$LX_SAVED_PHYS"; SHOPTS_TAINT="$LX_SAVED_SOT"
}

_lex_context() { # $1 terminator: "" (EOF), ")" or "`"
  local term="$1"
  # Per-invocation lexer state. Declared `local` so nested contexts (command
  # substitutions, subshells) get their own; the _end_word/_end_cmd helpers see
  # the innermost one through bash's dynamic scoping.
  local -a LX_WORDS=()
  local -a LX_REDIRS=()
  local -a LX_OTHER=()
  local -a LX_HSTR=()
  local -a LX_WQ=()
  local LX_CUR="" LX_HAVE=0 LX_PEND=0 LX_QN=0
  local LX_SAVED_DIR="$CURDIR" LX_SAVED_UNRES="$DIR_UNRESOLVED" LX_SAVED_DDANGER="$DIR_DANGER" LX_SAVED_WHY="$DIR_WHY"
  local LX_SAVED_ALT="$DIR_ALT" LX_SAVED_GUARD="$ALT_GUARD" LX_SAVED_OLD="$OLD_CUR" LX_SAVED_TCD="$TILDE_CD"
  local -a LX_SAVED_STK=("${DIRSTK[@]}") LX_SAVED_CS=("${CTRL_STK[@]}") LX_SAVED_CSN=("${CTRL_SNAP[@]}")
  local -a LX_SAVED_AT=("${ATTR_N[@]}")
  local -a LX_SAVED_VK=("${VAR_K[@]}") LX_SAVED_VV=("${VAR_V[@]}")
  local LX_SAVED_NC="$NEXT_COND" LX_SAVED_NP="$NEXT_PIPE" LX_SAVED_CD="$CTRL_DEPTH" LX_SAVED_CDC="$CD_COUNT" LX_SAVED_DST="$DIRSTK_TAINT" LX_SAVED_OPT="$OLDPWD_TAINT" LX_SAVED_CP="$CASE_PAT" LX_SAVED_PHYS="$PHYS" LX_SAVED_SOT="$SHOPTS_TAINT"
  local line ch nx rest run
  # `( … )`, `$( … )` and backticks are a new shell: its first command is not
  # the enclosing pipeline member or and-list operand (all of it is restored
  # on leaving).
  if [[ -n "$term" ]]; then NEXT_PIPE=0; NEXT_COND=0; CASE_PAT=0; fi

  while :; do
    STEPS=$((STEPS + 1))
    if (( STEPS > MAXSTEPS )); then PARSE_ERROR=1; _end_cmd; _leave_context; return; fi

    if (( L >= ${#LINES[@]} )); then
      [[ -n "$term" ]] && PARSE_ERROR=1
      _end_cmd
      _leave_context
      return
    fi
    line="${LINES[L]}"

    if (( C >= ${#line} )); then
      _end_cmd
      if (( ${#HD[@]} > 0 )); then _consume_heredocs; fi
      L=$((L + 1)); C=0
      continue
    fi

    # Fast path: swallow a whole run of ordinary word characters at once.
    rest="${line:C}"
    if [[ "$rest" =~ $ORDRUN_RE ]]; then
      run="${BASH_REMATCH[1]}"
      if [[ -n "$run" ]]; then
        LX_CUR="$LX_CUR$run"; LX_HAVE=1; C=$((C + ${#run}))
        continue
      fi
    fi

    ch="${line:C:1}"
    case "$ch" in
      '\')
        nx="${line:$((C + 1)):1}"
        if [[ -z "$nx" ]]; then
          C=$((C + 1))                       # line continuation
        elif [[ "$nx" == '$' ]] && (( BQ == 0 )); then
          _note_quote; LX_CUR="$LX_CUR$LITD"; LX_HAVE=1; C=$((C + 2))   # \$: a literal $
        else
          # \~ at a word's start is a literal ~, not a tilde expansion.
          [[ "$nx" == '~' && -z "$LX_CUR" ]] && LX_CUR="$QTILDE"
          _note_quote; LX_CUR="$LX_CUR$nx"; LX_HAVE=1; C=$((C + 2))
        fi ;;
      "'")
        # Every $ in '…' is literal: mark it so it is never expanded.
        _note_quote; C=$((C + 1)); _read_sq
        [[ "$RET" == '~'* && -z "$LX_CUR" ]] && LX_CUR="$QTILDE"   # '~/x': a literal ~
        LX_CUR="$LX_CUR${RET//\$/$LITD}"; LX_HAVE=1 ;;
      '"')
        _note_quote; C=$((C + 1)); _read_dq
        [[ "$RET" == '~'* && -z "$LX_CUR" ]] && LX_CUR="$QTILDE"   # "~/x": a literal ~
        LX_CUR="$LX_CUR$RET"; LX_HAVE=1 ;;
      '`')
        if [[ "$term" == '`' ]]; then C=$((C + 1)); _end_cmd; _leave_context; return; fi
        C=$((C + 1)); BQ=$((BQ + 1)); _lex_context '`'; BQ=$((BQ - 1))
        LX_CUR="$LX_CUR$CMDSUB"; LX_HAVE=1 ;;
      '$')
        if [[ "${line:$((C + 1)):1}" == '(' ]]; then
          local arith=0; [[ "${line:$((C + 2)):1}" == '(' ]] && arith=1
          C=$((C + 2)); _lex_context ')'; LX_CUR="$LX_CUR$CMDSUB"; LX_HAVE=1
          (( arith )) && _var_clear_all   # $((D=0)) assigns in this shell
        elif [[ "${line:$((C + 1)):1}" == "'" ]]; then
          _note_quote; C=$((C + 2)); _read_ansi; LX_CUR="$LX_CUR$RET"; LX_HAVE=1      # $'…'
        elif [[ "${line:$((C + 1)):1}" == '"' ]]; then
          # $"…" is "…" translated through the locale: its text may change.
          _note_quote; C=$((C + 2)); _read_dq; LX_CUR="$LX_CUR$RET$QMARK"; LX_HAVE=1
        else
          LX_CUR="$LX_CUR$ch"; LX_HAVE=1; C=$((C + 1))
        fi ;;
      '#')
        if (( LX_HAVE )); then
          LX_CUR="$LX_CUR$ch"; C=$((C + 1))
        else
          C=${#line}                         # comment to end of line
        fi ;;
      ' '|$'\t')
        _end_word; C=$((C + 1)) ;;
      ';')
        LX_TERM=semi; _end_cmd; C=$((C + 1))
        # ;; ;& ;;& end a case item: what follows is the next pattern list.
        if [[ "${line:C:1}" == ";" ]]; then C=$((C + 1)); CASE_PAT=1; fi
        if [[ "${line:C:1}" == "&" ]]; then C=$((C + 1)); CASE_PAT=1; fi ;;
      '|')
        if [[ "${line:$((C + 1)):1}" == "|" ]]; then LX_TERM=or; else LX_TERM=pipe; fi
        _end_cmd; C=$((C + 1))
        case "${line:C:1}" in '|'|'&') C=$((C + 1)) ;; esac ;;
      '&')
        if [[ "${line:$((C + 1)):1}" == ">" ]]; then
          _end_word; C=$((C + 2))
          [[ "${line:C:1}" == ">" ]] && C=$((C + 1))
          LX_PEND=1
        else
          if [[ "${line:$((C + 1)):1}" == "&" ]]; then LX_TERM=and; else LX_TERM=bg; fi
          _end_cmd; C=$((C + 1))
          [[ "${line:C:1}" == "&" ]] && C=$((C + 1))
        fi ;;
      '(')
        # The optional `(` before a case pattern: `case x in (a) …`, `;; (b) …`.
        if (( ! LX_HAVE )); then
          local nw=${#LX_WORDS[@]}
          if [[ "$CASE_PAT" == 1 ]] && (( nw == 0 )); then
            C=$((C + 1)); CASE_PAT=2; continue
          fi
          if _lx_case_k && (( nw == RET + 3 )); then
            C=$((C + 1)); LX_CPAREN=1; continue
          fi
        fi
        # NAME() / function NAME(): a function definition, not a subshell.
        local fnrest="${line:$((C + 1))}" fnname="" fnre='^([[:space:]]*\))'
        if [[ "$fnrest" =~ $fnre ]]; then
          local -a fnw=("${LX_WORDS[@]}")
          (( LX_HAVE )) && fnw+=("$LX_CUR")
          [[ "${fnw[0]}" == function ]] && fnw=("${fnw[@]:1}")
          (( ${#fnw[@]} == 1 )) && [[ "${fnw[0]}" != *=* ]] && fnname="${fnw[0]}"
        fi
        if [[ -n "$fnname" ]]; then
          C=$((C + 1 + ${#BASH_REMATCH[1]}))
          LX_WORDS=(); LX_WQ=(); LX_CUR=""; LX_HAVE=0; LX_QN=0
          _unmodelled "a function definition ($fnname)"
          _fn_taint
          continue
        fi
        _end_cmd
        # `((…))` is arithmetic in THIS shell, not a subshell: it can assign
        # (D=0, D++). The context below restores bindings on exit like a
        # subshell would, so drop them all again once it returns.
        if [[ "${line:$((C + 1)):1}" == '(' ]]; then
          C=$((C + 1)); _lex_context ')'; _var_clear_all
        else
          C=$((C + 1)); _lex_context ')'
        fi ;;
      ')')
        # Inside $( … ) or ( … ), the `)` that ends a case pattern does not end
        # the substitution or subshell.
        if [[ "$term" == ')' ]] && ! _in_case_pattern; then C=$((C + 1)); _end_cmd; _leave_context; return; fi
        LX_TERM=rparen; _end_cmd; C=$((C + 1)) ;;
      '>')
        if [[ "$LX_CUR" =~ ^[0-9]+$ ]]; then LX_CUR=""; LX_HAVE=0; fi
        _end_word; C=$((C + 1))
        [[ "${line:C:1}" == ">" ]] && C=$((C + 1))
        [[ "${line:C:1}" == "|" ]] && C=$((C + 1))
        if [[ "${line:C:1}" == "&" ]]; then C=$((C + 1)); LX_PEND=4; else LX_PEND=1; fi ;;
      '<')
        if [[ "$LX_CUR" =~ ^[0-9]+$ ]]; then LX_CUR=""; LX_HAVE=0; fi
        _end_word; C=$((C + 1))
        if [[ "${line:C:1}" == "<" ]]; then
          C=$((C + 1))
          if [[ "${line:C:1}" == "<" ]]; then
            C=$((C + 1)); LX_PEND=3                    # here-string
          else
            [[ "${line:C:1}" == "-" ]] && C=$((C + 1))
            _read_heredoc_delim; LX_PEND=0
          fi
        else
          LX_PEND=2
        fi ;;
      *)
        LX_CUR="$LX_CUR$ch"; LX_HAVE=1; C=$((C + 1)) ;;
    esac
  done
}

_analyze_text() {
  DEPTH=$((DEPTH + 1))
  if (( DEPTH > 8 )); then PARSE_ERROR=1; DEPTH=$((DEPTH - 1)); return; fi
  local -a save_lines
  save_lines=("${LINES[@]}")
  local save_l="$L" save_c="$C"
  local -a save_hd
  save_hd=("${HD[@]}")

  # Re-parsed text (eval, bash -c, a trap or alias body, a heredoc body) is its
  # own command list: not inside the enclosing command's pipeline or case.
  local save_cp="$CASE_PAT" save_term="$LX_TERM"
  _split_lines "$1"
  L=0; C=0; HD=(); CASE_PAT=0; LX_TERM=seq
  _lex_context ""

  LINES=("${save_lines[@]}")
  L="$save_l"; C="$save_c"; HD=("${save_hd[@]}"); CASE_PAT="$save_cp"; LX_TERM="$save_term"
  DEPTH=$((DEPTH - 1))
}

# --- structural backstop ----------------------------------------------------
#
# Everything above models bash: case pattern lists, compound commands,
# bindings, the working directory. A slip in that state machine (a `!` before
# `case x in esac` once left it reading every later command as a case pattern)
# turns into an ALLOW. This second pass does not share any of that state. It
# tokenizes the raw command flatly (quoting, $( … ), heredocs; nothing else),
# collects every redirection target and every destination of a write command,
# and judges them on their own:
#
#   A. A literal destination that lands in a main checkout blocks, wherever
#      the line runs. Absolute and ~ paths always; a relative one against the
#      hook's directory when nothing on the line can change directory.
#   B. If the line holds something the model does not fully track — case /
#      esac, ${…=…} / ${…:=…}, eval, a shell running text (bash -c, | sh,
#      sh <<EOF), trap, alias, coproc, select, a function, an arithmetic
#      assignment — then a destination built from an expansion, a command
#      named by one, or a relative destination after a directory change it
#      cannot follow, blocks wherever the line runs. A relative destination
#      after literal cds is judged against every directory the line may be in
#      (a cd that may not run keeps the old one).
#
# Over-blocking here is accepted by design (fail closed). Quoted text and
# heredoc bodies are data, except on a line that re-parses text (bash / sh /
# zsh, also as an argument such as find -exec sh -c; eval; trap; alias;
# source of stdin or of a computed file), where every one of them is scanned
# as code too: stdin, startup files (BASH_ENV, --rcfile), files the line
# writes and positional arguments can all carry it into the shell. A -c text
# and its positional arguments are also walked in order, as a script.

BS_T=()      # per token: W (word) or the operator itself
BS_V=()      # word value, quotes removed
BS_L=()      # word: 1 literal, 2 literal with a leading ~ (HOME), 0 computed
BS_Q=()      # word: 1 when quoted before its first = (never a reserved word or an assignment)
BS_SUBS=()   # code to walk separately: $( … ), ` … `, <( … ), >( … )
BS_DATA=()   # quoted strings and heredoc bodies (code only when the line re-parses)
BS_TRIG=""   # why rule B applies (empty: it does not)
BS_REPARSE=0  # a shell reads stdin: scan every quoted string / heredoc body as code
BS_ANYRP=0    # something on the line re-parses text
BS_CODEQ=()   # text a command re-parses: walked as code
BS_HIT=""    # rule A / B verdict: what blocked
BS_WHERE=""
BS_HOMEM=0   # HOME is mentioned: ~ is not the inherited value
BS_INDATA=0  # walking quoted text re-scanned as code
BS_UNDEC=""  # a $'…' with an escape shells decode differently (_ansi_decode)
BS_CODETXT="" # the command with its single-quoted / $'…' strings and quoted heredoc
              # bodies cut out by position (the construct check reads this)

_bs_trig() { [[ -z "$BS_TRIG" ]] && BS_TRIG="$1"; return 0; }

# Find the end of a $( … ) / ( … ) body in t (from index j): RET = index of
# the matching `)`, or the length of t when there is none. Quote-, backtick-
# and heredoc-aware; a `)` while a case is open there ends a pattern.
_bs_close() { # $1 text, $2 start index -> RET
  local t="$1" j="$2" n=${#1} depth=1 cs=0 c tok="" part rest d dq
  local -a hd=()
  while (( j < n )); do
    c="${t:j:1}"
    case "$c" in
      [A-Za-z_]) tok="$tok$c"; j=$((j + 1)); continue ;;
    esac
    [[ "$tok" == case ]] && cs=$((cs + 1))
    [[ "$tok" == esac ]] && (( cs > 0 )) && cs=$((cs - 1))
    tok=""
    case "$c" in
      "'") rest="${t:$((j + 1))}"
           if [[ "$rest" == *"'"* ]]; then part="${rest%%\'*}"; j=$((j + ${#part} + 2)); else j=$n; fi
           continue ;;
      '"') j=$((j + 1))
           while (( j < n )); do
             d="${t:j:1}"
             if [[ "$d" == '\' ]]; then j=$((j + 2)); continue; fi
             [[ "$d" == '"' ]] && break
             if [[ "$d" == '$' && "${t:$((j + 1)):1}" == '(' ]]; then
               _bs_close "$t" $((j + 2)); j=$((RET + 1)); continue
             fi
             j=$((j + 1))
           done
           j=$((j + 1)); continue ;;
      '\') j=$((j + 2)); continue ;;
      '`') j=$((j + 1))
           while (( j < n )) && [[ "${t:j:1}" != '`' ]]; do
             [[ "${t:j:1}" == '\' ]] && j=$((j + 1))
             j=$((j + 1))
           done
           j=$((j + 1)); continue ;;
      '#') if [[ "${t:$((j - 1)):1}" == [[:space:]\;\&\|\(] ]] || (( j == 0 )); then
             while (( j < n )) && [[ "${t:j:1}" != $'\n' ]]; do j=$((j + 1)); done
             continue
           fi ;;
      '<') if [[ "${t:j:2}" == '<<' && "${t:j:3}" != '<<<' ]]; then
             j=$((j + 2)); [[ "${t:j:1}" == - ]] && j=$((j + 1))
             while [[ "${t:j:1}" == [[:blank:]] ]]; do j=$((j + 1)); done
             d=""
             while (( j < n )); do
               c="${t:j:1}"
               case "$c" in
                 [[:space:]]|';'|'&'|'|'|'('|')'|'<'|'>') break ;;
                 "'"|'"') ;;
                 '\') ;;
                 *) d="$d$c" ;;
               esac
               j=$((j + 1))
             done
             [[ -n "$d" ]] && hd+=("$d")
             continue
           fi ;;
      $'\n')
           if (( ${#hd[@]} )); then
             j=$((j + 1))
             for d in "${hd[@]}"; do
               while (( j < n )); do
                 rest="${t:j}"; part="${rest%%$'\n'*}"
                 j=$((j + ${#part} + 1))
                 dq="$part"; while [[ "$dq" == $'\t'* ]]; do dq="${dq#?}"; done
                 [[ "$dq" == "$d" ]] && break
               done
             done
             hd=()
             continue
           fi ;;
      '(') depth=$((depth + 1)) ;;
      ')') if (( depth > 1 )); then depth=$((depth - 1))
           elif (( cs == 0 )); then RET=$j; return 0; fi ;;
    esac
    j=$((j + 1))
  done
  RET=$n
}

# A heredoc body: $1 Q (quoted delimiter: data) or U (it expands), $2 text.
_bs_body() {
  BS_DATA+=("$2")
  if [[ "$1" == U ]]; then
    _bs_dqsubs "$2"
    (( ${ct:-0} )) && BS_CODETXT="$BS_CODETXT$2"   # it expands: live (dynamic ct of _bs_lex)
  fi
}

# Queue the $( … ) and ` … ` inside text that expands like a double-quoted
# string (an unquoted heredoc body). Line by line, and only lines holding one
# (indexing a long string costs its length); a substitution that does not
# close on its line takes the following lines with it.
_bs_dqsubs() { # $1 text
  [[ "$1" == *'$('* || "$1" == *'`'* ]] || return 0
  local u ln j n c e i=0
  local -a ls=()
  while IFS= read -r ln; do ls+=("$ln"); done <<< "$1"
  while (( i < ${#ls[@]} )); do
    u="${ls[i]}"; i=$((i + 1))
    [[ "$u" == *'$('* || "$u" == *'`'* ]] || continue
    j=0; n=${#u}
    while (( j < n )); do
      c="${u:j:1}"
      if [[ "$c" == '\' ]]; then j=$((j + 2)); continue; fi
      if [[ "$c" == '$' && "${u:$((j + 1)):1}" == '(' ]]; then
        _bs_close "$u" $((j + 2))
        while (( RET >= n && i < ${#ls[@]} )); do
          u="$u"$'\n'"${ls[i]}"; i=$((i + 1)); n=${#u}; _bs_close "$u" $((j + 2))
        done
        BS_SUBS+=("${u:$((j + 2)):$((RET - j - 2))}"); j=$((RET + 1)); continue
      fi
      if [[ "$c" == '`' ]]; then
        while :; do
          e=$((j + 1)); while (( e < n )) && [[ "${u:e:1}" != '`' ]]; do [[ "${u:e:1}" == '\' ]] && e=$((e + 1)); e=$((e + 1)); done
          (( e < n || i >= ${#ls[@]} )) && break
          u="$u"$'\n'"${ls[i]}"; i=$((i + 1)); n=${#u}
        done
        BS_SUBS+=("${u:$((j + 1)):$((e - j - 1))}"); j=$((e + 1)); continue
      fi
      j=$((j + 1))
    done
  done
}

# Tokenize one piece of code onto BS_T / BS_V / BS_L / BS_Q. Substitutions go
# to BS_SUBS (walked as separate pieces), quoted text to BS_DATA.
# Text in [$1, $2) of t is data: cut it out of BS_CODETXT (dynamic t / cs /
# ct of _bs_lex; it leaves a space, so the text around it never joins).
_bs_ct() {
  (( ct )) || return 0
  BS_CODETXT="$BS_CODETXT${t:cs:$(( $1 - cs ))} "
  cs=$2
}

_bs_lex() { # $1 text, [$2 1: record BS_CODETXT]
  local t="$1" n=${#1} j=0 c d w="" have=0 lit=1 q=0 tq=0 part rest e x
  local ct="${2:-0}" cs=0 indq=0
  local -a hd=()
  local run_re=$'^([^\\\\\'"`$#;|&()<> \t\n*?[{}~]+)'
  while (( j <= n )); do
    if (( j == n )); then c=$'\n'; else c="${t:j:1}"; fi
    if [[ "$c" != $'\n' ]] && [[ "${t:j:64}" =~ $run_re ]]; then
      w="$w${BASH_REMATCH[1]}"; have=1; j=$((j + ${#BASH_REMATCH[1]})); continue
    fi
    case "$c" in
      '\')
        d="${t:$((j + 1)):1}"
        if [[ "$d" == $'\n' ]]; then j=$((j + 2)); continue; fi
        [[ "$w" == *=* ]] || q=1; w="$w$d"; have=1; j=$((j + 2)) ;;
      "'")
        rest="${t:$((j + 1))}"; e=$j
        if [[ "$rest" == *"'"* ]]; then part="${rest%%\'*}"; j=$((j + ${#part} + 2)); else part="$rest"; j=$n; fi
        _bs_ct "$e" "$j"
        [[ "$w" == *=* ]] || q=1; w="$w$part"; have=1; BS_DATA+=("$part") ;;
      '"')
        _bs_lex_dq ;;
      '`')
        e=$((j + 1)); while (( e < n )) && [[ "${t:e:1}" != '`' ]]; do [[ "${t:e:1}" == '\' ]] && e=$((e + 1)); e=$((e + 1)); done
        BS_SUBS+=("${t:$((j + 1)):$((e - j - 1))}"); w="$w\$(…)"; have=1; lit=0; j=$((e + 1)) ;;
      '$')
        _bs_lex_dollar ;;
      '#')
        if (( have )); then w="$w#"; j=$((j + 1))
        else while (( j < n )) && [[ "${t:j:1}" != $'\n' ]]; do j=$((j + 1)); done; fi ;;
      ' '|$'\t')
        _bs_endw; j=$((j + 1)) ;;
      $'\n')
        _bs_endw; BS_T+=(NL); BS_V+=(""); BS_L+=(1); BS_Q+=(0)
        j=$((j + 1))
        if (( ${#hd[@]} )); then
          # The bodies are data: read them a line at a time from one copy of
          # the rest, then drop what they used. (Indexing a string costs its
          # length in bash, so a 75 KB body read through ${t:j…} took seconds.)
          local ln hi=0 used=0
          (( ct )) && BS_CODETXT="$BS_CODETXT${t:cs:$((j - cs))}"
          rest="${t:j}"; part=""
          while (( hi < ${#hd[@]} )) && IFS= read -r ln; do
            used=$((used + ${#ln} + 1))
            d="$ln"; while [[ "$d" == $'\t'* ]]; do d="${d#?}"; done
            if [[ "$d" == "${hd[hi]:1}" ]]; then
              _bs_body "${hd[hi]:0:1}" "$part"; part=""; hi=$((hi + 1))
            else
              part="$part$ln"$'\n'
            fi
          done <<< "$rest"
          while (( hi < ${#hd[@]} )); do _bs_body "${hd[hi]:0:1}" "$part"; part=""; hi=$((hi + 1)); done
          t="${rest:used}"; n=${#t}; j=0; cs=0
          hd=()
        fi ;;
      ';')
        _bs_endw
        if [[ "${t:$((j + 1)):1}" == ';' || "${t:$((j + 1)):1}" == '&' ]]; then
          j=$((j + 2)); [[ "${t:j:1}" == '&' ]] && j=$((j + 1)); _bs_op ';;'
        else j=$((j + 1)); _bs_op ';'; fi ;;
      '&')
        _bs_endw
        if [[ "${t:$((j + 1)):1}" == '&' ]]; then j=$((j + 2)); _bs_op '&&'
        elif [[ "${t:$((j + 1)):1}" == '>' ]]; then j=$((j + 2)); [[ "${t:j:1}" == '>' ]] && j=$((j + 1)); _bs_op R
        else j=$((j + 1)); _bs_op '&'; fi ;;
      '|')
        _bs_endw
        if [[ "${t:$((j + 1)):1}" == '|' ]]; then j=$((j + 2)); _bs_op '||'
        else j=$((j + 1)); [[ "${t:j:1}" == '&' ]] && j=$((j + 1)); _bs_op '|'; fi ;;
      '(')
        if (( ! have )) && [[ "${t:$((j + 1)):1}" == '(' ]]; then
          # (( … )): arithmetic in this shell.
          _bs_close "$t" $((j + 2)); e=$RET
          x="${t:$((j + 2)):$((e - j - 2))}"
          _bs_arith "$x"
          j=$((e + 1)); [[ "${t:j:1}" == ')' ]] && j=$((j + 1))
          BS_T+=(W); BS_V+=("((…))"); BS_L+=(0); BS_Q+=(1)
        else
          _bs_endw; j=$((j + 1)); _bs_op '('
        fi ;;
      ')')
        _bs_endw; j=$((j + 1)); _bs_op ')' ;;
      '>'|'<')
        # N> / {var}> name a descriptor, not a word.
        if (( have && ! q )) && [[ "$w" =~ ^[0-9]+$ || "$w" =~ ^\{[A-Za-z_][A-Za-z0-9_]*\}$ ]]; then
          w=""; have=0; lit=1; tq=0
        fi
        _bs_endw
        d="${t:$((j + 1)):1}"
        if [[ "$d" == '(' ]]; then
          _bs_close "$t" $((j + 2)); BS_SUBS+=("${t:$((j + 2)):$((RET - j - 2))}"); j=$((RET + 1))
        elif [[ "$c" == '>' ]]; then
          case "$d" in
            '>'|'|') j=$((j + 2)); _bs_op R ;;
            '&') j=$((j + 2)); _bs_op RD ;;
            *) j=$((j + 1)); _bs_op R ;;
          esac
        else
          case "$d" in
            '>') j=$((j + 2)); _bs_op R ;;
            '&') j=$((j + 2)); _bs_op RI ;;
            '<')
              if [[ "${t:$((j + 2)):1}" == '<' ]]; then j=$((j + 3)); _bs_op RI
              else
                j=$((j + 2)); [[ "${t:j:1}" == - ]] && j=$((j + 1))
                while [[ "${t:j:1}" == [[:blank:]] ]]; do j=$((j + 1)); done
                local hq=U hdel=""
                while (( j < n )); do
                  x="${t:j:1}"
                  case "$x" in
                    [[:space:]]|';'|'&'|'|'|'('|')'|'<'|'>') break ;;
                    "'"|'"'|'\') hq=Q ;;
                    *) hdel="$hdel$x" ;;
                  esac
                  j=$((j + 1))
                done
                [[ -n "$hdel" ]] && hd+=("$hq$hdel")
              fi ;;
            *) j=$((j + 1)); _bs_op RI ;;
          esac
        fi ;;
      '~')
        (( have )) || tq=1
        w="$w~"; have=1; j=$((j + 1)) ;;
      *)
        # * ? [ { }: a glob or brace expansion (bash computes the word).
        w="$w$c"; have=1; lit=0; j=$((j + 1)) ;;
    esac
  done
  (( ct )) && BS_CODETXT="$BS_CODETXT${t:cs}"
  return 0
}

_bs_op() { BS_T+=("$1"); BS_V+=(""); BS_L+=(1); BS_Q+=(0); }

_bs_endw() { # (dynamic: w have lit q tq from _bs_lex)
  (( have )) || return 0
  if (( tq && lit )); then
    case "$w" in
      '~'|'~/'*) (( BS_HOMEM )) && lit=0 || lit=2 ;;
      *) lit=0 ;;   # ~user, ~+, ~-
    esac
  fi
  BS_T+=(W); BS_V+=("$w"); BS_L+=("$lit"); BS_Q+=("$q")
  w=""; have=0; lit=1; q=0; tq=0
}

_bs_arith() { # $1 arithmetic text: an assignment in it is not modelled
  local re='(^|[^=!<>])=([^=]|$)|\+\+|--|[-+*/%&|^]=|<<=|>>='
  [[ "$1" =~ $re ]] && _bs_trig "an arithmetic assignment"
  [[ "$1" == *'$('* || "$1" == *'`'* ]] && BS_SUBS+=("$1")
  return 0
}

_bs_lex_dq() { # at t[j] == '"' (dynamic scope of _bs_lex)
  local start=$((j + 1)) c d dq_re=$'^([^"\\\\$`]+)' indq=1
  j=$((j + 1)); [[ "$w" == *=* ]] || q=1; have=1
  while (( j < n )); do
    if [[ "${t:j:64}" =~ $dq_re ]]; then w="$w${BASH_REMATCH[1]}"; j=$((j + ${#BASH_REMATCH[1]})); continue; fi
    c="${t:j:1}"
    case "$c" in
      '"') BS_DATA+=("${t:start:$((j - start))}"); j=$((j + 1)); return 0 ;;
      '\') d="${t:$((j + 1)):1}"
           case "$d" in
             '$'|'`'|'"'|'\') w="$w$d"; j=$((j + 2)) ;;
             $'\n') j=$((j + 2)) ;;
             *) w="$w\\"; j=$((j + 1)) ;;
           esac ;;
      '$') _bs_lex_dollar ;;
      '`') local e=$((j + 1))
           while (( e < n )) && [[ "${t:e:1}" != '`' ]]; do [[ "${t:e:1}" == '\' ]] && e=$((e + 1)); e=$((e + 1)); done
           BS_SUBS+=("${t:$((j + 1)):$((e - j - 1))}"); w="$w\$(…)"; lit=0; j=$((e + 1)) ;;
      *) w="$w$c"; j=$((j + 1)) ;;
    esac
  done
  BS_DATA+=("${t:start}")
}

_bs_lex_dollar() { # at t[j] == '$' (dynamic scope of _bs_lex)
  local d="${t:$((j + 1)):1}" e x depth
  have=1
  case "$d" in
    '(')
      if [[ "${t:$((j + 2)):1}" == '(' ]]; then
        _bs_close "$t" $((j + 3)); e=$RET
        _bs_arith "${t:$((j + 3)):$((e - j - 3))}"
        j=$((e + 1)); [[ "${t:j:1}" == ')' ]] && j=$((j + 1))
      else
        _bs_close "$t" $((j + 2)); BS_SUBS+=("${t:$((j + 2)):$((RET - j - 2))}"); j=$((RET + 1))
      fi
      w="$w\$(…)"; lit=0 ;;
    '{')
      e=$((j + 2)); depth=1
      while (( e < n && depth > 0 )); do
        case "${t:e:1}" in '{') depth=$((depth + 1)) ;; '}') depth=$((depth - 1)) ;; '\') e=$((e + 1)) ;; esac
        e=$((e + 1))
      done
      x="${t:$((j + 2)):$((e - j - 3))}"
      [[ "$x" == *'$('* || "$x" == *'`'* ]] && BS_SUBS+=("$x")
      w="$w\${$x}"; lit=0; j=$e ;;
    "'")
      e=$((j + 2))
      while (( e < n )) && [[ "${t:e:1}" != "'" ]]; do [[ "${t:e:1}" == '\' ]] && e=$((e + 1)); e=$((e + 1)); done
      x="${t:$((j + 2)):$((e - j - 2))}"
      (( indq )) || _bs_ct "$j" $((e + 1))
      # Decoded, it is literal text; an escape shells decode differently
      # leaves an unknown expansion in its place.
      _ansi_decode "$x" '${__undecoded_escape__}'
      if (( RETUNRES )); then lit=0; [[ -z "$BS_UNDEC" ]] && BS_UNDEC="\$'$x'"; fi
      [[ "$w" == *=* ]] || q=1; BS_DATA+=("$RET"); w="$w$RET"; j=$((e + 1)) ;;
    '"')
      j=$((j + 1)); _bs_lex_dq; lit=0 ;;
    *)
      w="$w\$"; lit=0; j=$((j + 1)) ;;
  esac
}

# --- the walk ---

BS_CANDS=()   # directories the line may be in at this point
BS_ALLC=()    # every directory it may ever be in (for pieces walked out of order)
BS_CWDT=0     # something on the line may have changed directory
BS_CWDU=0     # ... to a directory this pass cannot tell
BS_LOOP=0     # a loop: a later cd may run before an earlier write
BS_NONLIT=""  # first computed destination (rule B)
BS_RELU=""    # first relative destination after an unknown directory change (rule B)
BS_RELM=""    # first relative destination that a possible directory puts in main (rule B)
BS_RELMW=""
BS_CSURE=1    # BS_CANDS is exactly where the shell is (every cd so far certainly ran here and succeeded)
BS_RELS=""    # first relative destination in a main checkout while BS_CSURE (blocks from anywhere)
BS_RELSW=""

_bs_cand_add() { # $1 dir -> BS_CANDS and BS_ALLC (logical and physical readings)
  local d e
  _lexnorm "$1"; d="$RET"
  for e in "$d" "$1"; do
    _bs_in "$e" "${BS_CANDS[@]}" || BS_CANDS+=("$e")
    _bs_in "$e" "${BS_ALLC[@]}" || BS_ALLC+=("$e")
  done
}
_bs_in() { local x="$1" y; shift; for y in "$@"; do [[ "$y" == "$x" ]] && return 0; done; return 1; }

# Judge one destination. $1 value, $2 literal flag (0 / 1 / 2), $3 1 when the
# piece is walked out of order (a substitution, re-parsed text).
_bs_target() {
  local v="$1" l="$2" ooo="${3:-0}" p c
  case "$v" in /dev/null|/dev/stdout|/dev/stderr|/dev/tty|/dev/fd/*) return 0 ;; esac
  if [[ "$l" == 0 ]]; then
    _shown "$v"; [[ -z "$BS_NONLIT" ]] && BS_NONLIT="$RET"
    return 0
  fi
  [[ -z "$v" ]] && return 0
  if [[ "$l" == 2 ]]; then p="$HOME${v#\~}"
  elif [[ "$v" == /* ]]; then p="$v"
  else
    if (( ! BS_CWDT )) && (( ! ooo )); then p="$PWD/$v"
    elif (( BS_CWDU )); then
      [[ -z "$BS_RELU" ]] && BS_RELU="$v"
      return 0
    else
      local -a cs=("${BS_CANDS[@]}")
      (( ooo )) && cs=("${BS_ALLC[@]}")
      for c in "${cs[@]}"; do
        _bs_wt_under "$c/$v" && continue
        if _dir_is_main "$c/$v"; then
          [[ -z "$BS_RELM" ]] && { BS_RELM="$v"; BS_RELMW="$c"; }
          (( BS_CSURE && ! ooo )) && [[ -z "$BS_RELS" ]] && { BS_RELS="$v"; BS_RELSW="$c"; }
          return 0
        fi
      done
      return 0
    fi
  fi
  _bs_wt_under "$p" && return 0
  if [[ -z "$BS_HIT" ]] && _dir_is_main "$p"; then
    BS_HIT="write to '$v'"; _nearest_dir "$p"; BS_WHERE="$RET"
  fi
  return 0
}

# Operands of a command (non-option words), skipping the values of the given
# options. $1 = space-separated options that take a value; words in BW_A/BW_L.
BO_V=(); BO_L=()
_bs_operands() {
  local takes=" $1 " k a dd=0 skip=0
  BO_V=(); BO_L=()
  for ((k = 0; k < ${#BW_A[@]}; k++)); do
    a="${BW_A[k]}"
    if (( skip )); then skip=0; continue; fi
    if (( ! dd )); then
      [[ "$a" == -- ]] && { dd=1; continue; }
      if [[ "$a" == -?* && "${BW_L[k]}" != 0 ]]; then
        # -m 755, and a cluster ending in it (-pm 755).
        [[ "$takes" == *" $a "* ]] && skip=1
        [[ "$a" =~ ^-[A-Za-z]+$ && "$takes" == *" -${a: -1} "* ]] && skip=1
        continue
      fi
    fi
    BO_V+=("$a"); BO_L+=("${BW_L[k]}")
  done
}

# A simple command has ended: judge what it writes (BW_C name, BW_CL its
# literal flag, BW_A / BW_L its words, BW_PFX the prefix it ran under).
_bs_cmd() { # $1 1 when out of order, $2 the operator that ended it
  local ooo="$1" endop="$2" base k a v l
  [[ -z "$BW_C" ]] && return 0
  base="${BW_C##*/}"
  if [[ "$BW_CL" == 0 ]]; then
    # (In re-scanned quoted text, which may not be code at all, a computed
    # name is no evidence of a write: `eval "$(mise activate bash)"`.)
    _shown "$BW_C"
    (( BS_INDATA )) || { [[ -z "$BS_NONLIT" ]] && BS_NONLIT="a command named by an expansion ('$RET')"; }
    BS_CWDT=1; BS_CDN=$((BS_CDN + 1)); BS_CWDU=1
    return 0
  fi
  if [[ "$BW_PFX" == xargs ]]; then
    # Its operands come from stdin: unknown destinations for a writer.
    case "$base" in cp|mv|install|ln|tee|touch|mkdir|rm|rmdir|unlink|truncate|shred|chmod|chown|chgrp|sed|gsed|perl|dd|rsync|patch)
      [[ -z "$BS_NONLIT" ]] && BS_NONLIT="xargs $base (operands from stdin)" ;;
    esac
  fi
  # Before a | or &, or after env / sudo / … (a new process), nothing it does
  # to the directory reaches this shell. builtin / command run it here.
  case "$base" in
    bash|sh|zsh|dash|ksh) ;;
    *) for ((k = 0; k < ${#BW_A[@]}; k++)); do
         case "${BW_A[k]##*/}" in bash|sh|zsh|dash|ksh) _bs_shell_c $((k + 1)) 1 ;; esac
       done ;;
  esac
  local child=0
  [[ "$endop" == '|' || "$endop" == '&' ]] && child=1
  [[ -n "$BW_PFX" && "$BW_PFX" != builtin && "$BW_PFX" != command ]] && child=1
  case "$base" in
    cd|pushd|popd)
      (( child )) && return 0
      _bs_cd "$base" "$ooo" "$endop"; return 0 ;;
    dirs)
      # dirs -c (or a computed option) empties the stack popd returns along.
      if (( ! child )); then
        for ((k = 0; k < ${#BW_A[@]}; k++)); do
          [[ "${BW_A[k]}" =~ ^-[A-Za-z]*c || "${BW_L[k]}" == 0 ]] && BS_DSTK=("?")
        done
      fi
      return 0 ;;
    source|.)
      # It runs a file's commands here. Reading stdin (/dev/stdin, a here-
      # string or heredoc), a computed file, or no file word (<(…)): what
      # it runs may be any quoted text on the line.
      local sf="${BW_A[0]:-}" sl="${BW_L[0]:-1}"
      [[ "$sf" == -- ]] && { sf="${BW_A[1]:-}"; sl="${BW_L[1]:-1}"; }
      case "$sf" in
        ''|-|/dev/stdin|/dev/fd/*|/proc/*/fd/*) BS_REPARSE=1; BS_ANYRP=1; _bs_trig "$base reading commands from stdin" ;;
        *) [[ "$sl" == 0 ]] && { BS_REPARSE=1; BS_ANYRP=1; _bs_trig "$base of a computed file"; } ;;
      esac
      (( child )) || { BS_CWDT=1; BS_CDN=$((BS_CDN + 1)); BS_CWDU=1; }; return 0 ;;
    eval)
      _bs_trig eval; _bs_codeq "${BW_A[*]}" "$(_bs_anylit0)"
      (( child )) || _bs_text_cds "${BW_A[*]}" "$(_bs_anylit0)"
      return 0 ;;
    bash|sh|zsh|dash|ksh)
      # Every quoted string on the line may reach it as code: stdin, a
      # startup file (BASH_ENV, --rcfile), a file the line writes, a
      # positional argument. All of them are scanned as code, and its -c text
      # is also walked in order (_bs_shell_c). A shell with no -c and no
      # script reads its commands from stdin (| sh, sh <<EOF), which the
      # model does not follow.
      BS_ANYRP=1; BS_REPARSE=1
      _bs_shell_c 0
      (( RETCOUNT )) || _bs_trig "a shell reading commands from stdin ($base)"
      return 0 ;;
    trap)
      # Its handler runs later: mid-line for anything but EXIT.
      BS_ANYRP=1
      local -a ta=()
      for a in "${BW_A[@]}"; do [[ "$a" == -* && ${#ta[@]} == 0 ]] || ta+=("$a"); done
      (( ${#ta[@]} )) && _bs_codeq "${ta[0]}" "$(_bs_anylit0)"
      if (( ${#ta[@]} >= 2 )) && (( ! child )); then
        local sig mid=0
        for sig in "${ta[@]:1}"; do case "$sig" in EXIT|exit|SIGEXIT|0) ;; *) mid=1 ;; esac; done
        (( mid )) && _bs_text_cds "${ta[0]}" 0
      fi
      return 0 ;;
    alias|enable)
      BS_ANYRP=1
      for a in "${BW_A[@]}"; do _bs_codeq "${a#*=}" "$(_bs_anylit0)"; done
      (( child )) || _bs_text_cds "${BW_A[*]}" "$(_bs_anylit0)"
      [[ "$base" == enable ]] && (( ! child )) && { BS_CWDT=1; BS_CDN=$((BS_CDN + 1)); BS_CWDU=1; }
      return 0 ;;
    let) _bs_trig "an arithmetic assignment (let)"; return 0 ;;
    shopt|set)
      # cdable_vars (cd NAME goes to $NAME) or a computed option name: cd
      # targets no longer mean what they say.
      (( child )) && return 0
      for ((k = 0; k < ${#BW_A[@]}; k++)); do
        if [[ "${BW_A[k]}" == cdable_vars || ( "${BW_L[k]}" == 0 && "$base" == shopt ) ]]; then
          BS_CWDT=1; BS_CDN=$((BS_CDN + 1)); BS_CWDU=1
        fi
      done
      return 0 ;;
    tee)
      _bs_operands ""; for ((k = 0; k < ${#BO_V[@]}; k++)); do _bs_target "${BO_V[k]}" "${BO_L[k]}" "$ooo"; done ;;
    touch)
      _bs_operands "-d -r -t --date --reference"
      for ((k = 0; k < ${#BO_V[@]}; k++)); do _bs_target "${BO_V[k]}" "${BO_L[k]}" "$ooo"; done ;;
    mkdir|rmdir|rm|unlink)
      _bs_operands "-m --mode"
      for ((k = 0; k < ${#BO_V[@]}; k++)); do _bs_target "${BO_V[k]}" "${BO_L[k]}" "$ooo"; done ;;
    truncate|shred)
      _bs_operands "-s -r -n --size --reference --iterations --random-source"
      for ((k = 0; k < ${#BO_V[@]}; k++)); do _bs_target "${BO_V[k]}" "${BO_L[k]}" "$ooo"; done ;;
    chmod|chown|chgrp)
      # The first operand is the mode / owner, unless --reference or a mode
      # written like an option (chmod -x f).
      local first=1
      for a in "${BW_A[@]}"; do
        [[ "$a" == --reference* || ( "$base" == chmod && "$a" =~ ^-[rwxXstugoa]+$ ) ]] && first=0
      done
      _bs_operands ""
      for ((k = first; k < ${#BO_V[@]}; k++)); do _bs_target "${BO_V[k]}" "${BO_L[k]}" "$ooo"; done ;;
    dd)
      for ((k = 0; k < ${#BW_A[@]}; k++)); do
        [[ "${BW_A[k]}" == of=* ]] && _bs_target "${BW_A[k]#of=}" "${BW_L[k]}" "$ooo"
      done ;;
    cp|mv|install|ln)
      local tdir="" tl=1 tset=0 dirs=0
      for ((k = 0; k < ${#BW_A[@]}; k++)); do
        a="${BW_A[k]}"
        [[ "$a" == -- ]] && break
        case "$a" in
          --target-directory=*) tdir="${a#*=}"; tl="${BW_L[k]}"; tset=1 ;;
          --target-directory) tdir="${BW_A[$((k + 1))]:-}"; tl="${BW_L[$((k + 1))]:-1}"; tset=1 ;;
          --directory) dirs=1 ;;
          --*) ;;
          -*)
            if [[ "$a" =~ ^-[A-Za-z]*t$ ]]; then tdir="${BW_A[$((k + 1))]:-}"; tl="${BW_L[$((k + 1))]:-1}"; tset=1
            elif [[ "$a" =~ ^-[A-Za-z]*t(.+)$ ]]; then tdir="${BASH_REMATCH[1]}"; tl="${BW_L[k]}"; tset=1; fi
            [[ "$base" == install && "$a" =~ ^-[A-Za-z]*d ]] && dirs=1 ;;
        esac
      done
      _bs_operands "-S --suffix -m -o -g --mode --owner --group -t --target-directory"
      if (( tset )); then _bs_target "$tdir" "$tl" "$ooo"
      elif (( dirs )); then for ((k = 0; k < ${#BO_V[@]}; k++)); do _bs_target "${BO_V[k]}" "${BO_L[k]}" "$ooo"; done
      elif (( ${#BO_V[@]} >= 2 )); then k=$((${#BO_V[@]} - 1)); _bs_target "${BO_V[k]}" "${BO_L[k]}" "$ooo"
      elif [[ "$base" == ln && ${#BO_V[@]} == 1 ]]; then _bs_target . 1 "$ooo"
      fi ;;
    sort)
      for ((k = 0; k < ${#BW_A[@]}; k++)); do
        a="${BW_A[k]}"
        case "$a" in
          -o|--output) _bs_target "${BW_A[$((k + 1))]:-}" "${BW_L[$((k + 1))]:-1}" "$ooo" ;;
          --output=*) _bs_target "${a#*=}" "${BW_L[k]}" "$ooo" ;;
          -o?*) _bs_target "${a#-o}" "${BW_L[k]}" "$ooo" ;;
        esac
      done ;;
    curl)
      for ((k = 0; k < ${#BW_A[@]}; k++)); do
        a="${BW_A[k]}"
        case "$a" in
          --output) _bs_target "${BW_A[$((k + 1))]:-}" "${BW_L[$((k + 1))]:-1}" "$ooo" ;;
          --output=*) _bs_target "${a#*=}" "${BW_L[k]}" "$ooo" ;;
          --remote-name|--remote-name-all|-J|--remote-header-name) _bs_target . 1 "$ooo" ;;
          --*) ;;
          -*)
            if [[ "$a" =~ ^-[A-Za-z0-9]*o$ ]]; then _bs_target "${BW_A[$((k + 1))]:-}" "${BW_L[$((k + 1))]:-1}" "$ooo"
            elif [[ "$a" =~ ^-[A-Za-np-z0-9]*o(.+)$ ]]; then _bs_target "${BASH_REMATCH[1]}" "${BW_L[k]}" "$ooo"; fi
            [[ "$a" =~ ^-[A-Za-z0-9]*O ]] && _bs_target . 1 "$ooo" ;;
        esac
      done ;;
    wget)
      local wout=0
      for ((k = 0; k < ${#BW_A[@]}; k++)); do
        a="${BW_A[k]}"
        case "$a" in
          -O|--output-document|-P|--directory-prefix) wout=1
             [[ "${BW_A[$((k + 1))]:-}" == - ]] || _bs_target "${BW_A[$((k + 1))]:-}" "${BW_L[$((k + 1))]:-1}" "$ooo" ;;
          --output-document=*|--directory-prefix=*) wout=1; [[ "${a#*=}" == - ]] || _bs_target "${a#*=}" "${BW_L[k]}" "$ooo" ;;
          -O?*|-P?*) wout=1; [[ "${a:2}" == - ]] || _bs_target "${a:2}" "${BW_L[k]}" "$ooo" ;;
          -*O) wout=1; [[ "${BW_A[$((k + 1))]:-}" == - ]] || _bs_target "${BW_A[$((k + 1))]:-}" "${BW_L[$((k + 1))]:-1}" "$ooo" ;;
        esac
      done
      (( wout )) || _bs_target . 1 "$ooo" ;;
    rsync)
      _bs_target . 1 "$ooo"
      _bs_operands ""
      if (( ${#BO_V[@]} >= 2 )); then
        k=$((${#BO_V[@]} - 1)); v="${BO_V[k]}"
        [[ "$v" =~ ^[^/]*: ]] || _bs_target "$v" "${BO_L[k]}" "$ooo"
      fi ;;
    sed|gsed|perl)
      local ip=0
      for a in "${BW_A[@]}"; do
        [[ "$a" == -- ]] && break
        [[ "$a" == --in-place* || "$a" =~ ^-[A-Za-z]*i ]] && ip=1
      done
      if (( ip )); then
        _bs_target . 1 "$ooo"
        if [[ "$base" == perl ]]; then _bs_operands "-e -E"; else _bs_operands "-e -f -l --expression --file --line-length"; fi
        for ((k = 0; k < ${#BO_V[@]}; k++)); do _bs_target "${BO_V[k]}" "${BO_L[k]}" "$ooo"; done
      fi ;;
    patch)
      _bs_target . 1 "$ooo"
      for ((k = 0; k < ${#BW_A[@]}; k++)); do
        a="${BW_A[k]}"
        case "$a" in
          -o|-d|--output|--directory) _bs_target "${BW_A[$((k + 1))]:-}" "${BW_L[$((k + 1))]:-1}" "$ooo" ;;
          --output=*|--directory=*) _bs_target "${a#*=}" "${BW_L[k]}" "$ooo" ;;
        esac
      done ;;
    devcontainer-exec)
      _bs_target . 1 "$ooo" ;;
    git)
      local gd="" gl=1 sub="" sub2=""
      k=0
      while (( k < ${#BW_A[@]} )); do
        a="${BW_A[k]}"
        case "$a" in
          -C)
            v="${BW_A[$((k + 1))]:-}"; l="${BW_L[$((k + 1))]:-1}"
            [[ "$l" == 0 ]] && gl=0
            if [[ "$l" == 2 ]]; then gd="$HOME${v#\~}"
            elif [[ "$v" == /* || -z "$gd" ]]; then gd="$v"
            else gd="$gd/$v"; fi
            k=$((k + 2)) ;;
          -c|--git-dir|--work-tree|--namespace|--exec-path) k=$((k + 2)) ;;
          -*) k=$((k + 1)) ;;
          *) sub="$a"; sub2="${BW_A[$((k + 1))]:-}"; break ;;
        esac
      done
      if [[ "$sub" == worktree && "$sub2" == add ]]; then _bs_wtadd "$gd" "$gl" $((k + 2)) "$ooo" "$endop"; return 0; fi
      case "$sub" in
        apply|am|cherry-pick|revert) ;;
        stash) [[ "$sub2" == pop || "$sub2" == apply ]] || return 0 ;;
        *) return 0 ;;
      esac
      if [[ "$gl" == 0 ]]; then _bs_target "$gd" 0 "$ooo"
      else _bs_target "${gd:-.}" 1 "$ooo"; fi ;;
  esac
  return 0
}

# git worktree add PATH … before && : the rest of the chain runs only if PATH
# is now a worktree, so writes under it there are not writes to the main
# checkout it sits in (a fresh .worktrees/x does not exist yet, so it would
# read as main). Only for that chain (cleared by _bs_gend).
BS_WTADD=()
_bs_wtadd() { # $1 -C dir, $2 its literal flag, $3 index of the first word after `add`, $4 out of order, $5 operator after it
  local gd="$1" k="$3" a v="" l=1 c
  [[ "$5" == '&&' && "$4" == 0 && "$2" != 0 ]] || return 0
  (( ${#BS_STK[@]} == 0 && ! BS_POISON )) || return 0
  case "$BW_PREV" in start|';'|NL|'&&') ;; *) return 0 ;; esac
  while (( k < ${#BW_A[@]} )); do
    a="${BW_A[k]}"
    case "$a" in
      -b|-B|--reason) k=$((k + 2)); continue ;;
      --) v="${BW_A[$((k + 1))]:-}"; l="${BW_L[$((k + 1))]:-1}"; break ;;
      -*) k=$((k + 1)); continue ;;
      *) v="$a"; l="${BW_L[k]}"; break ;;
    esac
  done
  [[ -n "$v" && "$l" != 0 ]] || return 0
  if [[ "$l" == 2 ]]; then v="$HOME${v#\~}"
  elif [[ "$v" != /* ]]; then
    if [[ "$gd" == /* ]]; then v="$gd/$v"
    elif (( BS_CWDU || ${#BS_CANDS[@]} != 1 )); then return 0
    else v="${BS_CANDS[0]}/${gd:+$gd/}$v"; fi
  fi
  _lexnorm "$v"; BS_WTADD+=("$RET")
  return 0
}
_bs_wt_under() { # $1 absolute path -> 0 when it is under a worktree the chain just added
  local p c
  (( ${#BS_WTADD[@]} )) || return 1
  _lexnorm "$1"; p="$RET"
  for c in "${BS_WTADD[@]}"; do [[ "$p" == "$c" || "$p" == "$c"/* ]] && return 0; done
  return 1
}

# A shell's arguments from BW_A[$1]: its -c TEXT, and the positional
# parameters after it (which TEXT may re-parse: sh -c "$1"), are queued to be
# walked in order as code; every quoted string on the line is scanned as code
# as well (BS_REPARSE). RETCOUNT = 1 when it has
# -c TEXT or a script operand, 0 when it reads commands from stdin (no operand,
# -s / -i, or an operand naming stdin). With $2 = 1, only -c TEXT counts (a
# shell named as an argument: find -exec sh -c TEXT, flock F sh -c …).
_bs_shell_c() { # $1 first index, [$2 1: only -c]
  local k="$1" a c=0 sin=0
  RETCOUNT=0
  while (( k < ${#BW_A[@]} )); do
    a="${BW_A[k]}"
    case "$a" in
      --) k=$((k + 1)); break ;;
      -o|+o|-O|+O|--rcfile|--init-file) k=$((k + 2)); continue ;;
      --*) ;;
      -*c*) c=1 ;;
      -*[si]*) sin=1 ;;
      -*|+*) ;;
      *) break ;;
    esac
    k=$((k + 1))
  done
  if (( c )); then
    (( k < ${#BW_A[@]} )) || return 0
    BS_ANYRP=1; BS_REPARSE=1; RETCOUNT=1
    for ((; k < ${#BW_A[@]}; k++)); do
      BS_CODEQ+=("${BW_A[k]}"); [[ "${BW_L[k]}" == 0 ]] && BS_REPARSE=1
    done
    return 0
  fi
  [[ "${2:-0}" == 1 ]] && return 0
  (( k < ${#BW_A[@]} && ! sin )) || return 0
  case "${BW_A[k]}" in /dev/stdin|/dev/fd/*|/proc/*/fd/*) return 0 ;; esac
  [[ "${BW_L[k]}" == 0 ]] && return 0
  RETCOUNT=1
}

# Text a command re-parses (eval's words, a trap handler, an alias): queued as
# code; a computed word means the code is not known (BS_REPARSE).
_bs_codeq() { # $1 text, $2 1 when computed (kept for the message; every quoted string is scanned anyway)
  BS_ANYRP=1; BS_REPARSE=1; BS_CODEQ+=("$1")
  return 0
}

_bs_anylit0() { # -> prints 1 when any word of the command is computed
  local x
  for x in "${BW_L[@]}"; do [[ "$x" == 0 ]] && { echo 1; return 0; }; done
  echo 0
}

# Text that runs in this shell (eval's words, an alias, a mid-line trap): when
# it may change directory (or is computed), the directory is unknown.
BS_CDN=0      # bumped by every directory change the walk sees
BS_DEPTH=0
_bs_text_cds() { # $1 text, $2 1 when computed
  if [[ "$2" == 1 ]] || (( BS_DEPTH > 6 )); then BS_CWDT=1; BS_CDN=$((BS_CDN + 1)); BS_CWDU=1; BS_DSTK=("?"); return 0; fi
  # Walk the text with this pass's own walker (its writes are judged like
  # any others); if it changes directory, the directory is unknown after it.
  local -a sc=("${BS_CANDS[@]}") sstk=("${BS_STK[@]}") sd=("${BS_DSTK[@]}") sga=("${BS_GALT[@]}")
  local st="$BS_CWDT" su="$BS_CWDU" sp="$BS_POISON" sprev="$BW_PREV" scdn="$BS_CDN" lo=${#BS_T[@]}
  local sgact="$BS_GACT" sgau="$BS_GALTU" sgs="$BS_GSURE" scs="$BS_CSURE"
  local -a swt=("${BS_WTADD[@]}")
  local -a sbwa=("${BW_A[@]}") sbwl=("${BW_L[@]}")
  local sbwc="$BW_C" sbwcl="$BW_CL" sbwp="$BW_PFX"
  BS_DEPTH=$((BS_DEPTH + 1))
  _bs_lex "$1"; _bs_walk "$lo" "${#BS_T[@]}" 0
  BS_DEPTH=$((BS_DEPTH - 1))
  local moved=0
  [[ "$BS_CDN" != "$scdn" ]] && moved=1
  BS_CANDS=("${sc[@]}"); BS_STK=("${sstk[@]}"); BS_DSTK=("${sd[@]}")
  BS_CWDT="$st"; BS_CWDU="$su"; BS_POISON="$sp"; BW_PREV="$sprev"
  BS_GACT="$sgact"; BS_GALT=("${sga[@]}"); BS_GALTU="$sgau"; BS_WTADD=("${swt[@]}")
  BS_GSURE="$sgs"; BS_CSURE="$scs"
  BW_A=("${sbwa[@]}"); BW_L=("${sbwl[@]}"); BW_C="$sbwc"; BW_CL="$sbwcl"; BW_PFX="$sbwp"
  (( moved )) && { BS_CWDT=1; BS_CDN=$((BS_CDN + 1)); BS_CWDU=1; BS_DSTK=("?"); }
  return 0
}

# A cd / pushd / popd: where may the shell be now?
BS_DSTK=()    # pushd's saved directory sets (each _join'ed; "?" = unknown)
_bs_cd() { # $1 base, $2 out of order, $3 operator after it
  local base="$1" ooo="$2" endop="$3" a k nops=0 tv="" tl=1 dd=0 bad=0 p c definite=1
  local -a news=()
  BS_CWDT=1; BS_CDN=$((BS_CDN + 1))
  (( ${#BS_STK[@]} == 0 && ! BS_POISON && ! ooo )) || definite=0
  case "$BW_PREV" in start|';'|NL) ;; *) definite=0 ;; esac
  if [[ "$base" == popd ]]; then
    # Back to the set pushd saved (only plain popd, a stack this pass kept).
    local nd=${#BS_DSTK[@]} top
    if (( ${#BW_A[@]} || nd == 0 )) || [[ "${BS_DSTK[$((nd - 1))]}" == "?" ]]; then BS_CWDU=1; BS_DSTK=("?"); return 0; fi
    top="${BS_DSTK[$((nd - 1))]}"
    unset "BS_DSTK[$((nd - 1))]"; BS_DSTK=("${BS_DSTK[@]}")
    if [[ "$top" == U ]]; then BS_CWDU=1; return 0; fi
    _split "${top#?}"
    if (( definite )); then BS_CANDS=(); BS_CWDU=0; BS_CSURE=1; elif (( BS_CWDU )); then return 0; else BS_CSURE=0; fi
    for p in "${SPLIT[@]}"; do _bs_cand_add "$p"; done
    return 0
  fi
  if [[ "$base" == pushd ]]; then
    if (( BS_CWDU )); then BS_DSTK+=(U); else _join "${BS_CANDS[@]}"; BS_DSTK+=("S$RET"); fi
    (( definite )) || BS_DSTK=("?")
  fi
  for ((k = 0; k < ${#BW_A[@]}; k++)); do
    a="${BW_A[k]}"
    if (( ! dd )) && [[ "$a" == -* && "$a" != - ]]; then
      [[ "$a" == -- ]] && { dd=1; continue; }
      [[ "$base" == cd && "$a" =~ ^-[LPe@]+$ ]] && continue
      bad=1; continue
    fi
    nops=$((nops + 1)); tv="$a"; tl="${BW_L[k]}"
  done
  if (( bad || nops > 1 )) || [[ "$tv" == - || "$tv" == [+-][0-9]* ]]; then BS_CWDU=1; return 0; fi
  if (( nops == 0 )); then
    [[ "$base" == pushd ]] && { BS_CWDU=1; return 0; }
    tv='~'; tl=2; (( BS_HOMEM )) && tl=0
  fi
  [[ "$tl" == 0 ]] && { BS_CWDU=1; return 0; }
  if [[ "$tl" == 2 ]]; then news=("$HOME${tv#\~}")
  elif [[ "$tv" == /* ]]; then news=("$tv")
  else
    # Relative: against every directory it may be in; CDPATH may redirect it.
    if (( BS_CWDU )) || [[ -n "${CDPATH:-}" ]] || (( BS_CDPM )); then BS_CWDU=1; return 0; fi
    for c in "${BS_CANDS[@]}"; do news+=("$c/$tv"); done
  fi
  # Before && (and not after ||), in this shell: the rest of the && chain runs
  # only if the cd ran and succeeded.
  local guard=0
  if [[ "$endop" == '&&' ]] && (( ${#BS_STK[@]} == 0 && ! BS_POISON && ! ooo )); then
    case "$BW_PREV" in start|';'|NL|'&&') guard=1 ;; esac
  fi
  # It certainly runs, in this shell, and certainly succeeds: only then does
  # it replace the directories the line may be in.
  (( ${#BS_STK[@]} == 0 && ! BS_POISON && ! ooo )) || definite=0
  case "$BW_PREV" in start|';'|NL) ;; *) definite=0 ;; esac
  for p in "${news[@]}"; do [[ -d "$p" ]] || definite=0; done
  if (( definite )); then
    BS_CANDS=(); BS_CWDU=0; BS_CSURE=1
  else
    BS_CSURE=0
  fi
  if (( definite || ! BS_CWDU )); then
    for p in "${news[@]}"; do _bs_cd_add "$p"; done
  fi
  if (( guard )); then
    # Within the chain the shell is where the cd went; once the chain ends
    # (_bs_gend) it may be anywhere the reading above allows.
    (( BS_GACT )) || BS_GSURE=1
    BS_GACT=1; (( BS_CWDU )) && BS_GALTU=1; (( BS_CSURE )) || BS_GSURE=0
    for p in "${BS_CANDS[@]}"; do _bs_in "$p" "${BS_GALT[@]}" || BS_GALT+=("$p"); done
    BS_CANDS=(); BS_CWDU=0; BS_CSURE=1
    for p in "${news[@]}"; do _bs_cd_add "$p"; done
  fi
  return 0
}

# Add a cd target: its logical and physical readings (set -P, or cd -P, is
# not tracked here). When they differ, where the shell is is not certain.
_bs_cd_add() { # $1 directory
  local lg
  _bs_cand_add "$1"
  _lexnorm "$1"; lg="$RET"
  _phys "$1"
  if [[ -n "$RET" ]]; then
    [[ "$RET" == "$lg" ]] || BS_CSURE=0
    _bs_cand_add "$RET"
  fi
}

# A && chain that followed a guarded cd has ended (; newline || & ;; or the
# end of the piece): add back where the shell may be if the chain stopped.
BS_GACT=0; BS_GALT=(); BS_GALTU=0; BS_GSURE=1
_bs_gend() {
  (( BS_GACT )) || return 0
  local p
  for p in "${BS_GALT[@]}"; do _bs_in "$p" "${BS_CANDS[@]}" || BS_CANDS+=("$p"); done
  (( BS_GALTU )) && BS_CWDU=1
  BS_CSURE="$BS_GSURE"
  BS_GACT=0; BS_GALT=(); BS_GALTU=0
  return 0
}

BS_STK=(); BS_POISON=0; BS_CDPM=0
_bs_push() { BS_STK+=("$1"); }
_bs_pop() { # $1 kind: pop it when it is the innermost, else the structure is lost
  local nn=${#BS_STK[@]}
  if (( nn > 0 )) && [[ "${BS_STK[$((nn - 1))]}" == "$1" ]]; then
    unset "BS_STK[$((nn - 1))]"; BS_STK=("${BS_STK[@]}")
  else
    BS_POISON=1
  fi
}

# Walk tokens [$1, $2). $3 = 1 for a piece walked out of order.
_bs_walk() {
  local from="$1" to="$2" ooo="$3" k ty v l qq cmdpos=1 cs=0 pend="" pfx="" pskip=0 tout=0 aftert=0
  BW_C=""; BW_CL=1; BW_A=(); BW_L=(); BW_PFX=""; BW_PREV=start
  BS_STK=(); BS_POISON=0; BS_GACT=0; BS_GALT=(); BS_GALTU=0; BS_WTADD=()
  (( ooo )) && BS_STK=(paren)
  for ((k = from; k < to; k++)); do
    ty="${BS_T[k]}"; v="${BS_V[k]}"; l="${BS_L[k]}"; qq="${BS_Q[k]}"
    if [[ "$ty" != W ]]; then
      case "$ty" in
        R|RD|RI) pend="$ty"; continue ;;
      esac
      pend=""
      # NL inside `case WORD` … `in` and before a pattern list is a linebreak.
      if [[ "$ty" == NL ]] && (( cs >= 1 && cs <= 3 )); then
        _bs_cmd "$ooo" ";"; BW_C=""; BW_A=(); BW_L=(); cmdpos=1; continue
      fi
      _bs_cmd "$ooo" "$ty"
      case "$ty" in ';'|NL|'||'|'&'|';;') _bs_gend; BS_WTADD=() ;; esac
      BW_C=""; BW_CL=1; BW_A=(); BW_L=(); BW_PFX=""; pfx=""; pskip=0; tout=0; aftert=0; cmdpos=1
      case "$ty" in
        ';;') local nn=${#BS_STK[@]}
              if (( nn > 0 )) && [[ "${BS_STK[$((nn - 1))]}" == case ]]; then cs=3; else BS_POISON=1; fi ;;
        '(')
          if (( cs == 3 )); then cs=4
          elif [[ "${BS_T[$((k + 1))]:-}" == ')' ]]; then
            # NAME ( ): a function definition.
            _bs_trig "a function definition"; BS_CWDT=1; BS_CDN=$((BS_CDN + 1)); BS_CWDU=1; k=$((k + 1))
          else _bs_push paren; fi ;;
        ')')
          if (( cs == 3 || cs == 4 )); then cs=0
          else _bs_pop paren; fi ;;
      esac
      BW_PREV="$ty"
      continue
    fi
    if [[ -n "$pend" ]]; then
      case "$pend" in
        R) _bs_target "$v" "$l" "$ooo" ;;
        RD) [[ "$v" =~ ^[0-9]*-?$ && "$l" != 0 ]] || _bs_target "$v" "$l" "$ooo" ;;
      esac
      pend=""; continue
    fi
    case "$cs" in
      1) cs=2; continue ;;                       # the case WORD
      2) cs=3; [[ "$v" == in && "$qq" == 0 ]] || BS_POISON=1; continue ;;
      3) if [[ "$v" == esac && "$qq" == 0 ]]; then _bs_pop case; cs=0; cmdpos=1; continue; fi
         cs=4; continue ;;
      4) continue ;;                             # pattern words
    esac
    if (( ! cmdpos )); then BW_A+=("$v"); BW_L+=("$l"); continue; fi
    if [[ -n "$pfx" ]]; then
      if (( pskip )); then pskip=0; continue; fi
      if [[ "$v" == -* ]]; then
        case "$pfx:$v" in
          sudo:-[ugCDhpUrt]|doas:-u|nice:-n|ionice:-[cnp]|stdbuf:-[ioe]|env:-[uCS]|exec:-a|xargs:-[nIPLsadE]|timeout:-[sk]) pskip=1 ;;
        esac
        continue
      fi
      if [[ "$pfx" == env && "$v" == *=* ]]; then continue; fi
      if [[ "$pfx" == timeout ]] && (( tout )); then tout=0; continue; fi
    fi
    if (( aftert )) && [[ "$v" == -p || "$v" == -- ]]; then continue; fi
    aftert=0
    if [[ "$qq" == 0 && "$v" =~ ^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?= ]]; then continue; fi
    if [[ "$qq" == 0 ]]; then
      case "$v" in
        '!'|then|else|elif|do) continue ;;
        time) aftert=1; continue ;;
        '{') _bs_push brace; continue ;;
        '}') _bs_pop brace; continue ;;
        if) _bs_push if; continue ;;
        fi) _bs_pop if; continue ;;
        while|until) _bs_push loop; BS_LOOP=1; continue ;;
        done) _bs_pop loop; continue ;;
        'esac') _bs_pop case; continue ;;
        coproc) _bs_trig coproc; continue ;;
        case) _bs_trig case; _bs_push case; cs=1; cmdpos=0; continue ;;
        for|select)
          _bs_push loop; BS_LOOP=1; [[ "$v" == select ]] && _bs_trig select
          cmdpos=0; continue ;;
        function) _bs_trig "a function definition"; BS_CWDT=1; BS_CDN=$((BS_CDN + 1)); BS_CWDU=1; cmdpos=0; continue ;;
      esac
    fi
    case "${v##*/}" in
      env|sudo|doas|nohup|nice|ionice|stdbuf|setsid|command|builtin|exec|xargs|time)
        [[ "$l" == 0 ]] || { pfx="${v##*/}"; BW_PFX="$pfx"; continue; } ;;
      timeout)
        [[ "$l" == 0 ]] || { pfx=timeout; BW_PFX=timeout; tout=1; continue; } ;;
    esac
    BW_C="$v"; BW_CL="$l"; cmdpos=0
  done
  _bs_cmd "$ooo" ";"
  _bs_gend; BS_WTADD=()
  BW_C=""; BW_A=(); BW_L=()
  (( cs != 0 || ${#BS_STK[@]} > ooo )) && BS_POISON=1
  return 0
}

_backstop() {
  local LC_ALL=C
  local i lo hi rounds=0
  [[ "$CMD" =~ HOME ]] && BS_HOMEM=1
  [[ "$CMD" == *CDPATH* ]] && BS_CDPM=1
  BS_CANDS=("$PWD"); BS_ALLC=("$PWD")
  BS_CODETXT=""; _bs_lex "$CMD" 1
  hi=${#BS_T[@]}
  _bs_walk 0 "$hi" 0
  if (( BS_LOOP && BS_CWDT )); then
    # In a loop, a cd later on the line may run before an earlier write.
    BS_CANDS=("${BS_ALLC[@]}"); BS_CSURE=0
    _bs_walk 0 "$hi" 0
  fi
  # Substitutions (and, on a line that re-parses text, quoted text and heredoc
  # bodies) as separate pieces, in any directory the line may be in.
  local si=0 di=0 ci=0
  while (( rounds < 64 )); do
    rounds=$((rounds + 1))
    if (( si < ${#BS_SUBS[@]} )); then
      lo=${#BS_T[@]}; _bs_lex "${BS_SUBS[si]}"; si=$((si + 1))
    elif (( ci < ${#BS_CODEQ[@]} )); then
      # Re-parsed text runs as a script of its own, in order, from wherever
      # the line may be (certain only when that is one directory).
      lo=${#BS_T[@]}; _bs_lex "${BS_CODEQ[ci]}"; ci=$((ci + 1)); BS_INDATA=1
      BS_CANDS=("${BS_ALLC[@]}"); BS_CSURE=0; (( ${#BS_ALLC[@]} == 1 )) && BS_CSURE=1
      _bs_walk "$lo" "${#BS_T[@]}" 0
      continue
    elif (( BS_REPARSE && di < ${#BS_DATA[@]} )); then
      lo=${#BS_T[@]}; _bs_lex "${BS_DATA[di]}"; di=$((di + 1)); BS_INDATA=1
    else
      break
    fi
    BS_CANDS=("${BS_ALLC[@]}")
    _bs_walk "$lo" "${#BS_T[@]}" 1
  done
  (( rounds >= 64 )) && _bs_trig "more nested text than this pass follows"
  # ${D:=w} / $[…] in code (single-quoted text and quoted heredoc bodies are
  # data, unless the line re-parses text: then they may be code too).
  local code="$CMD" dre='\$\{[#!]?[A-Za-z0-9_@*#?$!-]+(\[[^]]*\])?:?='
  (( BS_ANYRP )) || code="$BS_CODETXT"
  [[ "$code" =~ $dre ]] && _bs_trig '${…=…} (an assignment inside an expansion)'
  [[ "$code" == *'$['* ]] && _bs_trig 'an arithmetic expansion $[…]'
  [[ -n "$BS_HIT" ]] && return 0
  if (( BS_ANYRP )) && [[ -n "$BS_UNDEC" ]]; then
    BS_HIT="text re-parsed as code holding $BS_UNDEC, which shells decode differently"; BS_WHERE=""
    return 0
  fi
  # A relative destination after cds that certainly ran, in this shell, into
  # directories that exist (or within a cd's && chain) is judged like a
  # literal one: wherever the line runs.
  if [[ -n "$BS_RELS" ]]; then
    BS_HIT="relative write to '$BS_RELS', which lands in a main checkout (the shell is in $BS_RELSW)"; BS_WHERE="$BS_RELSW"
    return 0
  fi
  if [[ -n "$BS_TRIG" ]]; then
    if [[ -n "$BS_NONLIT" ]]; then BS_HIT="write to '$BS_NONLIT', a destination built from an expansion"; BS_WHERE=""
    elif [[ -n "$BS_RELU" ]]; then BS_HIT="relative write to '$BS_RELU' after a directory change this pass cannot follow"; BS_WHERE=""
    elif [[ -n "$BS_RELM" ]]; then BS_HIT="relative write to '$BS_RELM', which lands in a main checkout if the shell is in $BS_RELMW"; BS_WHERE="$BS_RELMW"
    fi
  fi
  return 0
}

# --- run --------------------------------------------------------------------

# Print a worktree command that works here. Prefer the estate-wt launcher: on
# PATH, beside this hook (agent-estate, reached through symlinks), or in the
# repo. Repos that vendor this hook as a plain file usually have none of these
# (delivery-ops#1088), so fall back to plain `git worktree add`.
_worktree_hint() { # $1 repo top-level ("" when unknown), $2 verb ("edit" / "run it")
  local top="$1" src dir ewt="" c def=""
  if command -v estate-wt >/dev/null 2>&1; then
    ewt=estate-wt
  else
    src=${BASH_SOURCE[0]}
    while [ -L "$src" ]; do
      dir=$(cd -P "$(dirname "$src")" && pwd); src=$(readlink "$src")
      case $src in /*) ;; *) src=$dir/$src ;; esac
    done
    dir=$(cd -P "$(dirname "$src")/.." 2>/dev/null && pwd)
    for c in ${dir:+"$dir/bin/estate-wt"} ${top:+"$top/bin/estate-wt" "$top/.agents/bin/estate-wt"}; do
      if [ -f "$c" ] && [ -x "$c" ]; then ewt=$c; break; fi
    done
  fi
  echo "   Create a worktree first, then $2 there:" >&2
  if [ -n "$ewt" ]; then
    echo "     $ewt -C ${top:-<repo>} new <slug>     (prints the new worktree's path)" >&2
  else
    if [ -n "$top" ]; then
      def=$(git -C "$top" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
      def=${def#origin/}
      for c in main master; do
        [ -z "$def" ] && git -C "$top" rev-parse --verify --quiet "refs/remotes/origin/$c" >/dev/null && def=$c
      done
    fi
    echo "     git -C ${top:-<repo>} worktree add .worktrees/<slug> -b <branch> origin/${def:-<default>}" >&2
  fi
}

if (( DEGRADED )); then
  # Old-style, deliberately over-eager substring scan (see note above).
  legacy_re='(^|[;&|[:space:]])(bin/devcontainer-exec|rsync|patch[[:space:]]|sed[[:space:]]+-i|perl[[:space:]]+-i|git[[:space:]]+(stash[[:space:]]+(pop|apply)|apply([[:space:]]|$)|am([[:space:]]|$)|cherry-pick|revert))'
  if [[ "$CMD" =~ $legacy_re ]] && _dir_is_main "$PWD"; then
    echo "❌ Blocked: possible tree-mutating Bash command in the MAIN checkout." >&2
    echo "   jq is not installed, so this guard cannot parse the command" >&2
    echo "   precisely and falls back to a conservative substring scan." >&2
    echo "   Install jq to restore precise matching." >&2
    exit 2
  fi
  exit 0
fi

_analyze_text "$CMD"
# Trap handlers run when the shell exits (or later signals): judge them again
# in the state the line leaves behind.
for _t in "${DEFERRED[@]}"; do _analyze_text "$_t"; done

if [[ -n "$UNDECODED" ]]; then
  echo "❌ Blocked: text this Bash command re-parses as code (bash -c / sh -c / eval /" >&2
  echo "   trap / alias) holds a \$'…' escape that shells decode differently." >&2
  echo "   Text:    $UNDECODED" >&2
  echo "   Command: $CMD" >&2
  echo "" >&2
  echo "   \\u / \\U (literal in bash 3.2), \\cX (not decoded by zsh), \\x with no digit," >&2
  echo "   NUL and unknown escapes such as \\q or \\/ mean the guard cannot tell what the" >&2
  echo "   code does, so every write in it is unresolved. Write the characters out, or" >&2
  echo "   use \\xHH / octal escapes." >&2
  exit 2
fi

# A write went to a ~ path (or relative to a cd ~) taken as literal, but HOME
# may change later on the line (in a loop, a later assignment runs first).
if (( ! BLOCKED && TILDE_SEEN && HOME_TAINT )) && _main_in_play; then
  _main_dir
  _block "write to a ~ path on a line that may change HOME" "$RET" nonliteral
fi

# The structural backstop: judged on its own, whatever the model concluded.
if (( ! BLOCKED )); then
  _backstop
  if [[ -n "$BS_HIT" ]]; then
    _shown "$BS_HIT"
    echo "❌ Blocked (structural backstop): a Bash write this guard cannot prove stays out of a MAIN checkout." >&2
    echo "   Action:  $RET" >&2
    [[ -n "$BS_TRIG" ]] && echo "   Because: the line uses $BS_TRIG, which the guard does not fully model." >&2
    echo "   Command: $CMD" >&2
    echo "" >&2
    echo "   A literal destination inside a main checkout always blocks, and so does a" >&2
    echo "   relative one after a cd into one. On a line with case / esac, \${…=…}," >&2
    echo "   eval, trap, alias, coproc, a function or an arithmetic assignment, so does" >&2
    echo "   every destination built from an expansion and every relative one after a" >&2
    echo "   cd it cannot follow. Spell the path out, drop the construct, or run the" >&2
    echo "   command from a worktree." >&2
    _top=""
    for _d in "$BS_WHERE" "$PWD"; do
      if [[ -n "$_d" ]] && _dir_is_main "$_d"; then
        _nearest_dir "$_d"; _top=$(cd "$RET" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null); break
      fi
    done
    [[ -n "$_top" ]] && _worktree_hint "$_top" "run it"
    exit 2
  fi
fi

if (( BLOCKED )) && [[ "$BLOCK_KIND" == unresolved ]]; then
  echo "❌ Blocked: a Bash write after a directory change this guard cannot resolve." >&2
  echo "   Action:  $BLOCK_WHAT" >&2
  echo "   Command: $CMD" >&2
  echo "" >&2
  echo "   After a cd / pushd / popd whose directory is empty, an option only, an" >&2
  echo "   unknown option, more than one word, a glob, or built from an expansion" >&2
  echo "   (\$VAR, \${…}, \$(…), ~user, {a,b}), the working directory is unknown, so" >&2
  echo "   relative writes and in-place commands after it block wherever the command" >&2
  echo "   runs, even when the variable was set earlier on the same line. cd to a" >&2
  echo "   literal path (cd /abs/path), or give the write an absolute destination." >&2
  if _main_in_play; then
    _main_dir; _nearest_dir "$RET"
    _worktree_hint "$(cd "$RET" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" "run it"
  fi
  exit 2
fi

if (( BLOCKED )) && [[ "$BLOCK_KIND" == nonliteral ]]; then
  echo "❌ Blocked: a Bash write whose destination is built from an expansion," >&2
  echo "   run from a MAIN checkout." >&2
  echo "   Action:   $BLOCK_WHAT" >&2
  echo "   Checkout: $BLOCK_WHERE" >&2
  echo "   Command:  $CMD" >&2
  echo "" >&2
  echo "   From a main checkout every write destination must be a literal path:" >&2
  echo "   no \$VAR, \${…}, \$(…), \$((…)), \$'…', ~user, {a,b} or globs (\$HOME and" >&2
  echo "   \$TMPDIR included). Spell the path out (/tmp/x, ~/.cache/x), or run the" >&2
  echo "   command from a worktree." >&2
  _nearest_dir "$BLOCK_WHERE"
  _worktree_hint "$(cd "$RET" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" "run it"
  exit 2
fi

if (( BLOCKED )); then
  echo "❌ Blocked: tree-mutating Bash command targeting the MAIN checkout." >&2
  echo "   Action:  $BLOCK_WHAT" >&2
  echo "   Target:  $BLOCK_WHERE" >&2
  echo "   Command: $CMD" >&2
  echo "" >&2
  echo "   The worktree-only mandate covers Bash writes too — rsync," >&2
  echo "   bin/devcontainer-exec, git stash pop/apply, git apply, patch, sed -i," >&2
  echo "   plus redirections / tee / cp / mv whose destination is a main checkout." >&2
  _nearest_dir "$BLOCK_WHERE"
  _worktree_hint "$(cd "$RET" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" "run it"
  exit 2
fi

if [[ -n "$UNMOD_WHY" ]] && _main_in_play; then
  _shown "$UNMOD_WHY"
  echo "❌ Blocked: this Bash command uses $RET," >&2
  echo "   which this guard cannot follow, and a MAIN checkout is in play — failing closed." >&2
  echo "   Command: $CMD" >&2
  echo "" >&2
  _top=""
  for _d in "$CURDIR" "$PWD" "$DIR_ALT"; do
    if [[ -n "$_d" ]] && _dir_is_main "$_d"; then
      _nearest_dir "$_d"; _top=$(cd "$RET" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null); break
    fi
  done
  _worktree_hint "$_top" "run it"
  exit 2
fi

if (( PARSE_ERROR )) && _main_in_play; then
  echo "❌ Blocked: could not parse this Bash command confidently, and a MAIN" >&2
  echo "   checkout is in play — failing closed." >&2
  echo "   Command: $CMD" >&2
  echo "" >&2
  echo "   Simplify the command, or run it from a worktree." >&2
  exit 2
fi

exit 0
