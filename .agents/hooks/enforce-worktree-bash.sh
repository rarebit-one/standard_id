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
#      install, rsync's destination, sed -i / perl -i's file arguments.
#   3. Anything it cannot parse confidently while a main checkout is in play
#      (unterminated quote, unbalanced `$(`, unresolvable `~user`/`$VAR` cd
#      target). Fail closed: an over-block on an exotic command is much cheaper
#      than letting a real write through.
#   4. Anything that makes bash do something other than what this guard models,
#      while a main checkout is in play (2026-11-23): eval, readonly /
#      declare|typeset|local -r, trap 'CMD', alias, enable, set -r, shopt
#      cdable_vars, and function definitions. Function/alias/enable/set -r also
#      make the working directory unknown for the rest of the line, so relative
#      writes after them block anywhere.
#
# Ambiguity is unresolved, and unresolved fails closed (2026-11-23):
#   * a `$` that was quoted ('$D', \$D, "\$D") is literal: the word is
#     unresolvable, never D's value. $'…' and $"…" strings are unresolvable too;
#   * an unresolvable path whose literal start is inside a main checkout
#     (`<main>/$X`) blocks from anywhere;
#   * every reading of ${D:-w} / ${D=w} / ${D:+w} … is judged, and ${D:=w} /
#     ${D=w} assign D wherever they appear (arguments, redirections,
#     here-strings, unquoted heredoc bodies);
#   * values set by set --, printf -v, read <<< and for loops are judged;
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
#   * `dd of=…`, `touch`, and editors are not treated as writers;
#   * values that only exist at run time (read from a file, $(…)) are
#     unresolvable: they block in a main checkout, not elsewhere;
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
BQ=0             # >0 while lexing inside backticks, where \$ is NOT literal

# The line does something this guard cannot follow (eval, readonly, a function
# definition, …): block when a main checkout is in play. Holds the reason.
UNMOD_WHY=""
POS_DANGER=0     # positional parameters ($1, $@, …) may hold a main-checkout path
FN_SEEN=0        # a function/alias/enable may have changed what cd and friends do
CDPATH_TAINT=0   # CDPATH is mentioned on this line: its value is not the inherited one
CREATED=()       # directories mkdir / git worktree add create on this line

_expand_path() { # $1 -> RET (expanded), RETUNRES=1 when it cannot be resolved
  local p="$1"
  RETUNRES=0
  RETDANGER=0
  case "$p" in
    '~')            p="$HOME" ;;
    '~/'*)          p="$HOME/${p#\~/}" ;;
    '$HOME')        p="$HOME" ;;
    '${HOME}')      p="$HOME" ;;
    '~'*)           RETUNRES=1 ;;   # ~otheruser — cannot resolve
  esac
  p="${p//\$\{HOME\}/$HOME}"
  p="${p//\$HOME/$HOME}"
  case "$p" in *'$'*) _subst_vars "$p"; p="$RET" ;; esac
  case "$p" in *'$'*) RETUNRES=1 ;; esac
  RET="$p"
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
  if _var_get "$1"; then _var_is_danger "$1" || VAR_D+=("$1"); fi
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
    RET=unres; return 0
  fi
  if _dir_is_main "$p"; then RET=main; return 0; fi
  RET=safe
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
      _var_poison "$nm" "$val"
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
  FN_SEEN=1; DIR_UNRESOLVED=1; DIR_DANGER=1
  _var_clear_all
}

_script_text() { # $1 lexed word -> RET: the text eval / bash -c / trap re-parse
  local s="$1" d='$'
  if [[ "$s" == *"$QLOST"* ]]; then PARSE_ERROR=1; s="${s//"$QLOST"/}"; fi
  s="${s//"$QMARK"/}"
  RET="${s//"$LITD"/$d}"
}

