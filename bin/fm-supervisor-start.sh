#!/usr/bin/env bash
# Start the durable normal-mode local supervisor for one FM_HOME.
#
# Usage: fm-supervisor-start.sh [--restart]
#   - exits 0 when state/.supervise-daemon.lock already names a live,
#     identity-matched daemon;
#   - with --restart, terminates only that identity-matched daemon, waits for
#     its lock to release, and starts the current daemon code;
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
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
}

RESTART=0
case "${1:-}" in
  '') ;;
  --restart) RESTART=1 ;;
  -h|--help) usage; exit 0 ;;
  *) echo "usage: $(basename "$0")" >&2; exit 2 ;;
esac

mkdir -p "$STATE"
[ ! -e "$STATE/.afk" ] || { echo "error: away mode is active; use bin/fm-afk-start.sh" >&2; exit 1; }

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if pid=$(fm_identity_lock_live_pid "$LOCK"); then
  if [ "$RESTART" -eq 0 ]; then
    echo "supervisor: daemon already running pid=$pid"
    exit 0
  fi
  echo "supervisor: stopping identity-matched daemon pid=$pid for restart"
  kill -TERM "$pid" 2>/dev/null \
    || { echo "error: could not signal identity-matched daemon pid=$pid" >&2; exit 1; }
  restart_wait=${FM_SUPERVISOR_RESTART_WAIT_SECS:-15}
  case "$restart_wait" in ''|*[!0-9]*|0) restart_wait=15 ;; esac
  restart_ticks=$((restart_wait * 10))
  while [ "$restart_ticks" -gt 0 ] && fm_identity_lock_live_pid "$LOCK" >/dev/null 2>&1; do
    sleep 0.1
    restart_ticks=$((restart_ticks - 1))
  done
  if fm_identity_lock_live_pid "$LOCK" >/dev/null 2>&1; then
    echo "error: identity-matched daemon pid=$pid did not stop within ${restart_wait}s" >&2
    exit 1
  fi
fi

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  fm_lock_remove_path "$LOCK" 2>/dev/null || true
fi

echo "supervisor: starting normal daemon in foreground; keep this command as a tracked background task"
export FM_SUPERVISE_MODE=normal
exec "$DAEMON"
