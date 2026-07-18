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
START_MARKER=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.start.XXXXXX") || {
  rm -f "$OUT" "$ERR" "$TIMEOUT_MARKER"
  exit 1
}
ABORT_MARKER=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.abort.XXXXXX") || {
  rm -f "$OUT" "$ERR" "$TIMEOUT_MARKER" "$START_MARKER"
  exit 1
}
rm -f "$START_MARKER" "$ABORT_MARKER"
WATCH_PID=
WATCH_IDENTITY=
CHECKPOINT_PID=${BASHPID:-$$}
TIMER_PID=
CLEANED=0
TIMED_OUT=0

watch_birth_identity() {
  fm_pid_birth_identity "$1"
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
  WATCH_IDENTITY=
  return 1
}

watch_child_state() {
  local current_identity current_parent pid_state
  [ -n "$WATCH_PID" ] && [ -n "$WATCH_IDENTITY" ] || { printf '%s\n' unknown; return; }
  pid_state=$(fm_pid_state "$WATCH_PID")
  [ "$pid_state" = alive ] || { printf '%s\n' "$pid_state"; return; }
  current_parent=$(ps -p "$WATCH_PID" -o ppid= 2>/dev/null | tr -d '[:space:]') || {
    printf '%s\n' unknown
    return
  }
  [ "$current_parent" = "$CHECKPOINT_PID" ] || { printf '%s\n' mismatch; return; }
  current_identity=$(watch_birth_identity "$WATCH_PID") || { printf '%s\n' unknown; return; }
  [ "$current_identity" = "$WATCH_IDENTITY" ] || { printf '%s\n' mismatch; return; }
  printf '%s\n' alive
}

reap_watch_child_bounded() {
  local limit=$1 i=0 child_state
  [ -n "$WATCH_PID" ] || return 0
  while [ "$i" -lt "$limit" ]; do
    child_state=$(watch_child_state)
    case "$child_state" in
      dead)
        wait "$WATCH_PID" 2>/dev/null || true
        WATCH_PID=
        return 0
        ;;
      mismatch)
        WATCH_PID=
        return 0
        ;;
    esac
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

signal_watch_child() {
  local signal=$1
  [ "$(watch_child_state)" = alive ] || return 1
  kill "-$signal" "$WATCH_PID" 2>/dev/null
}

retain_watch_child() {
  [ -n "$WATCH_PID" ] && [ -n "$WATCH_IDENTITY" ] || return 1
  fm_record_checkpoint_orphan "$STATE" "$WATCH_PID" "$WATCH_IDENTITY" || {
    echo "checkpoint: FAILED - exact watcher pid=$WATCH_PID remains live but durable orphan ownership could not be recorded" >&2
    return 1
  }
  echo "checkpoint: ORPHANED exact watcher pid=$WATCH_PID; durable ownership retained at $(fm_checkpoint_orphan_path "$STATE")" >&2
  WATCH_PID=
  return 0
}

stop_watch_child() {
  local limit=$1 i=0 term_sent=0 child_state
  [ -n "$WATCH_PID" ] || return 0
  while [ "$i" -lt "$limit" ]; do
    child_state=$(watch_child_state)
    case "$child_state" in
      dead|mismatch)
        reap_watch_child_bounded 1 && return 0
        retain_watch_child
        return
        ;;
    esac
    if [ "$child_state" = alive ] && [ "$term_sent" -eq 0 ] && signal_watch_child TERM; then
      term_sent=1
    fi
    sleep 0.05
    i=$((i + 1))
  done
  child_state=$(watch_child_state)
  case "$child_state" in
    dead|mismatch)
      reap_watch_child_bounded 1 && return 0
      retain_watch_child
      return
      ;;
  esac
  if [ "$child_state" = alive ]; then
    signal_watch_child KILL || true
  fi
  reap_watch_child_bounded 20 && return 0
  retain_watch_child
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
  stop_watch_child 20 || retain_watch_child || true
  rm -f "$OUT" "$ERR" "$TIMEOUT_MARKER" "$START_MARKER" "$ABORT_MARKER"
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
(
  wait_count=0
  while [ ! -e "$START_MARKER" ]; do
    [ ! -e "$ABORT_MARKER" ] || exit 125
    fm_pid_alive "$CHECKPOINT_PID" || exit 125
    [ "$wait_count" -lt 200 ] || exit 125
    sleep 0.01
    wait_count=$((wait_count + 1))
  done
  exec env FM_WATCH_OWNER_KIND=checkpoint FM_WATCH_OWNER_PID="$CHECKPOINT_PID" \
    FM_WATCH_CHECKPOINT_TIMEOUT_MARKER="$TIMEOUT_MARKER" "$WATCHER"
) >"$OUT" 2>"$ERR" &
WATCH_PID=$!
if ! capture_watch_identity; then
  : > "$ABORT_MARKER"
  i=0
  CHILD_STATE=$(fm_pid_state "$WATCH_PID")
  while [ "$CHILD_STATE" != dead ] && [ "$i" -lt 200 ]; do
    sleep 0.01
    i=$((i + 1))
    CHILD_STATE=$(fm_pid_state "$WATCH_PID")
  done
  if [ "$CHILD_STATE" = dead ]; then
    wait "$WATCH_PID" 2>/dev/null || true
  else
    echo "checkpoint: exact wrapper exit could not be confirmed after its abort gate closed" >&2
  fi
  WATCH_PID=
  echo "checkpoint: exact watcher child identity could not be captured; watcher was not started" >&2
  exit 1
fi
: > "$START_MARKER"
(
  sleep "$SECONDS_ARG"
  : > "$TIMEOUT_MARKER"
) &
TIMER_PID=$!

WATCH_FINISHED=0
while [ ! -e "$TIMEOUT_MARKER" ]; do
  CHILD_STATE=$(watch_child_state)
  case "$CHILD_STATE" in dead|mismatch) WATCH_FINISHED=1; break ;; esac
  sleep 1
done
if [ -e "$TIMEOUT_MARKER" ]; then
  TIMED_OUT=1
  stop_watch_child 20 || retain_watch_child || true
fi
set +e
RC=1
if [ -z "$WATCH_PID" ]; then
  RC=0
elif [ "$WATCH_FINISHED" -eq 1 ] && [ "$(watch_child_state)" = dead ]; then
  wait "$WATCH_PID"
  RC=$?
  WATCH_PID=
elif reap_watch_child_bounded 40; then
  RC=0
else
  retain_watch_child || true
fi
set -e
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
