#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then report done
# according to the project's delivery mode).
# Usage: fm-promote.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh" || exit 1
STATE=$FM_VALIDATED_STATE_PATH
"$FM_ROOT/bin/fm-guard.sh" || true
ID=${1:-}
case "$ID" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "error: unsafe task id: $ID" >&2; exit 2 ;;
esac
META="$STATE/$ID.meta"
fm_validate_task_meta_file "$META" || { echo "error: no safe meta for task $ID at $META" >&2; exit 1; }
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
TMP=
cleanup() {
  [ -z "$TMP" ] || rm -f "$TMP" 2>/dev/null || true
  fm_lock_release "$META_LOCK"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
fm_validate_task_meta_file "$META" || exit 1
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

TMP=$(mktemp "$STATE/.fm-promote.XXXXXX") || exit 1
grep -v '^kind=' "$META" > "$TMP"
echo "kind=ship" >> "$TMP"
fm_publish_file_no_follow "$TMP" "$META" replace || exit 1
TMP=

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship (teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
