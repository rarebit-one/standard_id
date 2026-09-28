#!/bin/bash
# Pre-push prepare hook for Claude Code
#
# Runs on PreToolUse event for Bash commands containing "git push" or "gh pr create"
# Keeps feature branches up-to-date and encourages single-commit PRs.
#
# What it does:
#   1. Fetches latest target branch and rebases current branch onto it
#   2. If rebase changes history, injects --force-with-lease into git push
#   3. Checks commit count and blocks if >1 commit (prompts user to squash)
#   4. For `gh pr create`, when rebase changed history: blocks and asks
#      for an explicit `git push --force-with-lease` first, so the push
#      goes through the agent's permission system.
#
# Exit codes:
#   0 - Allow (optionally with modified command)
#   2 - Block (rebase conflict, dirty working tree, or multiple commits)
#
# To skip entirely:
#   SKIP_PRE_PUSH_PREPARE=1 git push ...
#
# To allow multiple commits:
#   ALLOW_MULTIPLE_COMMITS=1 git push ...

set -e

# Require jq for JSON parsing
if ! command -v jq &>/dev/null; then
  echo "❌ pre-push-prepare hook requires 'jq'. Install it and retry." >&2
  exit 0
fi

# Read tool input from stdin
INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

# Detect command type
# --- which checkout is being pushed ------------------------------------------
# A PreToolUse hook runs BEFORE the command, in the session's cwd, so for the usual
# `cd <worktree> && git push` (or `git -C <worktree> push`) the checkout being
# pushed is not the hook's cwd. Acting on the cwd meant: from a workspace root the
# hook silently did nothing, and from a main checkout it could rebase the WRONG tree.
# The resolver below started as a port of sidekick-labs/sidekick-harness
# (.claude/hooks/lib/resolve-push-root.sh, ai-foundations-brain#745), inlined because
# estate hooks are vendored as single files; since agent-estate#20 it lexes the
# command instead of splitting its text. Its tests live in
# hooks/tests/resolve-push-root.test.sh and hooks/tests/pre-push-prepare.test.sh.

# Matches `git push` and `git -C <dir> push`. The -C form must be gated by
# both hooks — it is the documented way to push a worktree from elsewhere,
# and when it went unmatched the "use git -C" error message was advice to
# bypass the gate. Defined here so the two hooks cannot drift apart.
# shellcheck disable=SC2034  # consumed by the sourcing hooks
GIT_PUSH_RE='(^|[[:space:]&;|])git[[:space:]]+(-C[[:space:]]+("[^"]+"|'\''[^'\'']+'\''|[^[:space:]]+)[[:space:]]+)?push([[:space:]]|$)'

# _seg_is_push <segment>
# True when a single command segment (no shell separators) is the push:
# a `git … push` invocation or a `gh pr create`.
_seg_is_push() {
  # the push itself: `git [-C <dir>] push`, adjacent. Any segment that merely
  # CONTAINS both words (`git commit -m "fix push"`) used to match, and a cd before
  # it then selected the wrong checkout (review finding on the estate rollout).
  if [[ "$1" =~ $GIT_PUSH_RE ]]; then
    return 0
  fi
  [[ "$1" =~ (^|[[:space:]])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$) ]]
}

