#!/usr/bin/env bash
# Start the durable normal-mode local supervisor for one FM_HOME.
#
# Usage: fm-supervisor-start.sh
#   - exits 0 when state/.supervise-daemon.lock already names a live,
#     identity-matched daemon;
#   - reclaims a stale/dead/identity-mismatched daemon lock;
#   - otherwise execs bin/fm-supervise-daemon.sh in normal mode.
#
# Run this command as its own harness-tracked background task, never with shell
# `&` or nohup. The daemon remains a foreground process inside that tracked
# task, while its identity-bound lock proves durable ownership to the turn-end
# guard. Normal start refuses while state/.afk exists; away mode stays owned by
# bin/fm-afk-start.sh.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.supervise-daemon.lock"
DAEMON="$SCRIPT_DIR/fm-supervise-daemon.sh"

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  '') ;;
  -h|--help) usage; exit 0 ;;
  *) echo "usage: $(basename "$0")" >&2; exit 2 ;;
esac

mkdir -p "$STATE"
[ ! -e "$STATE/.afk" ] || { echo "error: away mode is active; use bin/fm-afk-start.sh" >&2; exit 1; }

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if pid=$(fm_identity_lock_live_pid "$LOCK"); then
  echo "supervisor: daemon already running pid=$pid"
  exit 0
fi

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  fm_lock_remove_path "$LOCK" 2>/dev/null || true
fi

echo "supervisor: starting normal daemon in foreground; keep this command as a tracked background task"
export FM_SUPERVISE_MODE=normal
exec "$DAEMON"
