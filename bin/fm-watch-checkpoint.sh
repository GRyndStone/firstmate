#!/usr/bin/env bash
# Run one bounded foreground watcher checkpoint for harnesses that should not
# rely on background-task completion to wake the model.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECONDS_ARG=${FM_CODEX_WATCH_CHECKPOINT:-180}
WATCHER=${FM_WATCH_CHECKPOINT_WATCHER:-$SCRIPT_DIR/fm-watch.sh}

usage() {
  cat <<'EOF'
Usage: fm-watch-checkpoint.sh [--seconds <n>]

Run bin/fm-watch.sh in the foreground for a bounded checkpoint.
On an actionable watcher wake, pass through the watcher output and exit 0.
On a quiet checkpoint, print "checkpoint: no actionable wake within <n>s" and exit 124.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --seconds)
      [ "$#" -gt 1 ] || { echo "error: --seconds requires a value" >&2; exit 2; }
      SECONDS_ARG=$2
      shift 2
      ;;
    --seconds=*)
      SECONDS_ARG=${1#--seconds=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$SECONDS_ARG" in
  ''|*[!0-9]*) echo "error: --seconds must be a positive integer" >&2; exit 2 ;;
  0) echo "error: --seconds must be greater than zero" >&2; exit 2 ;;
esac

OUT=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.out.XXXXXX") || exit 1
ERR=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.err.XXXXXX") || {
  rm -f "$OUT"
  exit 1
}
TIMEOUT_MARKER=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.timeout.XXXXXX") || {
  rm -f "$OUT" "$ERR"
  exit 1
}
rm -f "$TIMEOUT_MARKER"
WATCH_PID=
TIMER_PID=
CLEANED=0

# shellcheck disable=SC2329 # Invoked by EXIT and signal traps below.
cleanup_owned_children() {
  local i
  [ "$CLEANED" -eq 0 ] || return 0
  CLEANED=1
  if [ -n "$TIMER_PID" ] && kill -0 "$TIMER_PID" 2>/dev/null; then
    kill -TERM "$TIMER_PID" 2>/dev/null || true
  fi
  [ -z "$TIMER_PID" ] || wait "$TIMER_PID" 2>/dev/null || true
  TIMER_PID=
  if [ -n "$WATCH_PID" ] && kill -0 "$WATCH_PID" 2>/dev/null; then
    kill -TERM "$WATCH_PID" 2>/dev/null || true
    i=0
    while kill -0 "$WATCH_PID" 2>/dev/null && [ "$i" -lt 20 ]; do
      sleep 0.05
      i=$((i + 1))
    done
    if kill -0 "$WATCH_PID" 2>/dev/null; then
      kill -KILL "$WATCH_PID" 2>/dev/null || true
    fi
  fi
  [ -z "$WATCH_PID" ] || wait "$WATCH_PID" 2>/dev/null || true
  WATCH_PID=
  rm -f "$OUT" "$ERR" "$TIMEOUT_MARKER"
}

# shellcheck disable=SC2329 # Invoked by HUP, INT, and TERM traps below.
checkpoint_interrupted() {
  local code=$1
  trap - HUP INT TERM
  cleanup_owned_children
  exit "$code"
}

trap 'checkpoint_interrupted 129' HUP
trap 'checkpoint_interrupted 130' INT
trap 'checkpoint_interrupted 143' TERM
trap cleanup_owned_children EXIT

# The checkpoint owns one exact watcher child and one exact timer child.
# Signal traps terminate and reap only those captured PIDs, so an interrupted
# foreground tool call cannot reparent fm-watch.sh to PID 1 or touch a watcher
# belonging to another checkpoint or Firstmate home.
FM_WATCH_OWNER_KIND=checkpoint FM_WATCH_OWNER_PID="${BASHPID:-$$}" \
  FM_WATCH_CHECKPOINT_TIMEOUT_MARKER="$TIMEOUT_MARKER" "$WATCHER" >"$OUT" 2>"$ERR" &
WATCH_PID=$!
(
  i=0
  sleep "$SECONDS_ARG"
  : > "$TIMEOUT_MARKER"
  if kill -TERM "$WATCH_PID" 2>/dev/null; then
    while kill -0 "$WATCH_PID" 2>/dev/null && [ "$i" -lt 40 ]; do
      sleep 0.05
      i=$((i + 1))
    done
    if kill -0 "$WATCH_PID" 2>/dev/null; then
      kill -KILL "$WATCH_PID" 2>/dev/null || true
    fi
  fi
) &
TIMER_PID=$!

set +e
wait "$WATCH_PID"
RC=$?
set -e
WATCH_PID=
if kill -0 "$TIMER_PID" 2>/dev/null; then
  kill -TERM "$TIMER_PID" 2>/dev/null || true
fi
wait "$TIMER_PID" 2>/dev/null || true
TIMER_PID=

if [ -e "$TIMEOUT_MARKER" ]; then
  RC=124
fi

if grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" >/dev/null 2>&1; then
  cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  exit 0
fi

if grep -E '^watcher: already running' "$OUT" "$ERR" >/dev/null 2>&1; then
  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  echo "checkpoint: watcher is already running outside this foreground checkpoint" >&2
  exit 1
fi

if [ "$RC" -eq 124 ]; then
  printf 'checkpoint: no actionable wake within %ss\n' "$SECONDS_ARG"
  exit 124
fi

[ ! -s "$OUT" ] || cat "$OUT"
[ ! -s "$ERR" ] || cat "$ERR" >&2
exit "$RC"
