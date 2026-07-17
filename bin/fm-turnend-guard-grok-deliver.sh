#!/usr/bin/env bash
# Bounded deferred delivery for Grok primary turn-end continuations.
set -u

PENDING=${1:-}
ROOT=${2:-}
[ -n "$PENDING" ] && [ -n "$ROOT" ] || exit 1
[ -f "$PENDING" ] && [ ! -L "$PENDING" ] || exit 0
. "$ROOT/bin/fm-wake-lib.sh" || exit 1

DELAY=${FM_GROK_TURNEND_DELAY:-1}
RETRY_DELAY=${FM_GROK_TURNEND_RETRY_DELAY:-5}
TIMEOUT=${FM_GROK_TURNEND_DELIVERY_TIMEOUT:-120}
case "$DELAY" in ''|*[!0-9]*) DELAY=1 ;; esac
case "$RETRY_DELAY" in ''|*[!0-9]*|0) RETRY_DELAY=5 ;; esac
case "$TIMEOUT" in ''|*[!0-9]*|0) TIMEOUT=120 ;; esac
[ "$RETRY_DELAY" -le 60 ] || RETRY_DELAY=60
[ "$TIMEOUT" -le 300 ] || TIMEOUT=300

DELIVERY_LOCK="$PENDING.delivery"
LOCK_PID=${BASHPID:-$$}
LOCK_IDENTITY=$(fm_pid_identity "$LOCK_PID") || exit 1
LOCK_RECORD=$(printf '%s\n%s' "$LOCK_PID" "$LOCK_IDENTITY")
acquire_delivery_lock() {
  ( set -C; printf '%s\n' "$LOCK_RECORD" > "$DELIVERY_LOCK" ) 2>/dev/null
}
if ! acquire_delivery_lock; then
  [ -f "$DELIVERY_LOCK" ] && [ ! -L "$DELIVERY_LOCK" ] || exit 0
  old_record=$(cat "$DELIVERY_LOCK" 2>/dev/null || true)
  old_pid=$(printf '%s\n' "$old_record" | sed -n '1p')
  old_identity=$(printf '%s\n' "$old_record" | sed '1d')
  if fm_pid_alive "$old_pid" \
    && [ "$(fm_pid_identity "$old_pid" 2>/dev/null || true)" = "$old_identity" ]; then
    exit 0
  fi
  [ "$(cat "$DELIVERY_LOCK" 2>/dev/null || true)" = "$old_record" ] || exit 0
  rm -f "$DELIVERY_LOCK" || exit 0
  acquire_delivery_lock || exit 0
fi
cleanup() {
  if [ -f "$DELIVERY_LOCK" ] && [ ! -L "$DELIVERY_LOCK" ] \
    && [ "$(cat "$DELIVERY_LOCK" 2>/dev/null || true)" = "$LOCK_RECORD" ]; then
    rm -f "$DELIVERY_LOCK" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 1' TERM INT

run_delivery() {
  local delivery_pid timer_pid rc
  GROK_HOME="${GROK_HOME:-$HOME/.grok}" \
    grok --resume "$SESSION_ID" \
      --cwd "$ROOT" \
      --output-format plain \
      -p "$MESSAGE" >/dev/null 2>&1 &
  delivery_pid=$!
  (
    sleep "$TIMEOUT"
    kill -TERM "$delivery_pid" 2>/dev/null || exit 0
    sleep 2
    kill -KILL "$delivery_pid" 2>/dev/null || true
  ) &
  timer_pid=$!
  if wait "$delivery_pid"; then rc=0; else rc=$?; fi
  kill "$timer_pid" 2>/dev/null || true
  wait "$timer_pid" 2>/dev/null || true
  return "$rc"
}

wait_for_originating_hook() {
  local hook_pid=$1 hook_identity=$2 current_identity
  while fm_pid_alive "$hook_pid"; do
    current_identity=$(fm_pid_identity "$hook_pid" 2>/dev/null || true)
    [ "$current_identity" = "$hook_identity" ] || return 0
    sleep 0.05
  done
}

while [ -f "$PENDING" ] && [ ! -L "$PENDING" ]; do
  RECORD=$(cat "$PENDING" 2>/dev/null || true)
  TOKEN=$(printf '%s\n' "$RECORD" | sed -n '1p')
  HOOK_PID=$(printf '%s\n' "$RECORD" | sed -n '2p')
  HOOK_IDENTITY=$(printf '%s\n' "$RECORD" | sed -n '3p')
  SESSION_ID=$(printf '%s\n' "$RECORD" | sed -n '4p')
  REASON=$(printf '%s\n' "$RECORD" | sed '1,4d')
  [ -n "$TOKEN" ] && [ -n "$HOOK_PID" ] && [ -n "$HOOK_IDENTITY" ] && [ -n "$SESSION_ID" ] || exit 1
  wait_for_originating_hook "$HOOK_PID" "$HOOK_IDENTITY"
  sleep "$DELAY"
  [ "$(cat "$PENDING" 2>/dev/null || true)" = "$RECORD" ] || continue
  MESSAGE="TURN WOULD END BLIND - supervision is off. Resume supervision according to the session-start operating block before ending the turn.

$REASON"
  if run_delivery; then
    [ "$(cat "$PENDING" 2>/dev/null || true)" = "$RECORD" ] && rm -f "$PENDING"
    continue
  fi
  sleep "$RETRY_DELAY"
done

exit 0
