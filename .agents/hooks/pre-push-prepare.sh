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
# The resolver below is ported from sidekick-labs/sidekick-harness
# (.claude/hooks/lib/resolve-push-root.sh, ai-foundations-brain#745), inlined because
# estate hooks are vendored as single files. Its tests live in
# hooks/tests/pre-push-prepare.test.sh.

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

# _extract_dir_arg <text> <flag-regex>
# Prints the argument following the first <flag-regex> match in <text>,
# handling double-quoted, single-quoted, and bare values. Each quoting
# style is tried with an independent match, so one style can't clobber
# another's pattern space. <flag-regex> must not contain capture groups —
# the directory is read from BASH_REMATCH[1].
#
# The patterns below are ordinary regexes; only their delimiters are dense.
# Written out, they are:  <flag> <space> "..."  |  <flag> <space> '...'  |
# <flag> <space> <run of chars that aren't space/;/&/|>. The single-quote
# arm looks like line noise because a literal ' inside a '-quoted bash
# string must be spelled '\'' — so [^']+ becomes [^'\'']+.
_extract_dir_arg() {
  local text="$1" flag="$2"
  if [[ "$text" =~ ${flag}[[:space:]]+\"([^\"]+)\" ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "$text" =~ ${flag}[[:space:]]+\'([^\']+)\' ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "$text" =~ ${flag}[[:space:]]+([^[:space:]\;\&\|]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# _try_toplevel <base> <dir>
# Resolves <dir> (relative paths against <base>, `~` expanded) and prints
# the git toplevel it lands in. Returns non-zero if it isn't a resolvable
# git checkout — callers fall through to the next candidate.
_try_toplevel() {
  local base="$1" dir="$2" toplevel
  dir="${dir/#\~\//$HOME/}"
  [[ "$dir" == "~" ]] && dir="$HOME"
  # `cd` writes the target to stdout for some arguments (notably `-`), which
  # would otherwise be captured alongside the toplevel — send it to /dev/null.
  toplevel=$(cd "$base" >/dev/null 2>&1 && cd "$dir" >/dev/null 2>&1 \
    && git rev-parse --show-toplevel 2>/dev/null) || return 1
  [[ -n "$toplevel" ]] || return 1
  printf '%s' "$toplevel"
}

# resolve_push_root <command> <hook-input-json>
#
# Prints the absolute toplevel of the checkout the push targets.
# The command is split into segments on `&&`, `;`, `|`, and newlines, and
# only the segment that IS the push (git … push / gh pr create) plus the
# segments before it are consulted — a `git -C` on some other invocation,
# or a `cd` that runs after the push, never selects the root.
#
# Candidate order (first one that resolves to a git checkout wins):
#   1. the push segment's own `git -C <dir>`
#   2. the last `cd <dir>` in a segment before the push
#   3. the session cwd from the hook's stdin JSON (`.cwd`, with the
#      nested `.context.cwd` shape as fallback), else the hook's $PWD
# Relative paths in 1–2 resolve against 3, not the hook process's cwd.
# Returns non-zero only if no candidate is inside a git checkout.
resolve_push_root() {
  local command="$1" input="$2"
  local session_cwd base seg dir last_cd="" push_seg="" toplevel

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

  # Split into segments. Separators inside quoted arguments split too, but
  # the resulting fragments simply fail the cd/push matches below.
  local normalized="${command//&&/$'\n'}"
  normalized="${normalized//;/$'\n'}"
  normalized="${normalized//|/$'\n'}"

  while IFS= read -r seg; do
    if _seg_is_push "$seg"; then
      push_seg="$seg"
      break
    fi
    if [[ "$seg" =~ ^[[:space:]]*cd[[:space:]] ]]; then
      dir=$(_extract_dir_arg "$seg" '^[[:space:]]*cd')
      # `cd -` means OLDPWD *of the interactive shell*, which this process
      # cannot know. Resolving it here would land on the hook's own cwd —
      # the main checkout — silently reinstating the afb#745 bug. Ignore it
      # and let resolution fall through to the session cwd.
      [[ -n "$dir" && "$dir" != "-" ]] && last_cd="$dir"
    fi
  done <<<"$normalized"

  if [[ -n "$push_seg" ]]; then
    dir=$(_extract_dir_arg "$push_seg" '-C')
    # a relative -C is relative to wherever the preceding `cd` left the shell
    local cbase="$base"
    if [[ -n "$last_cd" && "$dir" != /* ]]; then
      local d="${last_cd/#\~\//$HOME/}"
      cbase=$(cd "$base" >/dev/null 2>&1 && cd "$d" >/dev/null 2>&1 && pwd) || cbase="$base"
    fi
    if [[ -n "$dir" ]] && toplevel=$(_try_toplevel "$cbase" "$dir"); then
      printf '%s' "$toplevel"
      return 0
    fi
  fi

  if [[ -n "$last_cd" ]] && toplevel=$(_try_toplevel "$base" "$last_cd"); then
    printf '%s' "$toplevel"
    return 0
  fi

  toplevel=$(_try_toplevel "$base" ".") || return 1
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
