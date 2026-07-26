#!/usr/bin/env bash
# Perform the approved local merge for a local-first or local-only ship task:
# fast-forward the project's checked-out default branch to the crewmate's
# fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-first or mode=local-only tasks, only after the captain
# approves (or yolo=on auto-approves), and only as a clean fast-forward.
# It refuses a diverged branch and tells you to have the crewmate rebase.
#
# local-first ordering is deliberate and fail-visible:
#   1. Fast-forward the checked-out local product first.
#   2. Push that local default branch to origin as its backup.
# A backup rejection never rolls the local product back. The command exits
# non-zero with a loud BACKUP FAILED message that says the local merge already
# happened and can be retried safely; a later retry re-runs the no-op
# fast-forward, then retries the backup. It never fetches or merges remote work
# down into the local product.
# local-only stops after the local fast-forward because it has no remote.
# See AGENTS.md prime directives, project management, and task lifecycle.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=${1:?usage: fm-merge-local.sh <task-id>}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
case "$MODE" in
  local-first|local-only) ;;
  *) echo "error: task $ID is mode=$MODE, not local-first or local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1 ;;
esac

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"

if [ "$MODE" = local-first ]; then
  backup_out=
  if ! backup_out=$(git -C "$PROJ" push origin "refs/heads/$DEFAULT:refs/heads/$DEFAULT" 2>&1); then
    echo "BACKUP FAILED: local $DEFAULT already carries $after in $PROJ, but origin/$DEFAULT was not updated." >&2
    [ -z "$backup_out" ] || printf '%s\n' "$backup_out" >&2
    echo "Fix the origin push failure and rerun bin/fm-merge-local.sh $ID; do not sync remote changes down." >&2
    exit 1
  fi
  echo "backup pushed: local $DEFAULT $after -> origin/$DEFAULT"
fi
