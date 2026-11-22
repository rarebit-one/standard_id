#!/bin/bash
# Pre-push prepare hook for Claude Code
#
# Runs on PreToolUse event for Bash commands containing "git push" or "gh pr create"
# Keeps feature branches up-to-date and encourages single-commit PRs.
#
# What it does:
#   1. Fetches latest target branch and rebases current branch onto it, in a
#      throwaway worktree: the checkout being pushed is never mid-rebase or
#      detached, whatever fails and even if the hook is killed
#   2. Checks commit count on the rebased result and blocks if >1 commit
#      (prompts user to squash)
#   3. If rebase changes history, moves the branch to the rebased commit and
#      injects --force-with-lease into git push. A blocked push never moves
#      the branch.
#   4. For `gh pr create`, when the branch needs a rebase: blocks and asks
#      for an explicit `git push --force-with-lease` first, so the push
#      goes through the agent's permission system.
#   It never rebases a branch that contains merge commits (it blocks), and
#   blocks a push from a checkout with a rebase/merge/cherry-pick in progress.
#
# Exit codes:
#   0 - Allow (optionally with modified command)
#   2 - Block (rebase conflict or failure, dirty working tree, merge commits,
#       an operation in progress, or multiple commits); the checkout is left
#       exactly as it was
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
# The resolver below started as a port of sidekick-labs/sidekick-harness's
# .claude/hooks/lib/resolve-push-root.sh (ai-foundations-brain#745; that lib was
# deleted in sidekick-harness#1434, so this file is now the canonical resolver), inlined because
# estate hooks are vendored as single files; since agent-estate#20 it lexes the
# command instead of splitting its text. Its tests live in
# hooks/tests/resolve-push-root.test.sh and hooks/tests/pre-push-prepare.test.sh.

# Matches `git push` and `git -C <dir> push`. The -C form must be gated by
# both hooks — it is the documented way to push a worktree from elsewhere,
# and when it went unmatched the "use git -C" error message was advice to
# bypass the gate. Defined here so the two hooks cannot drift apart.
# shellcheck disable=SC2034  # consumed by the sourcing hooks
GIT_PUSH_RE='(^|[[:space:]&;|])git[[:space:]]+(-C[[:space:]]+("[^"]+"|'\''[^'\'']+'\''|[^[:space:]]+)[[:space:]]+)?push([[:space:]]|$)'

# GIT_PUSH_CMD_RE: a segment (its x-masked text) whose COMMAND is the push:
# optional prefixes (`!`, if/then/…, assignments, redirections, and
# command/exec/time/nice/env with their options and operands; NOT `env -C/--chdir`
# or `-S/--split-string`, which move or re-parse the command, so such a push is
# not recognised and the hook skips it), then `git`, an
# optional `-C <dir>`, then `push` as the subcommand, in one anchored match. The
# resolver (_seg_is_push) and the lease (_rpr_lease_command) both select the
# push with it, so they can never pick different segments (Codex on #34:
# `echo git push; cd ../b && git push`).
GIT_PUSH_CMD_RE='^[[:space:]]*((!|if|then|else|elif|while|until|do|\{|[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?[+]?=[^[:space:]]*|[0-9]*[\<\>\&][\<\>\&]*([[:space:]]*[^[:space:]\<\>\&]+)?|(command|time)([[:space:]]+-[^[:space:]]*)*|env([[:space:]]+(-u|--unset)[[:space:]]+[^[:space:]]+|[[:space:]]+-[^[:space:]CSu-]*u[^[:space:]]+|[[:space:]]+--?|[[:space:]]+-[^[:space:]CSu-][^[:space:]CSu]*|[[:space:]]+--(ignore-environment|null|unset=[^[:space:]]+))*|nice([[:space:]]+(-n|--adjustment)[[:space:]]+[^[:space:]]+|[[:space:]]+-[^[:space:]]*)*|exec([[:space:]]+-a[[:space:]]+[^[:space:]]+|[[:space:]]+-[^[:space:]]*)*)[[:space:]]+)*git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?push([[:space:]]|$)'

