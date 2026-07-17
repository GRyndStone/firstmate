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

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

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
WATCH_IDENTITY=
CHECKPOINT_PID=${BASHPID:-$$}
TIMER_PID=
CLEANED=0
TIMED_OUT=0

watch_birth_identity() {
  local identity
  identity=$(LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null) || return 1
  identity=$(printf '%s\n' "$identity" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$identity" ] || return 1
  printf '%s\n' "$identity"
}

capture_watch_identity() {
  local current_identity current_parent previous_identity= i=0
  while [ "$i" -lt 40 ]; do
    current_parent=$(ps -p "$WATCH_PID" -o ppid= 2>/dev/null | tr -d '[:space:]' || true)
    current_identity=$(watch_birth_identity "$WATCH_PID" 2>/dev/null || true)
    if [ "$current_parent" = "$CHECKPOINT_PID" ] && [ -n "$current_identity" ] \
       && [ -n "$previous_identity" ] && [ "$current_identity" = "$previous_identity" ]; then
      WATCH_IDENTITY=$current_identity
      return 0
    fi
    previous_identity=$current_identity
    sleep 0.01
    i=$((i + 1))
  done
  WATCH_IDENTITY="direct-child:$CHECKPOINT_PID:$WATCH_PID"
  return 0
}

watch_child_matches() {
  local current_identity current_parent
  [ -n "$WATCH_PID" ] && [ -n "$WATCH_IDENTITY" ] || return 1
  fm_pid_alive "$WATCH_PID" || return 1
  current_parent=$(ps -p "$WATCH_PID" -o ppid= 2>/dev/null | tr -d '[:space:]') || return 1
  [ "$current_parent" = "$CHECKPOINT_PID" ] || return 1
  if [ "$WATCH_IDENTITY" = "direct-child:$CHECKPOINT_PID:$WATCH_PID" ]; then
    return 0
  fi
  current_identity=$(watch_birth_identity "$WATCH_PID") || return 1
  [ "$current_identity" = "$WATCH_IDENTITY" ]
}

signal_watch_child() {
  local signal=$1
  watch_child_matches || return 1
  kill "-$signal" "$WATCH_PID" 2>/dev/null
}

stop_watch_child() {
  local limit=$1 i=0
  if signal_watch_child TERM; then
    while watch_child_matches && [ "$i" -lt "$limit" ]; do
      sleep 0.05
      i=$((i + 1))
    done
    if watch_child_matches; then
      signal_watch_child KILL || true
    fi
  fi
}

# shellcheck disable=SC2329 # Invoked by EXIT and signal traps below.
cleanup_owned_children() {
  [ "$CLEANED" -eq 0 ] || return 0
  CLEANED=1
  if [ -n "$TIMER_PID" ] && kill -0 "$TIMER_PID" 2>/dev/null; then
    kill -TERM "$TIMER_PID" 2>/dev/null || true
  fi
  [ -z "$TIMER_PID" ] || wait "$TIMER_PID" 2>/dev/null || true
  TIMER_PID=
  stop_watch_child 20
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
capture_watch_identity
(
  sleep "$SECONDS_ARG"
  : > "$TIMEOUT_MARKER"
) &
TIMER_PID=$!

while [ ! -e "$TIMEOUT_MARKER" ] && watch_child_matches; do
  sleep 0.05
done
if [ -e "$TIMEOUT_MARKER" ]; then
  TIMED_OUT=1
  stop_watch_child 40
fi
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