# --- lexing -------------------------------------------------------------------
# _rpr_lex <command>
# Splits a command line into simple-command segments the way the shell would,
# honouring quotes ('…', "…", $'…'), backslash escapes, $(…) and `…` (nested),
# comments and heredoc bodies. A separator inside any of those does not split,
# and text inside them never looks like a `cd` or a push: every segment also has
# a MASK of the same length in which quoted/substituted text is `x`, and all
# matching runs on the mask. (Splitting the raw text on `&&`/`;`/`|` made
# `git commit -m "x; cd ../other"` a phantom cd, and a quoted `|` a pipeline —
# review findings on the 3dd9736 re-vendor, agent-estate#20.)
#
# Fills RPR_SEG[i] (raw text), RPR_MASK[i] and RPR_SEP[i], the separator that
# ENDS segment i: `&&` `||` `|` `;` `nl` `&` (background) `(` `)` `;;` `eof`.
# RPR_BAD=1 on an unterminated quote or substitution; RPR_LEAD=1 when the line
# opens with a subshell/`;;` (a separator with no segment before it).
_rpr_lex() {
  local LC_ALL=C
  local s="$1" n i=0 ch nx ctx="" top raw="" mask="" d q line rest re run
  local -a hd=()
  RPR_SEG=(); RPR_MASK=(); RPR_SEP=(); RPR_BAD=0; RPR_LEAD=0
  n=${#s}
  while (( i < n )); do
    top="${ctx: -1}"
    # consume a run of characters that mean nothing in this context in one step
    # (character-at-a-time is quadratic on a long `gh pr create --body …`)
    case "$top" in
      "'") re="^[^']+" ;;
      a) re="^[^'\\]+" ;;
      '"') re='^[^"\\$`]+' ;;
      '`') re='^[^`\\]+' ;;
      b) re=$'^[^\\\'"`${}\n]+' ;;
      *) re=$'^[^\\\'"`$<#;&|()\n]+' ;;
    esac
    if [[ "${s:i}" =~ $re ]]; then
      run="${BASH_REMATCH[0]}"
      raw+="$run"; i=$((i + ${#run}))
      if [[ -z "$top" ]]; then
        mask+="$run"
      else
        printf -v run '%*s' "${#run}" ''; mask+="${run// /x}"
      fi
      continue
    fi
    ch="${s:i:1}"; nx="${s:i+1:1}"
    if [[ -n "$top" && "$top" != "(" && "$top" != b ]]; then
      # inside '…', $'…', "…" or `…`: only its own terminator (and, in "…",
      # a nested substitution) matters
      if [[ "$ch" == '\' && "$top" != "'" ]]; then
        raw+="$ch$nx"; mask+="xx"; i=$((i + 2)); continue
      fi
      case "$top$ch" in
        "''"|"a'"|'""'|'``') ctx="${ctx%?}" ;;
        '"`') ctx+='`' ;;
        '"$') [[ "$nx" == "(" ]] && { ctx+="("; raw+='$('; mask+="xx"; i=$((i + 2)); continue; } ;;
      esac
      raw+="$ch"; mask+="x"; i=$((i + 1)); continue
    fi
    # top level, $( … ) or ${ … }: quotes, escapes, substitutions, heredocs
    case "$ch" in
      '\')
        if [[ "$nx" == $'\n' ]]; then i=$((i + 2)); continue; fi   # continuation
        raw+="$ch$nx"; mask+="xx"; i=$((i + 2)); continue ;;
      "'"|'"'|'`')
        ctx+="$ch"; raw+="$ch"; mask+="x"; i=$((i + 1)); continue ;;
      '$')
        if [[ "$nx" == "(" ]]; then ctx+="("; raw+='$('; mask+="xx"; i=$((i + 2)); continue; fi
        if [[ "$nx" == "{" ]]; then ctx+="b"; raw+='${'; mask+="xx"; i=$((i + 2)); continue; fi
        if [[ "$nx" == "'" ]]; then ctx+="a"; raw+="\$'"; mask+="xx"; i=$((i + 2)); continue; fi ;;
      '<')
        if [[ "${s:i:3}" == "<<<" ]]; then
          raw+="<<<"; mask+="<<<"; i=$((i + 3)); continue
        fi
        if [[ "$nx" == "<" ]]; then
          # heredoc: note its delimiter; the body is skipped at the next newline
          raw+="<<"; mask+="<<"; i=$((i + 2)); q=" "
          [[ "${s:i:1}" == "-" ]] && { raw+="-"; mask+="-"; i=$((i + 1)); q="-"; }
          while [[ "${s:i:1}" == " " || "${s:i:1}" == $'\t' ]]; do raw+=" "; mask+=" "; i=$((i + 1)); done
          d="$q"   # delimiter entries are "-EOF" for <<- (tabs stripped), " EOF" for <<
          while (( i < n )); do
            ch="${s:i:1}"
            case "$ch" in
              "'"|'"')
                q="$ch"; raw+="$ch"; mask+="x"; i=$((i + 1))
                while (( i < n )) && [[ "${s:i:1}" != "$q" ]]; do
                  d+="${s:i:1}"; raw+="${s:i:1}"; mask+="x"; i=$((i + 1))
                done
                raw+="$q"; mask+="x"; i=$((i + 1)) ;;
              '\') d+="${s:i+1:1}"; raw+="\\${s:i+1:1}"; mask+="xx"; i=$((i + 2)) ;;
              ' '|$'\t'|$'\n'|';'|'&'|'|'|'('|')'|'<'|'>') break ;;
              *) d+="$ch"; raw+="$ch"; mask+="x"; i=$((i + 1)) ;;
            esac
          done
          [[ ${#d} -gt 1 ]] && hd+=("$d")
          continue
        fi ;;
    esac
    if [[ "$ch" == $'\n' && ${#hd[@]} -gt 0 && "$top" != b ]]; then
      # swallow the bodies of the heredocs opened on this line
      i=$((i + 1))
      for d in "${hd[@]}"; do
        while (( i < n )); do
          rest="${s:i}"; line="${rest%%$'\n'*}"
          i=$((i + ${#line} + 1))
          if [[ "${d:0:1}" == "-" ]]; then
            while [[ "$line" == $'\t'* ]]; do line="${line#?}"; done
          fi
          [[ "$line" == "${d:1}" ]] && break
        done
      done
      hd=()
      [[ "$top" == "(" ]] || _rpr_emit nl   # the line's own newline ends it
      continue
    fi
    if [[ "$top" == "(" ]]; then
      case "$ch" in
        "(") ctx+="(" ;;
        ")") ctx="${ctx%?}" ;;
      esac
      raw+="$ch"; mask+="x"; i=$((i + 1)); continue
    fi
    if [[ "$top" == b ]]; then   # inside ${ … }: `;`, `#`, `|` are operators of the expansion
      [[ "$ch" == "}" ]] && ctx="${ctx%?}"
      raw+="$ch"; mask+="x"; i=$((i + 1)); continue
    fi
    case "$ch" in
      # context is read off the MASK, where an escaped char is `x`: `\ #` is a
      # word, not a comment, and `\>&` is a background & (review finding)
      '#')
        if [[ -z "$mask" || "${mask: -1}" == " " || "${mask: -1}" == $'\t' ]]; then
          rest="${s:i}"; line="${rest%%$'\n'*}"; i=$((i + ${#line})); continue
        fi ;;
      ';')
        if [[ "$nx" == ";" ]]; then _rpr_emit ';;'; i=$((i + 2)); continue; fi
        _rpr_emit ';'; i=$((i + 1)); continue ;;
      $'\n') _rpr_emit nl; i=$((i + 1)); continue ;;
      '&')
        if [[ "$nx" == "&" ]]; then _rpr_emit '&&'; i=$((i + 2)); continue; fi
        if [[ "$nx" != ">" && "${mask: -1}" != ">" && "${mask: -1}" != "<" ]]; then
          _rpr_emit '&'; i=$((i + 1)); continue
        fi ;;
      '|')
        if [[ "$nx" == "|" ]]; then _rpr_emit '||'; i=$((i + 2)); continue; fi
        if [[ "${mask: -1}" != ">" ]]; then
          _rpr_emit '|'; i=$((i + 1)); [[ "$nx" == "&" ]] && i=$((i + 1)); continue
        fi ;;
      '('|')') _rpr_emit "$ch"; i=$((i + 1)); continue ;;
    esac
    raw+="$ch"; mask+="$ch"; i=$((i + 1))
  done
  [[ -n "$ctx" ]] && RPR_BAD=1
  _rpr_emit eof
}

# _rpr_emit <separator>: close the current segment (called from _rpr_lex).
# A blank segment is dropped, except that it still ends a list — a line break
# after `&&`/`||`/`|` is a continuation and ends nothing.
_rpr_emit() {
  if [[ "$raw" =~ ^[[:space:]]*$ ]]; then
    local last=$(( ${#RPR_SEP[@]} - 1 ))
    if (( last >= 0 )); then
      case "${RPR_SEP[last]}:$1" in
        '&&:nl'|'||:nl'|'|:nl'|*:eof) ;;
        *:'('|*:')'|*:';;') RPR_SEP[last]="$1" ;;
      esac
    else
      case "$1" in '('|')'|';;') RPR_LEAD=1 ;; esac   # e.g. a leading `(`
    fi
    raw=""; mask=""
    return
  fi
  RPR_SEG+=("$raw"); RPR_MASK+=("$mask"); RPR_SEP+=("$1")
  raw=""; mask=""
}

# _rpr_word <raw-text> <offset>
# Reads the shell word at <offset> and sets RPR_W to the path it names, with a
# leading `~`/`~/` expanded. RPR_WOK=0 when the value is only known at run time
# ($VAR, $(…), `…`, a glob * ? [ ], a brace {a,b}, ~user/~+/~-, or an option
# such as `-P`/`--`): those cannot be followed here, so the target is unknown.
# RPR_WOK=2 when there is no word at all (a bare `cd`).
_rpr_word() {
  local LC_ALL=C
  local s="$1" i="$2" n ch w="" started=0
  n=${#s}
  RPR_WOK=1
  while (( i < n )); do
    ch="${s:i:1}"
    case "$ch" in
      # an unquoted & left in a segment is a redirection (`&>`, `&>>`)
      ' '|$'\t'|'<'|'>'|'&') break ;;
      "'")
        started=1; i=$((i + 1))
        while (( i < n )) && [[ "${s:i:1}" != "'" ]]; do w+="${s:i:1}"; i=$((i + 1)); done
        i=$((i + 1)) ;;
      '"')
        started=1; i=$((i + 1))
        while (( i < n )) && [[ "${s:i:1}" != '"' ]]; do
          ch="${s:i:1}"
          [[ "$ch" == '$' || "$ch" == '`' ]] && RPR_WOK=0
          if [[ "$ch" == '\' ]]; then
            # in "…" a backslash escapes only $ ` " \ and a newline; before
            # anything else bash keeps it (review finding)
            case "${s:i+1:1}" in
              '$'|'`'|'"'|'\') i=$((i + 1)); ch="${s:i:1}" ;;
              $'\n') i=$((i + 2)); continue ;;
            esac
          fi
          w+="$ch"; i=$((i + 1))
        done
        i=$((i + 1)) ;;
      '\') started=1; w+="${s:i+1:1}"; i=$((i + 2)) ;;
      '$'|'`'|'*'|'?'|'['|'{') RPR_WOK=0; started=1; w+="$ch"; i=$((i + 1)) ;;
      '~')
        if (( started == 0 )); then
          case "${s:i+1:1}" in
            ''|' '|$'\t'|'/') w+="$HOME" ;;
            *) RPR_WOK=0; w+="$ch" ;;
          esac
        else
          w+="$ch"
        fi
        started=1; i=$((i + 1)) ;;
      *) started=1; w+="$ch"; i=$((i + 1)) ;;
    esac
  done
  RPR_W="$w"
  (( started == 0 )) && RPR_WOK=2
  [[ "$RPR_WOK" == 1 && "$w" == -* ]] && RPR_WOK=0
  return 0
}