# _seg_is_push <segment>
# True when a single command segment (no shell separators) is the push:
# a `git … push` invocation or a `gh pr create`.
_seg_is_push() {
  # the push itself: `git [-C <dir>] push`, adjacent. Any segment that merely
  # CONTAINS both words (`git commit -m "fix push"`) used to match, and a cd before
  # it then selected the wrong checkout (review finding on the estate rollout).
  # Command position only (GIT_PUSH_CMD_RE): `echo git push` mentions it.
  if [[ "$1" =~ $GIT_PUSH_CMD_RE ]]; then
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
# RPR_OFF[i] is the offset in <command> where segment i starts; RPR_CONT lists
# the offsets of the line continuations (`\<newline>`) dropped from the raw text,
# so a mask offset maps back onto <command> (_rpr_lease_command).
# RPR_BAD=1 on an unterminated quote or substitution; RPR_LEAD=1 when the line
# opens with a subshell/`;;` (a separator with no segment before it).
_rpr_lex() {
  local LC_ALL=C
  local s="$1" n i=0 ch nx ctx="" top raw="" mask="" d q line rest re run st=0 pend=0 bs
  local -a hd=()
  RPR_SEG=(); RPR_MASK=(); RPR_SEP=(); RPR_OFF=(); RPR_CONT=(); RPR_BAD=0; RPR_LEAD=0
  n=${#s}
  while (( i < n )); do
    (( pend )) && { st=$i; pend=0; }   # a segment starts after the separator
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
        '"$')
          # ${ … } nests like $( … ): its own quotes do not close the "…"
          # (`"${x:-"; cd ../b;"}"` is one word; agent-estate#23)
          if [[ "$nx" == "(" ]]; then ctx+="("; raw+='$('; mask+="xx"; i=$((i + 2)); continue; fi
          if [[ "$nx" == "{" ]]; then ctx+="b"; raw+='${'; mask+="xx"; i=$((i + 2)); continue; fi ;;
      esac
      raw+="$ch"; mask+="x"; i=$((i + 1)); continue
    fi
    # top level, $( … ) or ${ … }: quotes, escapes, substitutions, heredocs
    case "$ch" in
      '\')
        if [[ "$nx" == $'\n' ]]; then RPR_CONT+=("$i"); i=$((i + 2)); continue; fi   # continuation
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
        '#')
          # a comment runs to the end of the line, so a `)` in it closes
          # nothing (`$(: # )` …); `$#` is not one (agent-estate#23)
          # A space escaped by an odd run of backslashes (`\ #`) is part of
          # the word, so that # is not a comment either.
          bs=0; while [[ "${raw: -$((bs + 2)):1}" == '\' ]] && (( bs + 2 <= ${#raw} )); do bs=$((bs + 1)); done
          if [[ "${raw: -1}" == [[:space:]\(\;\&\|] ]] && ! { [[ "${raw: -1}" == [[:space:]] ]] && (( bs % 2 )); }; then
            rest="${s:i}"; line="${rest%%$'\n'*}"
            raw+="$line"; printf -v run '%*s' "${#line}" ''; mask+="${run// /x}"
            i=$((i + ${#line})); continue
          fi ;;
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
    raw=""; mask=""; pend=1
    return
  fi
  RPR_SEG+=("$raw"); RPR_MASK+=("$mask"); RPR_SEP+=("$1"); RPR_OFF+=("$st")
  raw=""; mask=""; pend=1
}

# _rpr_word <raw-text> <offset>
# Reads the shell word at <offset> and sets RPR_W to the path it names, with a
# leading `~`/`~/` expanded. RPR_WOK=0 when the value is only known at run time
# ($VAR, $(…), `…`, a glob * ? [ ], a brace {a,b}, ~user/~+/~-, or an option
# such as `-P`/`--`): those cannot be followed here, so the target is unknown.
# RPR_WOK=2 when there is no word at all (a bare `cd`). RPR_WHOME=1 when a
# leading `~` was replaced with the hook's own $HOME (see _rpr_home_moved).
_rpr_word() {
  local LC_ALL=C
  local s="$1" i="$2" n ch w="" started=0
  n=${#s}
  RPR_WOK=1; RPR_WHOME=0
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
            ''|' '|$'\t'|'/') w+="$HOME"; RPR_WHOME=1 ;;
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

# _rpr_home_moved <last-segment-index>: 0 when a segment up to and including it
# may change HOME (an assignment, `unset HOME`, `export "HOME=…"`, `read HOME` …).
# The hook's own $HOME then no longer says where a bare `cd` or a `~` goes
# (agent-estate#23). Checked on the raw text, so a quoted assignment counts;
# reading it as $HOME / ${HOME} does not. Any other mention errs towards unknown.
_rpr_home_moved() {
  local k re='(^|[^A-Za-z0-9_${])HOME([+]?=|[[:space:]"'\'';&|)]|$)'
  for (( k = 0; k <= $1; k++ )); do
    [[ "${RPR_SEG[k]}" =~ $re ]] && return 0
  done
  return 1
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
  elif [[ "$m" =~ (^|[[:space:]])(eval|source)([[:space:]]|$) ]]; then RPR_KIND=cdish
  # `.` only in command position (after assignments, redirections such as
  # `2>/dev/null` / `> log`, a keyword such as `if`, or a prefix such as
  # `command -p` / `time -p`): in `git add .` /
  # `docker build .` it is an argument (agent-estate#23)
  elif [[ "$m" =~ ^[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?[+]?=[^[:space:]]*|[0-9]*[\<\>\&][\<\>\&]*([[:space:]]*[^[:space:]\<\>\&]+)?|if|then|else|elif|while|until|do|!|\{|(time|command|builtin|exec)([[:space:]]+-[^[:space:]]*)*)[[:space:]]+)*\.([[:space:]]|$) ]]; then RPR_KIND=cdish
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
  if [[ "$RPR_WOK" == 2 ]]; then RPR_W="$HOME"; RPR_WOK=1; RPR_WHOME=1; fi   # bare `cd`
  [[ "$RPR_WHOME" == 1 ]] && _rpr_home_moved "$k" && RPR_WOK=0   # HOME was changed
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
    [[ "$RPR_WHOME" == 1 ]] && _rpr_home_moved "$p" && return 1   # `-C ~` after a HOME change
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

# _rpr_lease_command <command>
# Prints <command> with ` --force-with-lease` inserted after the `push` of its
# first segment whose MASK is a `git push` (the one resolve_push_root acts on,
# unless a `gh pr create` precedes it). Never the first textual `git push`: an
# echoed string or a commit message got it, and the real push went out without
# one and was rejected (agent-estate#23). Non-zero when there is no push to edit.
_rpr_lease_command() {
  # Byte offsets, like _rpr_lex: under a UTF-8 locale ${s:0:j} would count
  # characters, and a multibyte earlier segment would shift the insertion.
  local LC_ALL=C
  local s="$1" k p=-1 m off j c
  _rpr_lex "$s"
  [[ "$RPR_BAD" == 1 ]] && return 1
  # The push must be the segment's COMMAND, and `push` that git's subcommand, in
  # ONE anchored match: `echo git push; git push` and `git add git push; git push`
  # both mention the words before the real push (Codex on the rollout and #34).
  # Prefixes: assignments, redirections (`2>/tmp/err`, `> log`), and
  # command/exec/time/nice/env with their -options, including the ones that take
  # the next word as a value (`env -u NAME`, `nice -n 10`, `exec -a NAME`),
  # and Bash's `!` negation.
  # Quoted text is already x-masked, so a quoted `-C "<dir>"` is one word here.
  for (( k = 0; k < ${#RPR_SEG[@]}; k++ )); do
    if [[ "${RPR_MASK[k]}" =~ $GIT_PUSH_CMD_RE ]]; then p=$k; break; fi
  done
  (( p >= 0 )) || return 1
  m="${BASH_REMATCH[0]}"
  # anchored at the segment start, so the offset is the match minus its trailing space
  off=${#m}; [[ "$m" == *[[:space:]] ]] && off=$((off - 1))   # just past `push`
  # the mask lacks the continuations (`\<newline>`) inside the segment
  j=$(( RPR_OFF[p] + off ))
  for c in "${RPR_CONT[@]}"; do
    (( c >= RPR_OFF[p] && c < j )) && j=$((j + 2))
  done
  printf '%s' "${s:0:j} --force-with-lease${s:j}"
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

# --- Refuse a checkout that is mid-operation -----------------------------------
# A rebase, merge, cherry-pick or revert left in progress (before this hook
# rebased off to the side, an interrupted run of the hook itself left exactly
# that) is a person's to finish or undo: the hook never continues or aborts work
# it did not start. Checked before the detached-HEAD skip below, because a
# stopped rebase IS a detached HEAD, and pushing from it pushes whatever it holds.
GIT_DIR_ABS=$(git rev-parse --absolute-git-dir)
OP_IN_PROGRESS=""
if [[ -d "$GIT_DIR_ABS/rebase-merge" || -d "$GIT_DIR_ABS/rebase-apply" ]]; then
  OP_IN_PROGRESS=rebase
elif [[ -f "$GIT_DIR_ABS/MERGE_HEAD" ]]; then
  OP_IN_PROGRESS=merge
elif [[ -f "$GIT_DIR_ABS/CHERRY_PICK_HEAD" ]]; then
  OP_IN_PROGRESS=cherry-pick
elif [[ -f "$GIT_DIR_ABS/REVERT_HEAD" ]]; then
  OP_IN_PROGRESS=revert
fi
if [[ -n "$OP_IN_PROGRESS" ]]; then
  echo "❌ A $OP_IN_PROGRESS is in progress in $ROOT; not pushing from it." >&2
  echo "   Finish it (git $OP_IN_PROGRESS --continue) or undo it (git $OP_IN_PROGRESS --abort)," >&2
  echo "   check \`git status\` shows your branch, then retry." >&2
  exit 2
fi

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

# --- Rebasing without ever leaving the checkout mid-rebase ---------------------
# The rebase runs in a throwaway detached worktree (SCRATCH), never in the
# checkout being pushed. The branch moves only at the very end, with one
# `git reset --keep`, and only when the hook is about to allow the push. So:
#   * a conflict, a signing failure or any other rebase error leaves the
#     developer's checkout exactly as it was (same branch, same HEAD);
#   * every blocking check (commit count, lease placement) runs on the rebased
#     result BEFORE the branch moves, so a blocked push changes nothing. (In
#     place, a push blocked by the commit count had already rewritten the
#     branch; the next push then saw nothing to rebase, got no lease, and was
#     rejected: fundbright-web, 2026-11-22.)
#   * when the harness kills the hook at its timeout, only the scratch worktree
#     is lost, and a later run sweeps it. (In place, a slow post-checkout /
#     post-rewrite hook, lefthook's devcontainer bundle-sync, ran inside the
#     rebase, and the kill left the checkout detached in .git/rebase-merge:
#     luminality-web, 2026-11-22.)
# The scratch rebase runs with core.hooksPath=/dev/null: post-checkout and
# post-rewrite hooks exist to sync the developer's checkout, and running them in
# a directory about to be deleted only burns the timeout. Commit signing is
# config, not a hook, so rebased commits are signed exactly as before; the
# checkout's identity and signing settings are passed to the scratch rebase
# explicitly (CARRY_CONFIG), because an `includeIf "onbranch:…"` that sets them
# does not match a detached worktree (Codex on #75).
HEAD_BEFORE=$(git rev-parse HEAD)
REBASED=""            # rebased tip, built in SCRATCH; applied by apply_rebase
REBASE_HAPPENED=false
SCRATCH=""
CHILD=""              # the scratch git command in flight (see run_child)
# physical path, no trailing slash: `git worktree list` prints it that way
# (macOS: TMPDIR ends in `/`, and /var is /private/var), and the sweep matches it
SCRATCH_BASE=$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P) || SCRATCH_BASE=/tmp
SCRATCH_PREFIX="$SCRATCH_BASE/pre-push-prepare."
NO_HOOKS=(-c core.hooksPath=/dev/null -c rebase.updateRefs=false)

cleanup_scratch() {
  if [[ -n "$CHILD" ]]; then
    kill "$CHILD" 2>/dev/null || true
    wait "$CHILD" 2>/dev/null || true
    CHILD=""
  fi
  [[ -n "$SCRATCH" && "$SCRATCH" == "$SCRATCH_PREFIX"* && -d "$SCRATCH" ]] || return 0
  git -C "$SCRATCH/wt" rebase --abort >/dev/null 2>&1 || true
  git "${NO_HOOKS[@]}" -C "$ROOT" worktree remove --force "$SCRATCH/wt" >/dev/null 2>&1 || true
  rm -rf -- "$SCRATCH"
  SCRATCH=""
}

# Scratch worktrees a SIGKILLed run left behind (an hour old: a live run of a
# parallel session takes seconds). Only paths this hook itself creates.
sweep_stale_scratch() {
  local path dir
  while IFS= read -r path; do
    [[ "$path" == worktree\ * ]] || continue
    path="${path#worktree }"
    [[ "$path" == "$SCRATCH_PREFIX"*/wt ]] || continue
    dir="${path%/wt}"
    if [[ ! -d "$dir" ]] || [[ -n "$(find "$dir" -maxdepth 0 -mmin +60 2>/dev/null)" ]]; then
      git "${NO_HOOKS[@]}" -C "$ROOT" worktree remove --force "$path" >/dev/null 2>&1 || true
      [[ -d "$dir" ]] && rm -rf -- "$dir"
    fi
  done < <(git -C "$ROOT" worktree list --porcelain 2>/dev/null)
}

# run_child <log> <command…>: run a scratch git command in the background and wait
# for it. Bash defers a trapped signal until a FOREGROUND child exits, so a
# rebase stuck on a slow signer would keep the hook alive past the harness's
# SIGTERM; `wait` returns as soon as the signal arrives, and the trap's exit
# runs cleanup_scratch, which stops the child.
run_child() {
  local log="$1" rc=0
  shift
  "$@" >"$log" 2>&1 &
  CHILD=$!
  wait "$CHILD" || rc=$?
  CHILD=""
  return "$rc"
}

# carried_config: fill CARRY_CONFIG with `-c key=value` for each identity and
# signing setting as the checkout being pushed sees it (on its branch).
CARRY_CONFIG=()
carried_config() {
  local key val
  for key in user.name user.email user.signingkey gpg.format gpg.program \
             gpg.openpgp.program gpg.x509.program gpg.ssh.program gpg.ssh.defaultKeyCommand; do
    if val=$(git config --get "$key" 2>/dev/null); then
      CARRY_CONFIG+=(-c "$key=$val")
    fi
  done
  if val=$(git config --type=bool --get commit.gpgsign 2>/dev/null); then
    CARRY_CONFIG+=(-c "commit.gpgsign=$val")
  fi
  return 0
}

# rebase_aside <onto>: rebase HEAD_BEFORE onto <onto> in SCRATCH and set REBASED.
# Non-zero (with the reason on stderr) when the rebase cannot complete; the
# checkout being pushed is never touched either way.
rebase_aside() {
  local onto="$1" wt log conflicts
  sweep_stale_scratch
  SCRATCH=$(mktemp -d "${SCRATCH_PREFIX}XXXXXX") || {
    echo "❌ Could not create a scratch directory to rebase in; nothing changed." >&2
    return 1
  }
  wt="$SCRATCH/wt"; log="$SCRATCH/rebase.log"
  if ! run_child "$log" git "${NO_HOOKS[@]}" worktree add --quiet --detach "$wt" "$HEAD_BEFORE"; then
    echo "❌ Could not create a scratch worktree to rebase in; nothing changed:" >&2
    sed 's/^/   /' "$log" >&2
    return 1
  fi
  carried_config
  if run_child "$log" git "${NO_HOOKS[@]}" ${CARRY_CONFIG[@]+"${CARRY_CONFIG[@]}"} -C "$wt" rebase --quiet "$onto"; then
    REBASED=$(git -C "$wt" rev-parse HEAD)
    return 0
  fi
  conflicts=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null || true)
  if [[ -n "$conflicts" ]]; then
    echo "❌ Rebasing '$CURRENT_BRANCH' onto $onto conflicts in:" >&2
    printf '%s\n' "$conflicts" | sed 's/^/     /' >&2
    echo "   Your checkout was not touched. Rebase it yourself, resolve, then retry:" >&2
    echo "     git rebase $onto" >&2
  else
    echo "❌ Rebasing '$CURRENT_BRANCH' onto $onto failed; your checkout was not touched:" >&2
    tail -n 15 "$log" | sed 's/^/   /' >&2
  fi
  return 1
}

# restore_original: put the branch and the working tree back where they were.
restore_original() {
  if [[ "$(git symbolic-ref -q HEAD 2>/dev/null || true)" != "refs/heads/$CURRENT_BRANCH" ]]; then
    git checkout --quiet "$CURRENT_BRANCH" 2>/dev/null || true
  fi
  if [[ "$(git rev-parse HEAD 2>/dev/null || true)" != "$HEAD_BEFORE" ]]; then
    git reset --quiet --keep "$HEAD_BEFORE" 2>/dev/null || true
  fi
  if [[ "$(git symbolic-ref -q HEAD 2>/dev/null || true)" != "refs/heads/$CURRENT_BRANCH" \
        || "$(git rev-parse HEAD 2>/dev/null || true)" != "$HEAD_BEFORE" ]]; then
    echo "   Could not restore it automatically. To get back:" >&2
    echo "     git checkout $CURRENT_BRANCH && git reset --keep $HEAD_BEFORE" >&2
  fi
}

# apply_rebase: move the checkout's branch to REBASED. Called only on a path
# that then exits 0. `git reset --keep` keeps the branch checked out (it never
# detaches) and refuses up front, changing nothing, when a file it would replace
# has local changes or is untracked. Interrupts are ignored for these few
# milliseconds so the move is not cut in half.
apply_rebase() {
  local err
  trap '' INT TERM HUP
  if [[ "$(git rev-parse HEAD)" != "$HEAD_BEFORE" \
        || "$(git symbolic-ref -q HEAD || true)" != "refs/heads/$CURRENT_BRANCH" ]]; then
    echo "❌ '$CURRENT_BRANCH' moved while the hook was rebasing it; nothing changed. Retry the push." >&2
    exit 2
  fi
  if ! err=$(GIT_REFLOG_ACTION="pre-push-prepare: rebase onto origin/$DEFAULT_BRANCH" \
             git reset --quiet --keep "$REBASED" 2>&1); then
    echo "❌ Could not move '$CURRENT_BRANCH' to its rebased commit:" >&2
    printf '%s\n' "$err" | sed 's/^/   /' >&2
    restore_original
    echo "   Your checkout is unchanged. Clear what git names above, or rebase yourself, then retry." >&2
    exit 2
  fi
  if [[ "$(git rev-parse HEAD)" != "$REBASED" \
        || "$(git symbolic-ref -q HEAD || true)" != "refs/heads/$CURRENT_BRANCH" ]]; then
    echo "❌ '$CURRENT_BRANCH' did not land on its rebased commit; restoring it." >&2
    restore_original
    exit 2
  fi
  trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
  echo "✅ Rebased '$CURRENT_BRANCH' onto origin/$DEFAULT_BRANCH (was $HEAD_BEFORE; undo: git reset --keep $HEAD_BEFORE)" >&2
  # the scratch rebase skipped the repo's post-checkout / post-rewrite hooks,
  # and `reset` runs none: say how to run them where they belong
  local path
  path=$(git rev-parse --git-path hooks/post-checkout 2>/dev/null || true)
  if [[ -n "$path" && -x "$path" ]]; then
    echo "ℹ️  The repo's post-checkout git hook did not run for this update. If it syncs dependencies:" >&2
    echo "     git hook run post-checkout -- $HEAD_BEFORE $REBASED 1" >&2
    return 0
  fi
  path=$(git rev-parse --git-path hooks/post-rewrite 2>/dev/null || true)
  if [[ -n "$path" && -x "$path" ]]; then
    echo "ℹ️  The repo's post-rewrite git hook did not run for this update. If it syncs dependencies:" >&2
    echo "     echo '$HEAD_BEFORE $REBASED' | git hook run --to-stdin=/dev/stdin post-rewrite -- rebase" >&2
  fi
  return 0
}

# a signal now still runs the EXIT trap, so the scratch worktree is cleaned up
trap cleanup_scratch EXIT
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP

# --- Step 1: Fetch and Rebase (off to the side) ---

echo "🔄 Fetching latest $DEFAULT_BRANCH..." >&2
if git fetch origin "$DEFAULT_BRANCH" --quiet 2>/dev/null; then
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
    # A branch that merged the default branch in chose merging over rebasing.
    # Rebasing it would silently flatten those merges into rewritten history
    # (and need a force push); that is the developer's call, not this hook's.
    if [[ -n "$(git rev-list --merges "$MERGE_BASE..HEAD" 2>/dev/null)" ]]; then
      echo "❌ '$CURRENT_BRANCH' is behind origin/$DEFAULT_BRANCH and contains merge commits." >&2
      echo "   The hook will not flatten them into a rebase. Update it yourself, then retry:" >&2
      echo "     git merge origin/$DEFAULT_BRANCH     # keep merging" >&2
      echo "     git rebase origin/$DEFAULT_BRANCH    # or rewrite as a linear branch" >&2
      exit 2
    fi
    echo "🔄 Rebasing onto origin/$DEFAULT_BRANCH (in a scratch worktree)..." >&2
    rebase_aside "origin/$DEFAULT_BRANCH" || exit 2
    if [[ "$REBASED" != "$HEAD_BEFORE" ]]; then
      REBASE_HAPPENED=true
    fi
  fi
else
  echo "⚠️  Could not fetch origin/$DEFAULT_BRANCH (network?), skipping rebase" >&2
fi

# --- Step 2: Commit Count Check (on the rebased result) ---

TIP="${REBASED:-$HEAD_BEFORE}"
COMMIT_COUNT=$(git rev-list --count "origin/$DEFAULT_BRANCH..$TIP" 2>/dev/null || echo "0")

if [[ "$COMMIT_COUNT" -gt 1 ]]; then
  if [[ "${ALLOW_MULTIPLE_COMMITS:-}" != "1" ]] && [[ ! "$COMMAND" == ALLOW_MULTIPLE_COMMITS=1* ]]; then
    echo "" >&2
    echo "📊 Branch '$CURRENT_BRANCH' has $COMMIT_COUNT commits ahead of $DEFAULT_BRANCH:" >&2
    git log --oneline "origin/$DEFAULT_BRANCH..$TIP" >&2
    echo "" >&2
    echo "Consider squashing into a single commit before pushing." >&2
    echo "To proceed with multiple commits: ALLOW_MULTIPLE_COMMITS=1 git push ..." >&2
    [[ "$REBASE_HAPPENED" == "true" ]] && echo "(The branch was not rebased; the hook rebases it on the next push.)" >&2
    exit 2
  fi
fi

# --- Step 3: Apply the rebase and handle its side effects ---
# Every block happens before apply_rebase, so a blocked push leaves the branch
# where it was.

if [[ "$REBASE_HAPPENED" == "true" ]]; then
  if [[ "$IS_GIT_PUSH" == "true" ]]; then
    # Inject --force-with-lease if no --force* flag is already present.
    # The word-boundary regex catches --force, --force-with-lease, and
    # --force-if-includes without false-matching unrelated tokens.
    if [[ ! "$COMMAND" =~ (^|[[:space:]])--force ]]; then
      # insert after the `push` of the push segment the resolver acted on,
      # including the `git -C <dir> push` form (review findings; agent-estate#23)
      if ! MODIFIED_COMMAND=$(_rpr_lease_command "$COMMAND"); then
        echo "❌ '$CURRENT_BRANCH' needs a rebase onto origin/$DEFAULT_BRANCH, but --force-with-lease could not be placed in this command." >&2
        echo "   Nothing changed. Push with it explicitly (the hook rebases first): git push --force-with-lease origin $CURRENT_BRANCH" >&2
        exit 2
      fi
      apply_rebase
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
    apply_rebase
    exit 0
  fi

  if [[ "$IS_GH_PR_CREATE" == "true" ]]; then
    # Pushing from inside the hook would bypass the agent's permission
    # prompt, so block and ask for an explicit push instead. The push's own
    # run of this hook rebases the branch; this one leaves it untouched.
    echo "🔄 '$CURRENT_BRANCH' is behind origin/$DEFAULT_BRANCH. Push it first (the hook rebases it), then retry:" >&2
    echo "   git push --force-with-lease origin $CURRENT_BRANCH" >&2
    exit 2
  fi
fi

exit 0
