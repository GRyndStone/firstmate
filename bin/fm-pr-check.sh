#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and GitHub's pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR is merged (the watcher's
# check contract: output = wake firstmate, silence = keep sleeping).
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh" || exit 1
STATE=$FM_VALIDATED_STATE_PATH
ID=$1
URL=$2
case "$ID" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "error: unsafe task id: $ID" >&2; exit 2 ;;
esac
META="$STATE/$ID.meta"
if [ -e "$META" ] || [ -L "$META" ]; then
  fm_validate_task_meta_file "$META" || exit 1
fi
"$FM_ROOT/bin/fm-guard.sh" || true
if [ -e "$META" ] || [ -L "$META" ]; then
  fm_validate_task_meta_file "$META" || exit 1
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_HEAD=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    if command -v gh >/dev/null 2>&1; then
      if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
        PR_HEAD=$REMOTE_HEAD
      fi
    fi
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    printf 'pr=%s\n' "$URL" | fm_append_file_no_follow "$META" || exit 1
  fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    printf 'pr_head=%s\n' "$PR_HEAD" | fm_append_file_no_follow "$META" || exit 1
  fi
fi

fm_write_file_no_follow "$STATE/$ID.check.sh" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
echo "armed: state/$ID.check.sh polls $URL"