# _resolve_dir <base> <dir>
# Prints the absolute directory `cd <dir>` would land in when run from <base>.
# Returns non-zero if either does not exist.
_resolve_dir() {
  (cd "$1" >/dev/null 2>&1 && cd "$2" >/dev/null 2>&1 && pwd)
}

# _rpr_kind <mask>: what a simple command does to the shell's directory/flow.
#   cd       a plain `cd [dir]`
#   cdish    any other cd/pushd/popd (`if cd x`, `{ cd x`, `pushd x`), or an
#            eval/source/. that may cd invisibly: unmodelled
#   control  a compound-command keyword: flow this resolver does not model
#   exit     `exit`/`return` [n]      true  `true`/`:`      false  `false`
#   other    anything else: its exit status is unknown
_rpr_kind() {
  local m="$1"
  if [[ "$m" =~ ^[[:space:]]*cd([[:space:]]|$) ]]; then RPR_KIND=cd
  elif [[ "$m" =~ (^|[[:space:]])(cd|pushd|popd)([[:space:]]|$) ]]; then RPR_KIND=cdish
  # eval/source/. run text this resolver cannot see in the CURRENT shell
  elif [[ "$m" =~ (^|[[:space:]])(eval|source|\.)([[:space:]]|$) ]]; then RPR_KIND=cdish
  elif [[ "$m" =~ ^[[:space:]]*(if|then|else|elif|fi|while|until|do|done|for|select|case|esac|function|\{|\})([[:space:]]|$) ]]; then RPR_KIND=control
  elif [[ "$m" =~ ^[[:space:]]*(exit|return)([[:space:]]+[0-9]+)?[[:space:]]*$ ]]; then RPR_KIND=exit
  elif [[ "$m" =~ ^[[:space:]]*(true|:)[[:space:]]*$ ]]; then RPR_KIND=true
  elif [[ "$m" =~ ^[[:space:]]*false[[:space:]]*$ ]]; then RPR_KIND=false
  else RPR_KIND=other
  fi
}