# Code that runs LATER (a trap handler, an alias's text): judge its writes, but
# do not let its cd or assignments change the state the rest of the line is
# judged in. Trap handlers are judged again at the end, in the line's final
# state (an EXIT handler runs then).
DEFERRED=()
_analyze_deferred() { # $1 shell text
  local sdir="$CURDIR" sunres="$DIR_UNRESOLVED" sdanger="$DIR_DANGER"
  local salt="$DIR_ALT" sguard="$ALT_GUARD" sold="$OLD_CUR"
  local snc="$NEXT_COND" snp="$NEXT_PIPE"
  local -a sstk=("${DIRSTK[@]}") svk=("${VAR_K[@]}") svv=("${VAR_V[@]}")
  _analyze_text "$1"
  CURDIR="$sdir"; DIR_UNRESOLVED="$sunres"; DIR_DANGER="$sdanger"
  DIR_ALT="$salt"; ALT_GUARD="$sguard"; OLD_CUR="$sold"
  NEXT_COND="$snc"; NEXT_PIPE="$snp"
  DIRSTK=("${sstk[@]}"); VAR_K=("${svk[@]}"); VAR_V=("${svv[@]}")
  return 0
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

_var_set() { # $1 name, $2 raw value (already lexed: quotes removed)
  _var_poison "$1"
  # Never bound, but a main-checkout value still makes it DANGER.
  _shell_managed "$1" && { _var_poison "$1" "$2"; return 0; }
  # The lexer has dropped quoting, so `P='$D'` (literal) and `P=$D` (expanded)
  # look the same here, as do `'~/x'` and `~/x`. Bind only plain literals.
  case "$2" in *'$'*|'~'*|*':~'*) _var_poison "$1" "$2"; return 0 ;; esac
  _expand_path "$2"
  [[ "$RETUNRES" == "1" ]] && return 0
  VAR_K+=("$1"); VAR_V+=("$RET")
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
  if [[ "$NEXT_PIPE" == "1" || "$LX_TERM" == "pipe" || "$LX_TERM" == "bg" ]]; then
    RET=skip
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
_poison_mentions() { # $@ words
  local wd nm i
  local -a all=()
  for wd in "$@"; do
    all+=("$wd")
    # An indirect name (`N=D; printf -v "$N"`) mentions D only after expansion.
    if [[ "$wd" == *'$'* ]]; then _subst_vars "$wd"; [[ "$RET" == "$wd" ]] || all+=("$RET"); fi
  done
  for wd in "${all[@]}"; do
    # Any mention: cd stops trusting the inherited CDPATH (a binding still wins).
    [[ "$wd" == *CDPATH* ]] && CDPATH_TAINT=1
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

_var_clear_all() { # forget every binding and bind nothing more on this line
  local i
  for ((i = 0; i < ${#VAR_K[@]}; i++)); do
    [[ -n "${VAR_K[i]}" ]] && { _var_is_danger "${VAR_K[i]}" || VAR_D+=("${VAR_K[i]}"); }
  done
  VAR_K=(); VAR_V=(); LINE_CTRL=1
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
  gd=$(cd "$d" 2>/dev/null && git rev-parse --git-dir 2>/dev/null)
  if [[ -n "$gd" ]]; then
    if [[ "$gd" != /* ]]; then
      gd=$(cd "$d" 2>/dev/null && cd "$gd" 2>/dev/null && pwd)
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

_block() { # $1 what, $2 where
  [[ "$BLOCKED" == "1" ]] && return 0
  BLOCKED=1
  _shown "$1"; BLOCK_WHAT="$RET"
  BLOCK_WHERE="$2"
}

_shown() { # $1 text -> RET with the lexer's placeholders written back as shell text
  local s="$1" lit='\$'
  s="${s//"$LITD"/$lit}"; s="${s//"$QLOST"/…}"; s="${s//"$QMARK"/}"
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

# Read a $'…' string starting at C (just past the opening quote). Unlike '…',
# a backslash escapes the quote ($'it\'s'). Simple escapes are decoded; at the
# first one that is not (\x41, \u…, octal, \cX) the rest of the string is
# lost (QLOST). The result always ends in QMARK, so as a path it stays
# unresolvable: only its literal start can be judged.
_read_ansi() {
  local out="" lost=0 line ch nx
  while :; do
    if (( L >= ${#LINES[@]} )); then PARSE_ERROR=1; break; fi
    line="${LINES[L]}"
    while (( C < ${#line} )); do
      ch="${line:C:1}"
      if [[ "$ch" == "'" ]]; then
        C=$((C + 1))
        out="${out//\$/$LITD}"
        if (( lost )); then RET="$out$QLOST$QMARK"; else RET="$out$QMARK"; fi
        return
      fi
      if [[ "$ch" == '\' ]]; then
        nx="${line:$((C + 1)):1}"
        C=$((C + 2))
        (( lost )) && continue
        case "$nx" in
          "'"|'"'|'\'|'?') out="$out$nx" ;;
          n) out="$out"$'\n' ;;
          t) out="$out"$'\t' ;;
          r) out="$out"$'\r' ;;
          a) out="$out"$'\a' ;;
          b) out="$out"$'\b' ;;
          e|E) out="$out"$'\033' ;;
          f) out="$out"$'\f' ;;
          v) out="$out"$'\v' ;;
          '') C=$((C - 1)); lost=1 ;;        # backslash at end of line
          *) lost=1 ;;
        esac
        continue
      fi
      (( lost )) || out="$out$ch"
      C=$((C + 1))
    done
    (( lost )) || out="$out"$'\n'
    L=$((L + 1)); C=0
  done
  out="${out//\$/$LITD}"
  RET="$out$QLOST$QMARK"
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
  if [[ "$kind" == "remote" && "$raw" =~ ^[^/]*: ]]; then
    return 0                                  # host:path — not this machine
  fi
  _expand_path "$raw"
  if [[ "$RETDANGER" == "1" ]]; then
    _block "write to '$raw', whose variable may point into a main checkout" "$CURDIR"
    return 0
  fi
  if [[ "$DIR_DANGER" == "1" && "$raw" != /* ]]; then
    _block "relative write after cd to a directory that may be a main checkout ('$raw')" "$CURDIR"
    return 0
  fi
  # Judge every reading of the word (defaults like ${D:-<main>} included),
  # against the working directory and, after a cd that may have failed,
  # against the directory the shell may still be in.
  local -a alts bases
  local a b unres=0
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
        unres) unres=1 ;;
      esac
    done
  done
  if (( unres )); then
    # Unresolvable variable in the path. If we are sitting in a main checkout a
    # relative/unknown target may well land in it — fail closed. Elsewhere the
    # risk is speculative, so allow.
    if _dir_is_main "$CURDIR" || { _alt_active && _dir_is_main "$DIR_ALT"; }; then
      _block "write to an unresolvable destination ('$raw')" "$CURDIR"
    fi
  fi
  return 0
}

_block_if_cwd_main() { # $1 what — a content-introducing command run in CWD
  local what="$1"
  if [[ "$DIR_UNRESOLVED" == "1" ]]; then
    _block "$what (unresolvable cd target — fail closed)" "$CURDIR"
    return 0
  fi
  if _dir_is_main "$CURDIR"; then
    _block "$what" "$CURDIR"
  elif _alt_active && _dir_is_main "$DIR_ALT"; then
    _block "$what (after a cd that may have failed: its target does not exist)" "$DIR_ALT"
  fi
}

# Change the modelled working directory the way `cd <target>` / `pushd <target>`
# would.
_cd_to() { # $1 target word
  local target="$1" old="$CURDIR" oldun="$DIR_UNRESOLVED" olddg="$DIR_DANGER"
  local e unres danger p a risky=0 viacdp="" cdp known ent
  local -a alts ents
  # A reading other than the word itself (cd "${D:-<main>}"), or an
  # unresolvable part under a main checkout, may put us in a main checkout.
  _alt_candidates "$target"; alts=("${ALTS[@]}")
  for a in "${alts[@]}"; do
    _dest_risk "$a" "$CURDIR"
    [[ "$RET" == danger ]] && risky=1
    [[ "$RET" == main && ( "$a" != "$target" || -n "$RETWHY" ) ]] && risky=1
  done
  _expand_path "$target"; e="$RET"; unres="$RETUNRES"; danger="$RETDANGER"
  # CDPATH applies to a relative target that does not start with . or ..
  if [[ "$unres" == "0" && "$e" != /* && "$e" != . && "$e" != .. && "$e" != ./* && "$e" != ../* ]]; then
    known=1; cdp=""
    if _var_get CDPATH; then cdp="$RET"
    elif [[ "$CDPATH_TAINT" == "1" ]] || _var_is_danger CDPATH; then known=0
    else cdp="${CDPATH:-}"
    fi
    if (( ! known )); then
      unres=1; danger=1
    elif [[ -n "$cdp" ]]; then
      IFS=: read -r -a ents <<< "$cdp"
      for ent in "${ents[@]}"; do
        [[ -z "$ent" ]] && ent="$CURDIR"
        [[ "$ent" != /* ]] && ent="$CURDIR/$ent"
        if [[ -d "$ent/$e" ]]; then viacdp="$ent/$e"; break; fi
      done
    fi
  fi
  if [[ "$unres" == "1" ]]; then
    DIR_UNRESOLVED=1
    [[ "$danger" == "1" ]] && DIR_DANGER=1
  else
    if [[ -n "$viacdp" ]]; then p="$viacdp"; else p="$e"; [[ "$p" != /* ]] && p="$CURDIR/$p"; fi
    if [[ -d "$p" ]] || _was_created "$p"; then
      _nearest_dir "$p"; CURDIR="$RET"; DIR_UNRESOLVED=0; DIR_DANGER=0
      # Only an absolute target settles where we are; a relative one may be
      # relative to DIR_ALT.
      [[ "$e" == /* ]] && DIR_ALT=""
    else
      # bash's cd fails here unless something this guard does not model creates
      # the directory first; the shell may then still be where it was.
      [[ -z "$DIR_ALT" ]] && DIR_ALT="$old"
      ALT_GUARD=0; [[ "$LX_TERM" == and ]] && ALT_GUARD=1
      _nearest_dir "$p"; CURDIR="$RET"
      DIR_UNRESOLVED="$oldun"; DIR_DANGER="$olddg"
    fi
  fi
  (( risky )) && { DIR_UNRESOLVED=1; DIR_DANGER=1; }
  (( FN_SEEN )) && { DIR_UNRESOLVED=1; DIR_DANGER=1; }
  OLD_CUR="$old"
  return 0
}

# Return to a directory the line visited earlier (`cd -`, `popd`). The old
# model ignored these, so a main checkout we are leaving stays a possibility.
_cd_back() { # $1 directory, or "?" when unknown
  local old="$CURDIR"
  if [[ "$1" == "?" || -z "$1" ]]; then
    DIR_UNRESOLVED=1; DIR_DANGER=1
  else
    CURDIR="$1"; DIR_UNRESOLVED=0; DIR_DANGER=0
    if _dir_is_main "$old"; then DIR_ALT="$old"; ALT_GUARD=0; fi
  fi
  (( FN_SEEN )) && { DIR_UNRESOLVED=1; DIR_DANGER=1; }
  OLD_CUR="$old"
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
  local n=${#w[@]}
  local i=0 x base t j a prefixed=0 mode

  # ${D:=…} / ${D=…} anywhere in the command assign D before anything is judged.
  _scan_default_assigns "${r[@]}" "${o[@]}" "${h[@]}" "${w[@]}"

  # Redirection targets are writes wherever the command runs.
  for t in "${r[@]}"; do
    _check_dest "$t" redir
  done

  (( n == 0 )) && return 0

  _poison_mentions "${w[@]}"

  # Strip variable assignments and command prefixes (env, sudo, xargs, …).
  while (( i < n )); do
    x="${w[i]}"
    if [[ "$x" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then i=$((i + 1)); continue; fi
    base="${x##*/}"
    case "$base" in
      then|do|else|elif|if|while|until|'{'|'}')
        LINE_CTRL=1; i=$((i + 1)); continue ;;
      env|sudo|doas|nohup|command|builtin|exec|nice|ionice|stdbuf|setsid|time|\
      '!'|'('|')')
        prefixed=1; i=$((i + 1)); continue ;;
      timeout)
        prefixed=1; i=$((i + 1))
        while (( i < n )) && [[ "${w[i]}" == -* ]]; do i=$((i + 1)); done
        i=$((i + 1)); continue ;;
      xargs)
        prefixed=1; i=$((i + 1))
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
    for ((j = 0; j < n; j++)); do
      [[ "${w[j]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && _assign "${w[j]}" "$mode"
    done
    return 0
  fi

  local name="${w[i]}"
  base="${name##*/}"
  local -a args
  args=("${w[@]:$((i + 1))}")

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
      if (( ro )); then
        _unmodelled "$base${args[0]:+ ${args[0]}} (a read-only variable: later assignments to it fail)"
        _var_clear_all
      fi
      return 0
      ;;
    fi|done|esac|for|case|select|function)
      LINE_CTRL=1
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
      # With expand_aliases, a later line runs the alias's text instead.
      for a in "${args[@]}"; do
        if [[ "$a" == *=* ]]; then
          _unmodelled "alias"
          _script_text "${a#*=}"; _analyze_deferred "$RET"
          _fn_taint
        fi
      done
      return 0 ;;
    enable)
      _unmodelled "enable (it can disable builtins such as cd)"
      _fn_taint
      return 0 ;;
    shopt)
      # cdable_vars lets `cd NAME` go to $NAME's value.
      for a in "${args[@]}"; do
        if [[ "$a" == cdable_vars ]]; then _unmodelled "shopt cdable_vars"; _fn_taint; fi
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
      if (( ${#targs[@]} >= 2 )) && [[ "${targs[0]}" != - && -n "${targs[0]}" ]]; then
        _unmodelled "trap (its command runs later in this shell)"
        _script_text "${targs[0]}"; _analyze_deferred "$RET"
        (( DEPTH == 1 )) && DEFERRED+=("$RET")
      fi
      return 0 ;;
    set)
      # set -r: restricted mode, where cd fails. Non-option words replace the
      # positional parameters.
      local pos=0
      for ((j = 0; j < ${#args[@]}; j++)); do
        a="${args[j]}"
        if (( pos )); then _value_risky "$a" && POS_DANGER=1; continue; fi
        case "$a" in
          --|-|+) pos=1 ;;
          -o|+o) j=$((j + 1)) ;;
          -*r*) _unmodelled "set -r (restricted mode: cd fails)"; _fn_taint ;;
          [-+]*) : ;;
          *) pos=1; _value_risky "$a" && POS_DANGER=1 ;;
        esac
      done
      return 0 ;;
    mkdir)
      # A directory created here makes a later cd into it succeed.
      local skipm=0
      for a in "${args[@]}"; do
        if (( skipm )); then skipm=0; continue; fi
        case "$a" in
          -m) skipm=1 ;;
          -*) : ;;
          *) _expand_path "$a"
             if [[ "$RETUNRES" == "0" ]]; then
               x="$RET"; [[ "$x" != /* ]] && x="$CURDIR/$x"
               CREATED+=("${x%/}")
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
        pv="${pv%%\[*}"
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
      ;;
    cd|pushd)
      local target="" dashdash=0
      for ((j = 0; j < ${#args[@]}; j++)); do
        if (( dashdash )); then target="${args[j]}"; break; fi
        case "${args[j]}" in
          --) dashdash=1 ;;
          -) target=-; break ;;
          [-+][0-9]*) [[ "$base" == pushd ]] && { target="?"; break; } ;;
          -*) ;;
          *) target="${args[j]}"; break ;;
        esac
      done
      if [[ "$base" == pushd ]]; then
        # pushd with no directory, or +N / -N, rotates the stack: unknown.
        if [[ -z "$target" || "$target" == "?" ]]; then _cd_back "?"; return 0; fi
        if [[ "$DIR_UNRESOLVED" == "1" ]]; then DIRSTK+=("?"); else DIRSTK+=("$CURDIR"); fi
      fi
      [[ -z "$target" ]] && return 0
      if [[ "$target" == "-" ]]; then
        if [[ -n "$OLD_CUR" ]]; then _cd_back "$OLD_CUR"; else _cd_back "?"; fi
        return 0
      fi
      _cd_to "$target"
      return 0 ;;

    popd)
      for a in "${args[@]}"; do
        case "$a" in
          -n) return 0 ;;                       # stack only, no cd
          [-+][0-9]*) _cd_back "?"; return 0 ;;
        esac
      done
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
      _script_text "${args[*]}"; _analyze_text "$RET"
      _var_clear_all
      return 0 ;;

    bash|sh|zsh|dash|ksh)
      # `bash -c` is a child process, so like a subshell its `cd` cannot move
      # this shell — analyse the script, then put the working directory back.
      # (`eval` above is deliberately NOT restored: it runs in the same shell,
      # so its `cd` really does persist.)
      for ((j = 0; j < ${#args[@]}; j++)); do
        if [[ "${args[j]}" == "-c" ]]; then
          local sdir="$CURDIR" sunres="$DIR_UNRESOLVED" sddanger="$DIR_DANGER"
          local salt="$DIR_ALT" sguard="$ALT_GUARD" sold="$OLD_CUR"
          local -a sstk=("${DIRSTK[@]}")
          # A new shell does not inherit unexported variables. Rather than
          # track export state, hide every binding while analysing the child,
          # so its expansions are unresolved (fail closed) as without bindings.
          local -a svk=("${VAR_K[@]}") svv=("${VAR_V[@]}")
          # An exported binding IS inherited: one holding a main-checkout path
          # must stay dangerous in the child, where it is hidden.
          local m
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
          _script_text "${args[$((j + 1))]}"; _analyze_text "$RET"
          VAR_K=("${svk[@]}"); VAR_V=("${svv[@]}")
          CURDIR="$sdir"; DIR_UNRESOLVED="$sunres"; DIR_DANGER="$sddanger"
          DIR_ALT="$salt"; ALT_GUARD="$sguard"; OLD_CUR="$sold"; DIRSTK=("${sstk[@]}")
          return 0
        fi
      done
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
      local gdir="$CURDIR" gunres="$DIR_UNRESOLVED" sub="" sub2="" k=0 galt=""
      local m=${#args[@]}
      _alt_active && galt="$DIR_ALT"
      while (( k < m )); do
        case "${args[k]}" in
          -C)
            _abs_path "${args[$((k + 1))]}" "$CURDIR"
            if [[ "$RETUNRES" == "1" ]]; then gunres=1; else gunres=0; gdir="$RET"; fi
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
              [[ "$RETUNRES" == "0" && "$gunres" == "0" ]] && CREATED+=("${RET%/}")
              break
            done
          fi ;;
      esac
      if (( mutating )); then
        if [[ "$gunres" == "1" ]]; then
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
    *) LX_WORDS+=("$LX_CUR") ;;
  esac
  LX_PEND=0; LX_CUR=""; LX_HAVE=0
}

_end_cmd() {
  _end_word
  local had=${#LX_WORDS[@]}
  if (( had > 0 || ${#LX_REDIRS[@]} + ${#LX_OTHER[@]} + ${#LX_HSTR[@]} > 0 )); then
    IC_WORDS=("${LX_WORDS[@]}")
    IC_REDIRS=("${LX_REDIRS[@]}")
    IC_OTHER=("${LX_OTHER[@]}")
    IC_HSTR=("${LX_HSTR[@]}")
    _inspect_cmd
  fi
  LX_WORDS=(); LX_REDIRS=(); LX_OTHER=(); LX_HSTR=(); LX_PEND=0
  # The commands after `cd <missing> &&` run only if that cd succeeded; the
  # first one ending in ; / || / & closes that and-list.
  if (( had > 0 )); then
    case "$LX_TERM" in seq|or|bg) ALT_GUARD=0 ;; esac
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

# Restore the working directory a subshell context was entered with. A `cd`
# inside `$( … )` / backticks / `( … )` is scoped to the child shell and must
# not follow the parent out. Dynamically scoped: reads `term` and the saved
# values from the _lex_context frame that calls it.
_leave_context() {
  [[ -z "$term" ]] && return 0
  CURDIR="$LX_SAVED_DIR"
  DIR_UNRESOLVED="$LX_SAVED_UNRES"
  DIR_DANGER="$LX_SAVED_DDANGER"
  DIR_ALT="$LX_SAVED_ALT"; ALT_GUARD="$LX_SAVED_GUARD"; OLD_CUR="$LX_SAVED_OLD"
  DIRSTK=("${LX_SAVED_STK[@]}")
  # Assignments in a subshell are scoped to it too.
  VAR_K=("${LX_SAVED_VK[@]}")
  VAR_V=("${LX_SAVED_VV[@]}")
  NEXT_COND="$LX_SAVED_NC"; NEXT_PIPE="$LX_SAVED_NP"; LX_TERM=seq
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
  local LX_CUR="" LX_HAVE=0 LX_PEND=0
  local LX_SAVED_DIR="$CURDIR" LX_SAVED_UNRES="$DIR_UNRESOLVED" LX_SAVED_DDANGER="$DIR_DANGER"
  local LX_SAVED_ALT="$DIR_ALT" LX_SAVED_GUARD="$ALT_GUARD" LX_SAVED_OLD="$OLD_CUR"
  local -a LX_SAVED_STK=("${DIRSTK[@]}")
  local -a LX_SAVED_VK=("${VAR_K[@]}") LX_SAVED_VV=("${VAR_V[@]}")
  local LX_SAVED_NC="$NEXT_COND" LX_SAVED_NP="$NEXT_PIPE"
  local line ch nx rest run

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
          LX_CUR="$LX_CUR$LITD"; LX_HAVE=1; C=$((C + 2))   # \$: a literal $
        else
          LX_CUR="$LX_CUR$nx"; LX_HAVE=1; C=$((C + 2))
        fi ;;
      "'")
        # Every $ in '…' is literal: mark it so it is never expanded.
        C=$((C + 1)); _read_sq; LX_CUR="$LX_CUR${RET//\$/$LITD}"; LX_HAVE=1 ;;
      '"')
        C=$((C + 1)); _read_dq; LX_CUR="$LX_CUR$RET"; LX_HAVE=1 ;;
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
          C=$((C + 2)); _read_ansi; LX_CUR="$LX_CUR$RET"; LX_HAVE=1      # $'…'
        elif [[ "${line:$((C + 1)):1}" == '"' ]]; then
          # $"…" is "…" translated through the locale: its text may change.
          C=$((C + 2)); _read_dq; LX_CUR="$LX_CUR$RET$QMARK"; LX_HAVE=1
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
        _end_cmd; C=$((C + 1))
        [[ "${line:C:1}" == ";" ]] && C=$((C + 1)) ;;
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
          LX_WORDS=(); LX_CUR=""; LX_HAVE=0
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
        if [[ "$term" == ')' ]]; then C=$((C + 1)); _end_cmd; _leave_context; return; fi
        _end_cmd; C=$((C + 1)) ;;
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

  _split_lines "$1"
  L=0; C=0; HD=()
  _lex_context ""

  LINES=("${save_lines[@]}")
  L="$save_l"; C="$save_c"; HD=("${save_hd[@]}")
  DEPTH=$((DEPTH - 1))
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

_main_in_play() { # -> 0 when the line starts, ends or may still be in a main checkout
  _dir_is_main "$CURDIR" || _dir_is_main "$PWD" || { [[ -n "$DIR_ALT" ]] && _dir_is_main "$DIR_ALT"; }
}

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
