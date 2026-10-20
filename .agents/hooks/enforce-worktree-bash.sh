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
#
# What it deliberately does NOT block:
#   * pristine-RESTORING commands (git checkout HEAD -- ., git restore,
#     git clean) and branch switches — /cleanup and /start need those on main;
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
#   * `dd of=…`, `touch`, and editors are not treated as writers.
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
  if [[ -n "${2:-}" ]]; then
    local cand="$2"
    if [[ "$cand" == *'$'* ]]; then
      # Quote loss means this can't be cached as definite, but known variables
      # in it still say where it may point (D=$ROOT, D=${ROOT%/}).
      RETDANGER=0; _subst_vars "$cand"; cand="$RET"
      if [[ "$RETDANGER" == "1" ]]; then _var_is_danger "$1" || VAR_D+=("$1"); cand=""; fi
    fi
    case "$cand" in
      '~'|'~/'*) _expand_path "$cand"; _mark_danger_if_main "$1" "$RET" ;;
      ''|*'$'*|'~'*|*':~'*) ;;   # can't evaluate: stays plain unresolvable
      *) _abs_path "$cand" "$CURDIR"; [[ "$RETUNRES" == "1" ]] || _mark_danger_if_main "$1" "$RET" ;;
    esac
  fi
  _forget "$1"
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
  BLOCK_WHAT="$1"
  BLOCK_WHERE="$2"
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
          '"'|'\'|'$'|'`') out="$out$nx"; C=$((C + 2)); continue ;;
          *)               out="$out$ch"; C=$((C + 1)); continue ;;
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
        C=$((C + 1)); _lex_context '`'; line="${LINES[L]}"; out="$out$CMDSUB"; continue
      fi
      out="$out$ch"; C=$((C + 1))
    done
    if (( C >= ${#line} )); then
      out="$out"$'\n'
      L=$((L + 1)); C=0
    fi
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
      # Queue those lines to be lexed like a double-quoted string.
      if [[ "$kind" == "U" && ( "$ln" == *'$('* || "$ln" == *'`'* ) ]]; then
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
  _abs_path "$raw" "$CURDIR"
  local p="$RET"
  if [[ "$RETDANGER" == "1" ]]; then
    _block "write to '$raw', whose variable may point into a main checkout" "$CURDIR"
    return 0
  fi
  if [[ "$DIR_DANGER" == "1" && "$raw" != /* ]]; then
    _block "relative write after cd to a directory that may be a main checkout ('$raw')" "$CURDIR"
    return 0
  fi
  if [[ "$RETUNRES" == "1" ]]; then
    # Unresolvable variable in the path. If we are sitting in a main checkout a
    # relative/unknown target may well land in it — fail closed. Elsewhere the
    # risk is speculative, so allow.
    if _dir_is_main "$CURDIR"; then
      _block "write to an unresolvable destination ('$raw')" "$CURDIR"
    fi
    return 0
  fi
  if _dir_is_main "$p"; then
    _block "write to '$raw'" "$p"
  fi
}

_block_if_cwd_main() { # $1 what — a content-introducing command run in CWD
  local what="$1"
  if [[ "$DIR_UNRESOLVED" == "1" ]]; then
    _block "$what (unresolvable cd target — fail closed)" "$CURDIR"
    return 0
  fi
  if _dir_is_main "$CURDIR"; then
    _block "$what" "$CURDIR"
  fi
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
  local -a r
  w=("${IC_WORDS[@]}")
  r=("${IC_REDIRS[@]}")
  local n=${#w[@]}
  local i=0 x base t j a prefixed=0 mode

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
  case "$base" in
    read|select)       _var_get REPLY && _var_poison REPLY ;;
    mapfile|readarray) _var_get MAPFILE && _var_poison MAPFILE ;;
    getopts)
      _var_get OPTARG && _var_poison OPTARG
      _var_get OPTIND && _var_poison OPTIND ;;
  esac

  case "$base" in
    export|declare|typeset|local|readonly)
      for a in "${args[@]}"; do
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
      return 0
      ;;
    fi|done|esac|for|case|select|function)
      LINE_CTRL=1
      ;;
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
      ;;
    source|.)
      _var_clear_all   # a sourced file can set anything
      ;;
    cd|pushd)
      local target=""
      for ((j = 0; j < ${#args[@]}; j++)); do
        case "${args[j]}" in -*) ;; *) target="${args[j]}"; break ;; esac
      done
      if [[ -z "$target" || "$target" == "-" ]]; then return 0; fi
      _abs_path "$target" "$CURDIR"
      if [[ "$RETUNRES" == "1" ]]; then
        DIR_UNRESOLVED=1
        [[ "$RETDANGER" == "1" ]] && DIR_DANGER=1
      else
        DIR_UNRESOLVED=0; DIR_DANGER=0
        _nearest_dir "$RET"
        CURDIR="$RET"
      fi
      return 0 ;;

    eval)
      _analyze_text "${args[*]}"
      return 0 ;;

    bash|sh|zsh|dash|ksh)
      # `bash -c` is a child process, so like a subshell its `cd` cannot move
      # this shell — analyse the script, then put the working directory back.
      # (`eval` above is deliberately NOT restored: it runs in the same shell,
      # so its `cd` really does persist.)
      for ((j = 0; j < ${#args[@]}; j++)); do
        if [[ "${args[j]}" == "-c" ]]; then
          local sdir="$CURDIR" sunres="$DIR_UNRESOLVED" sddanger="$DIR_DANGER"
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
          _analyze_text "${args[$((j + 1))]}"
          VAR_K=("${svk[@]}"); VAR_V=("${svv[@]}")
          CURDIR="$sdir"; DIR_UNRESOLVED="$sunres"; DIR_DANGER="$sddanger"
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
      local gdir="$CURDIR" gunres="$DIR_UNRESOLVED" sub="" sub2="" k=0
      local m=${#args[@]}
      while (( k < m )); do
        case "${args[k]}" in
          -C)
            _abs_path "${args[$((k + 1))]}" "$CURDIR"
            if [[ "$RETUNRES" == "1" ]]; then gunres=1; else gunres=0; gdir="$RET"; fi
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
      esac
      if (( mutating )); then
        if [[ "$gunres" == "1" ]]; then
          _block "git $sub (unresolvable target directory — fail closed)" "$gdir"
        else
          _nearest_dir "$gdir"
          if _is_main_checkout "$RET"; then
            _block "git $sub" "$RET"
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
    2) : ;;
    *) LX_WORDS+=("$LX_CUR") ;;
  esac
  LX_PEND=0; LX_CUR=""; LX_HAVE=0
}

_end_cmd() {
  _end_word
  local had=${#LX_WORDS[@]}
  if (( had > 0 )); then
    IC_WORDS=("${LX_WORDS[@]}")
    IC_REDIRS=("${LX_REDIRS[@]}")
    _inspect_cmd
  fi
  LX_WORDS=(); LX_REDIRS=(); LX_PEND=0
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
  local LX_CUR="" LX_HAVE=0 LX_PEND=0
  local LX_SAVED_DIR="$CURDIR" LX_SAVED_UNRES="$DIR_UNRESOLVED" LX_SAVED_DDANGER="$DIR_DANGER"
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
        else
          LX_CUR="$LX_CUR$nx"; LX_HAVE=1; C=$((C + 2))
        fi ;;
      "'")
        C=$((C + 1)); _read_sq; LX_CUR="$LX_CUR$RET"; LX_HAVE=1 ;;
      '"')
        C=$((C + 1)); _read_dq; LX_CUR="$LX_CUR$RET"; LX_HAVE=1 ;;
      '`')
        if [[ "$term" == '`' ]]; then C=$((C + 1)); _end_cmd; _leave_context; return; fi
        C=$((C + 1)); _lex_context '`'; LX_CUR="$LX_CUR$CMDSUB"; LX_HAVE=1 ;;
      '$')
        if [[ "${line:$((C + 1)):1}" == '(' ]]; then
          local arith=0; [[ "${line:$((C + 2)):1}" == '(' ]] && arith=1
          C=$((C + 2)); _lex_context ')'; LX_CUR="$LX_CUR$CMDSUB"; LX_HAVE=1
          (( arith )) && _var_clear_all   # $((D=0)) assigns in this shell
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
        if [[ "${line:C:1}" == "&" ]]; then C=$((C + 1)); LX_PEND=2; else LX_PEND=1; fi ;;
      '<')
        if [[ "$LX_CUR" =~ ^[0-9]+$ ]]; then LX_CUR=""; LX_HAVE=0; fi
        _end_word; C=$((C + 1))
        if [[ "${line:C:1}" == "<" ]]; then
          C=$((C + 1))
          if [[ "${line:C:1}" == "<" ]]; then
            C=$((C + 1)); LX_PEND=2                    # here-string
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

if (( BLOCKED )); then
  echo "❌ Blocked: tree-mutating Bash command targeting the MAIN checkout." >&2
  echo "   Action:  $BLOCK_WHAT" >&2
  echo "   Target:  $BLOCK_WHERE" >&2
  echo "   Command: $CMD" >&2
  echo "" >&2
  echo "   The worktree-only mandate covers Bash writes too — rsync," >&2
  echo "   bin/devcontainer-exec, git stash pop/apply, git apply, patch, sed -i," >&2
  echo "   plus redirections / tee / cp / mv whose destination is a main checkout." >&2
  echo "   Create a worktree first: /worktree or /start <issue>, and run it there." >&2
  exit 2
fi

if (( PARSE_ERROR )) && { _dir_is_main "$CURDIR" || _dir_is_main "$PWD"; }; then
  echo "❌ Blocked: could not parse this Bash command confidently, and a MAIN" >&2
  echo "   checkout is in play — failing closed." >&2
  echo "   Command: $CMD" >&2
  echo "" >&2
  echo "   Simplify the command, or run it from a worktree." >&2
  exit 2
fi

exit 0