# _rpr_cd <segment-index> <mode>
# Applies a plain `cd` to eff/eff_known (resolve_push_root's locals). <mode>:
#   certain  the cd runs
#   maybe    the cd may or may not run (it follows a command whose exit status
#            is unknown): a cd that would move the shell makes it unknown
#   must     the push runs only if this cd succeeded (it is `&&`-chained to it)
# Sets RPR_CD to ok | fail (a certain failure: the directory is unchanged) |
# unk | abort (with `must`: the push cannot run from a directory known here).
_rpr_cd() {
  local k="$1" mode="$2" m off next from rest word
  local redir='[[:space:]]*[0-9]*(&>>?|[<>]+[&|]?)[[:space:]]*[^[:space:]<>&]*'
  m="${RPR_MASK[k]}"
  [[ "$m" =~ ^[[:space:]]*cd[[:space:]]* ]]
  off=${#BASH_REMATCH[0]}
  rest="${m:off}"
  # the shape must be `cd [dir] [redirections]`. A redirection BEFORE the
  # operand (`cd >/dev/null dir`), an fd-numbered one read as the operand
  # (`cd 2>x`), or extra operands (`cd a b` fails in bash) are not followed
  # (review finding: `cd >/dev/null .` read as a bare cd, i.e. $HOME).
  if [[ "$rest" =~ ^([^[:space:]\<\>\&]+)?(${redir})*[[:space:]]*$ ]]; then
    word="${BASH_REMATCH[1]}"
    if [[ "$word" =~ ^[0-9]+$ && "${rest:${#word}:1}" == [\<\>] ]]; then
      eff_known=0; RPR_CD=unk; return 0
    fi
  else
    eff_known=0; RPR_CD=unk; return 0
  fi
  _rpr_word "${RPR_SEG[k]}" "$off"
  if [[ "$RPR_WOK" == 2 ]]; then RPR_W="$HOME"; RPR_WOK=1; fi   # bare `cd`
  if [[ "$RPR_WOK" != 1 ]]; then
    eff_known=0; RPR_CD=unk; return 0
  fi
  if [[ "$RPR_W" == /* ]]; then
    from=/
  elif [[ "$eff_known" == 1 ]]; then
    from="$eff"
  else
    RPR_CD=unk; return 0      # relative to an unknown directory stays unknown
  fi
  if next=$(_resolve_dir "$from" "$RPR_W"); then
    if [[ "$mode" == maybe ]]; then
      [[ "$eff_known" == 1 && "$next" == "$eff" ]] || eff_known=0
      RPR_CD=unk
    else
      eff="$next"; eff_known=1; RPR_CD=ok
    fi
    return 0
  fi
  # the target does not exist now. bash's cd would fail and leave the shell
  # where it was — unless an earlier command in this line creates it
  # (`git worktree add ../wt; cd ../wt`), which cannot be known here.
  if [[ "$mode" == must ]]; then
    RPR_CD=abort
  elif [[ "$mutated" == 1 || "$mode" == maybe ]]; then
    eff_known=0; RPR_CD=unk
  else
    RPR_CD=fail
  fi
}

# resolve_push_root <command> <hook-input-json>
#
# Prints the absolute toplevel of the checkout the push (`git [-C <dir>] push`
# or `gh pr create`) runs in, or returns non-zero; the hook then skips — it never
# blocks. The rule throughout: when it cannot be CERTAIN which checkout is being
# pushed, it returns non-zero rather than name one. Acting on the wrong checkout
# (rebasing it, counting its commits) is the failure that matters; a skipped
# rebase is cheap.
#
# The start directory is the session cwd from the hook's stdin JSON (`.cwd`,
# with the nested `.context.cwd` shape as fallback), else the hook's $PWD. The
# command is lexed (_rpr_lex) and walked up to the push, tracking where each
# `cd` leaves the shell:
#   * a cd resolves against the directory the previous one left; a relative cd
#     from an unknown directory stays unknown, an absolute one (or `~`)
#     re-anchors. A bare `cd` is $HOME.
#   * a cd whose target is only known at run time ($VAR, `cd -`, a glob or brace,
#     ~user, an option) makes the directory unknown.
#   * a cd in a pipeline stage or a backgrounded (`&`) list runs in a subshell
#     and moves nothing.
#   * `&&` chains: before the push, `a && cd x && git push` means every step
#     succeeded if the push runs, so each cd applies — and one whose target
#     does not exist means the push never runs from a directory known here
#     (skip). In a list that ends before the push, a cd that follows a command
#     with an unknown exit status may not have run: unknown.
#   * `||`: a cd on either side of `||` makes the directory unknown — which side
#     ran is not knowable. The one exception is `cd <dir> || exit|return [n]`,
#     after which the shell can only still be running in <dir>.
#   * a literal cd to a missing directory fails and leaves the directory as it
#     was — unless an earlier command could have created it, when it is unknown.
#   * subshells `( … )`, braces and compound commands (if/for/while/case) are
#     not modelled: with any cd before the push, the result is unknown.
# The push segment's own `-C <dir>` then decides: an absolute -C resolves on its
# own; a relative one resolves against the tracked directory, and fails when that
# is unknown. An explicit -C that does not resolve is final (git would exit with
# "cannot change to"), never a fallback.
resolve_push_root() {
  local command="$1" input="$2"
  local session_cwd base eff eff_known=1 mutated=0 saw_cd=0 complex=0
  local k p=-1 s0=0 n sep m kind toplevel

  session_cwd=$(printf '%s' "$input" | jq -r '.cwd // .context.cwd // ""' 2>/dev/null) \
    || session_cwd=""
  if [[ -z "$session_cwd" ]]; then
    # No cwd in the payload — fall back to the hook process's own cwd, which
    # in the worktree-only workflow is the main checkout. That is exactly the
    # wrong tree, so say so out loud: if the hook payload schema ever drops
    # or renames `cwd`, this must be a visible degradation rather than a
    # silent return to the afb#745 behavior.
    echo "⚠️  resolve_push_root: no cwd in hook payload; falling back to \$PWD ($PWD)." >&2
    echo "   If pushes are being validated against the wrong checkout, the hook" >&2
    echo "   input schema likely changed — see resolve_push_root in pre-push-prepare.sh." >&2
  fi
  base="${session_cwd:-$PWD}"
  eff="$base"

  _rpr_lex "$command"
  [[ "$RPR_BAD" == 1 ]] && return 1
  complex="$RPR_LEAD"
  n=${#RPR_SEG[@]}

  # the push is the first segment that IS one (on the mask, so a commit message
  # mentioning "git push" is not it); its and-or list starts after the last
  # list terminator before it
  for (( k = 0; k < n; k++ )); do
    if _seg_is_push "${RPR_MASK[k]}"; then p=$k; break; fi
  done
  (( p >= 0 )) || return 1
  # GIT_DIR / GIT_WORK_TREE point the push at another repository entirely.
  # Checked on the RAW text, so a quoted `export "GIT_DIR=…"` / `env "…"` is
  # caught too (review finding); a mere mention in an argument also skips,
  # which is the safe direction.
  local git_env_re='(^|[[:space:]"'\''])GIT_(DIR|WORK_TREE)='
  for (( k = 0; k <= p; k++ )); do
    [[ "${RPR_SEG[k]}" =~ $git_env_re ]] && return 1
  done
  for (( k = 0; k < p; k++ )); do
    case "${RPR_SEP[k]}" in
      nl|';'|'&'|'('|')'|';;') s0=$((k + 1)) ;;
    esac
  done

  # --- lists that end before the push's own list ------------------------------
  local ls=0 le has_or piped alive
  while (( ls < s0 )); do
    le=$ls
    while (( le < s0 - 1 )); do
      case "${RPR_SEP[le]}" in '&&'|'||'|'|') le=$((le + 1)) ;; *) break ;; esac
    done
    sep="${RPR_SEP[le]}"
    case "$sep" in '('|')'|';;') complex=1 ;; esac
    has_or=0
    for (( k = ls; k < le; k++ )); do [[ "${RPR_SEP[k]}" == '||' ]] && has_or=1; done
    alive=certain
    for (( k = ls; k <= le; k++ )); do
      _rpr_kind "${RPR_MASK[k]}"; kind="$RPR_KIND"
      [[ "$kind" == control ]] && complex=1
      [[ "$kind" == cd || "$kind" == cdish ]] && saw_cd=1
      piped=0
      [[ "${RPR_SEP[k]}" == '|' ]] && piped=1
      (( k > ls )) && [[ "${RPR_SEP[k-1]}" == '|' ]] && piped=1
      if [[ "$sep" == '&' || "$piped" == 1 ]]; then
        # a subshell: a cd there moves nothing, and its status is unknown
        [[ "$kind" == cd || "$kind" == cdish ]] || mutated=1
        [[ "$sep" == '&' ]] || alive=maybe
        continue
      fi
      if [[ "$has_or" == 1 ]]; then
        # `cd <dir> || exit` — the only `||` shape whose surviving path is known
        if (( le == ls + 1 )) && [[ "$kind" == cd && "${RPR_SEP[ls]}" == '||' ]] \
          && { _rpr_kind "${RPR_MASK[le]}"; [[ "$RPR_KIND" == exit ]]; }; then
          _rpr_cd "$k" must
          [[ "$RPR_CD" == abort ]] && eff_known=0
          break
        fi
        case "$kind" in
          cd|cdish) eff_known=0 ;;
          other) mutated=1 ;;
        esac
        continue
      fi
      [[ "$alive" == dead ]] && break
      case "$kind" in
        cd)
          _rpr_cd "$k" "$alive"
          case "$RPR_CD" in fail) alive=dead ;; unk) alive=maybe ;; esac ;;
        cdish) eff_known=0; alive=maybe ;;
        exit) [[ "$alive" == certain ]] && return 1 ;;   # the push never runs
        false) [[ "$alive" == certain ]] && alive=dead ;;
        true) ;;
        *) mutated=1; alive=maybe ;;
      esac
    done
    ls=$((le + 1))
  done

  # --- the push's own list: the steps before the push, and the push ----------
  has_or=0
  for (( k = s0; k < p; k++ )); do [[ "${RPR_SEP[k]}" == '||' ]] && has_or=1; done
  for (( k = s0; k < p; k++ )); do
    _rpr_kind "${RPR_MASK[k]}"; kind="$RPR_KIND"
    [[ "$kind" == control ]] && complex=1
    [[ "$kind" == cd || "$kind" == cdish ]] && saw_cd=1
    [[ "${RPR_SEP[k]}" == '|' ]] && continue          # a pipeline stage
    (( k > s0 )) && [[ "${RPR_SEP[k-1]}" == '|' ]] && continue
    if [[ "$has_or" == 1 ]]; then
      # which side of the `||` ran is unknowable: any cd here is fatal
      [[ "$kind" == cd || "$kind" == cdish ]] && return 1
      continue
    fi
    # `&&` all the way: if the push runs, every step here ran and succeeded
    case "$kind" in
      cd)
        _rpr_cd "$k" must
        [[ "$RPR_CD" == abort ]] && return 1 ;;
      cdish) eff_known=0 ;;
      exit|false) return 1 ;;
    esac
  done
  m="${RPR_MASK[p]}"
  _rpr_kind "$m"
  [[ "$RPR_KIND" == control ]] && complex=1

  # subshells, braces and compound commands are not modelled; with a cd in play
  # the directory the push runs in is not knowable
  [[ "$complex" == 1 && "$saw_cd" == 1 ]] && return 1

  # the push segment's own `git -C <dir>`
  if [[ "$m" =~ ^(.*[[:space:]]|)git[[:space:]]+-C[[:space:]]* ]]; then
    local off=${#BASH_REMATCH[0]} rest from
    rest="${m:off}"
    # `git -C a -C b push` composes; not modelled
    [[ "$rest" =~ ^[^[:space:]]+[[:space:]]+-C([[:space:]]|$) ]] && return 1
    _rpr_word "${RPR_SEG[p]}" "$off"
    [[ "$RPR_WOK" == 1 ]] || return 1
    if [[ "$RPR_W" == /* ]]; then
      from=/
    elif [[ "$eff_known" == 1 ]]; then
      from="$eff"
    else
      # relative to a directory this process cannot know (review finding:
      # `cd "$WT" && git -C child push` resolved cwd/child)
      return 1
    fi
    eff=$(_resolve_dir "$from" "$RPR_W") || return 1
    eff_known=1
  fi

  [[ "$eff_known" == 1 ]] || return 1
  toplevel=$(cd "$eff" >/dev/null 2>&1 && git rev-parse --show-toplevel 2>/dev/null) || return 1
  [[ -n "$toplevel" ]] || return 1
  printf '%s' "$toplevel"
}

# push_root_in_scope <resolved-root>
# 0 when this hook should act on <resolved-root>. A copy vendored inside a repo
# (.agents/hooks/ or .claude/hooks/) acts only on that repo's checkouts (main or
# any linked worktree); a push of some other repo is left to that repo's own hook.
# The canonical copy, and a workspace root (not a git checkout, its hooks linked
# in), act on every push.
push_root_in_scope() {
  local root="$1" here hooks_common root_common
  here="$(dirname "${BASH_SOURCE[0]}")"
  # only a copy VENDORED into a repo is repo-scoped; the canonical copy
  # (agent-estate/hooks) and a workspace-root link act on every push
  case "$here" in
    */.agents/hooks|*/.claude/hooks) ;;
    *) return 0 ;;
  esac
  hooks_common=$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || return 0
  root_common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [[ "$root_common" == "$hooks_common" ]]
}

IS_GIT_PUSH=false
IS_GH_PR_CREATE=false

if [[ "$COMMAND" =~ $GIT_PUSH_RE ]]; then
  IS_GIT_PUSH=true
elif [[ "$COMMAND" =~ (^|[[:space:]\&\;\|])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$) ]]; then
  IS_GH_PR_CREATE=true
