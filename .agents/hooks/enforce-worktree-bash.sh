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
RETCOUNT=0

_expand_path() { # $1 -> RET (expanded), RETUNRES=1 when it cannot be resolved
  local p="$1"
  RETUNRES=0
  case "$p" in
    '~')            p="$HOME" ;;
    '~/'*)          p="$HOME/${p#\~/}" ;;
    '$HOME')        p="$HOME" ;;
    '${HOME}')      p="$HOME" ;;
    '~'*)           RETUNRES=1 ;;   # ~otheruser — cannot resolve
  esac
  p="${p//\$\{HOME\}/$HOME}"
  p="${p//\$HOME/$HOME}"
  case "$p" in *'$'*) RETUNRES=1 ;; esac
  RET="$p"
}

_abs_path() { # $1 path, $2 base dir -> RET absolute (unresolvable vars flagged)
  _expand_path "$1"
  local p="$RET"
  [[ "$p" != /* ]] && p="$2/$p"
  RET="$p"
}

_nearest_dir() { # $1 absolute path -> RET nearest existing ancestor directory
  local p="$1"
  while [[ -n "$p" && ! -d "$p" ]]; do
    p="${p%/*}"
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
        C=$((C + 2)); _lex_context ')'; line="${LINES[L]}"; out="$out$CMDSUB"; continue
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
  local line="${LINES[L]}" ch delim="" q
  while [[ "${line:C:1}" == " " || "${line:C:1}" == $'\t' ]]; do C=$((C + 1)); done
  while (( C < ${#line} )); do
    ch="${line:C:1}"
    case "$ch" in
      "'"|'"')
        q="$ch"; C=$((C + 1))
        while (( C < ${#line} )) && [[ "${line:C:1}" != "$q" ]]; do
          delim="$delim${line:C:1}"; C=$((C + 1))
        done
        C=$((C + 1))
        ;;
      '\')
        C=$((C + 1)); delim="$delim${line:C:1}"; C=$((C + 1))
        ;;
      ' '|$'\t'|';'|'&'|'|'|')'|'<'|'>')
        break
        ;;
      *)
        delim="$delim$ch"; C=$((C + 1))
        ;;
    esac
  done
  [[ -n "$delim" ]] && HD+=("$delim")
}

# At end of a line that opened heredocs: swallow their bodies.
_consume_heredocs() {
  local i=$((L + 1)) d ln trimmed
  local n=${#LINES[@]}
  for d in "${HD[@]}"; do
    while (( i < n )); do
      ln="${LINES[i]}"
      trimmed="$ln"
      while [[ "$trimmed" == $'\t'* ]]; do trimmed="${trimmed#	}"; done
      i=$((i + 1))
      if [[ "$ln" == "$d" || "$trimmed" == "$d" ]]; then break; fi
    done
  done
  HD=()
  L=$((i - 1))
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
  local i=0 x base t j a

  # Redirection targets are writes wherever the command runs.
  for t in "${r[@]}"; do
    _check_dest "$t" redir
  done

  (( n == 0 )) && return 0

  # Strip variable assignments and command prefixes (env, sudo, xargs, …).
  while (( i < n )); do
    x="${w[i]}"
    if [[ "$x" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then i=$((i + 1)); continue; fi
    base="${x##*/}"
    case "$base" in
      env|sudo|doas|nohup|command|builtin|exec|nice|ionice|stdbuf|setsid|time|\
      then|do|else|elif|if|while|until|'!'|'{'|'}'|'('|')')
        i=$((i + 1)); continue ;;
      timeout)
        i=$((i + 1))
        while (( i < n )) && [[ "${w[i]}" == -* ]]; do i=$((i + 1)); done
        i=$((i + 1)); continue ;;
      xargs)
        i=$((i + 1))
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
  (( i >= n )) && return 0

  local name="${w[i]}"
  base="${name##*/}"
  local -a args
  args=("${w[@]:$((i + 1))}")

  case "$base" in
    cd|pushd)
      local target=""
      for ((j = 0; j < ${#args[@]}; j++)); do
        case "${args[j]}" in -*) ;; *) target="${args[j]}"; break ;; esac
      done
      if [[ -z "$target" || "$target" == "-" ]]; then return 0; fi
      _abs_path "$target" "$CURDIR"
      if [[ "$RETUNRES" == "1" ]]; then
        DIR_UNRESOLVED=1
      else
        DIR_UNRESOLVED=0
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
          local sdir="$CURDIR" sunres="$DIR_UNRESOLVED"
          _analyze_text "${args[$((j + 1))]}"
          CURDIR="$sdir"; DIR_UNRESOLVED="$sunres"
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
  if (( ${#LX_WORDS[@]} > 0 )); then
    IC_WORDS=("${LX_WORDS[@]}")
    IC_REDIRS=("${LX_REDIRS[@]}")
    _inspect_cmd
  fi
  LX_WORDS=(); LX_REDIRS=(); LX_PEND=0
}

# Restore the working directory a subshell context was entered with. A `cd`
# inside `$( … )` / backticks / `( … )` is scoped to the child shell and must
# not follow the parent out. Dynamically scoped: reads `term` and the saved
# values from the _lex_context frame that calls it.
_leave_context() {
  [[ -z "$term" ]] && return 0
  CURDIR="$LX_SAVED_DIR"
  DIR_UNRESOLVED="$LX_SAVED_UNRES"
}

_lex_context() { # $1 terminator: "" (EOF), ")" or "`"
  local term="$1"
  # Per-invocation lexer state. Declared `local` so nested contexts (command
  # substitutions, subshells) get their own; the _end_word/_end_cmd helpers see
  # the innermost one through bash's dynamic scoping.
  local -a LX_WORDS=()
  local -a LX_REDIRS=()
  local LX_CUR="" LX_HAVE=0 LX_PEND=0
  local LX_SAVED_DIR="$CURDIR" LX_SAVED_UNRES="$DIR_UNRESOLVED"
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
          C=$((C + 2)); _lex_context ')'; LX_CUR="$LX_CUR$CMDSUB"; LX_HAVE=1
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
        _end_cmd; C=$((C + 1))
        case "${line:C:1}" in '|'|'&') C=$((C + 1)) ;; esac ;;
      '&')
        if [[ "${line:$((C + 1)):1}" == ">" ]]; then
          _end_word; C=$((C + 2))
          [[ "${line:C:1}" == ">" ]] && C=$((C + 1))
          LX_PEND=1
        else
          _end_cmd; C=$((C + 1))
          [[ "${line:C:1}" == "&" ]] && C=$((C + 1))
        fi ;;
      '(')
        _end_cmd; C=$((C + 1)); _lex_context ')' ;;
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