fi

if [[ "$IS_GIT_PUSH" == "false" && "$IS_GH_PR_CREATE" == "false" ]]; then
  exit 0
fi

# Allow skipping the entire hook
# Note: env var check works when exported in the shell session.
# The inline prefix form (SKIP_PRE_PUSH_PREPARE=1 git push) is matched via $COMMAND
# since inline env vars only apply to the subprocess, not the hook process.
if [[ "${SKIP_PRE_PUSH_PREPARE:-}" == "1" ]] || [[ "$COMMAND" == SKIP_PRE_PUSH_PREPARE=1* ]]; then
  echo "⏭️  Pre-push prepare hook skipped (SKIP_PRE_PUSH_PREPARE=1)" >&2
  exit 0
fi

# Skip in CI environments
if [[ "${CI:-}" == "true" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  exit 0
fi

# Act on the checkout being pushed, not on the hook's cwd.
if ! ROOT=$(resolve_push_root "$COMMAND" "$INPUT"); then
  echo "⚠️  pre-push-prepare: could not resolve the checkout being pushed; skipping rebase/commit checks." >&2
  exit 0
fi
if ! push_root_in_scope "$ROOT"; then
  exit 0
fi
cd "$ROOT"

# Get current branch (skip if detached HEAD). `|| true` absorbs the non-zero
# exit from git symbolic-ref when HEAD is detached so `set -e` doesn't bail
# before the -z guard fires.
CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || true)
if [[ -z "$CURRENT_BRANCH" ]]; then
  exit 0
fi

# Determine default branch
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}

# Don't rebase if on the default branch
if [[ "$CURRENT_BRANCH" == "$DEFAULT_BRANCH" ]]; then
  exit 0
fi

# --- Step 1: Fetch and Rebase ---

REBASE_HAPPENED=false

echo "🔄 Fetching latest $DEFAULT_BRANCH..." >&2
if git fetch origin "$DEFAULT_BRANCH" --quiet 2>/dev/null; then
  HEAD_BEFORE=$(git rev-parse HEAD)
  MERGE_BASE=$(git merge-base HEAD "origin/$DEFAULT_BRANCH" 2>/dev/null || true)
  REMOTE_TIP=$(git rev-parse "origin/$DEFAULT_BRANCH" 2>/dev/null || true)

  if [[ -z "$REMOTE_TIP" ]]; then
    echo "⚠️  Could not resolve origin/$DEFAULT_BRANCH, skipping rebase" >&2
  elif [[ -n "$MERGE_BASE" && "$MERGE_BASE" != "$REMOTE_TIP" ]]; then
    # Guard against rebasing with a dirty working tree — git rebase
    # would fail with a "could not apply" error that reads like a
    # real merge conflict, masking the actual cause. Bail with a
    # clearer message so the user can stash/commit first.
    if ! git diff --quiet || ! git diff --cached --quiet; then
      echo "❌ Uncommitted changes — cannot rebase onto origin/$DEFAULT_BRANCH." >&2
      echo "   Stash or commit them, then retry:" >&2
      git status --short >&2
      exit 2
    fi
    echo "🔄 Rebasing onto origin/$DEFAULT_BRANCH..." >&2
    if git rebase --quiet "origin/$DEFAULT_BRANCH" >&2; then
      HEAD_AFTER=$(git rev-parse HEAD)
      if [[ "$HEAD_BEFORE" != "$HEAD_AFTER" ]]; then
        REBASE_HAPPENED=true
        echo "✅ Rebased successfully onto origin/$DEFAULT_BRANCH" >&2
      fi
    else
      git rebase --abort 2>/dev/null || true
      echo "❌ Rebase failed due to conflicts. Resolve manually before pushing." >&2
      exit 2
    fi
  fi
else
  echo "⚠️  Could not fetch origin/$DEFAULT_BRANCH (network?), skipping rebase" >&2
fi

# --- Step 2: Commit Count Check ---

COMMIT_COUNT=$(git rev-list --count "origin/$DEFAULT_BRANCH..HEAD" 2>/dev/null || echo "0")

if [[ "$COMMIT_COUNT" -gt 1 ]]; then
  if [[ "${ALLOW_MULTIPLE_COMMITS:-}" != "1" ]] && [[ ! "$COMMAND" == ALLOW_MULTIPLE_COMMITS=1* ]]; then
    echo "" >&2
    echo "📊 Branch '$CURRENT_BRANCH' has $COMMIT_COUNT commits ahead of $DEFAULT_BRANCH:" >&2
    git log --oneline "origin/$DEFAULT_BRANCH..HEAD" >&2
    echo "" >&2
    echo "Consider squashing into a single commit before pushing." >&2
    echo "To proceed with multiple commits: ALLOW_MULTIPLE_COMMITS=1 git push ..." >&2
    exit 2
  fi
fi

# --- Step 3: Handle Rebase Side-Effects ---

if [[ "$REBASE_HAPPENED" == "true" ]]; then
  if [[ "$IS_GIT_PUSH" == "true" ]]; then
    # Inject --force-with-lease if no --force* flag is already present.
    # The word-boundary regex catches --force, --force-with-lease, and
    # --force-if-includes without false-matching unrelated tokens.
    if [[ ! "$COMMAND" =~ (^|[[:space:]])--force ]]; then
      # insert after `push`, including the `git -C <dir> push` form (review finding)
      MODIFIED_COMMAND=$(printf '%s' "$COMMAND" | sed -E "s/(git([[:space:]]+-C[[:space:]]+(\"[^\"]+\"|'[^']+'|[^[:space:]]+))?[[:space:]]+push)([[:space:]]|\$)/\\1 --force-with-lease\\4/")
      echo "🔄 Injecting --force-with-lease (rebase changed history)" >&2
      jq -n --arg cmd "$MODIFIED_COMMAND" '{
        "hookSpecificOutput": {
          "hookEventName": "PreToolUse",
          "updatedInput": {
            "command": $cmd
          }
        }
      }'
      exit 0
    fi
  fi

  if [[ "$IS_GH_PR_CREATE" == "true" ]]; then
    # Pushing from inside the hook would bypass the agent's permission
    # prompt, so block and ask for an explicit push instead.
    echo "🔄 Rebase changed history. Push the branch first, then retry:" >&2
    echo "   git push --force-with-lease origin $CURRENT_BRANCH" >&2
    exit 2
  fi
fi

exit 0
