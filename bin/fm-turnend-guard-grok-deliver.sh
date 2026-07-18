#!/usr/bin/env bash
# Bounded deferred delivery for Grok primary turn-end continuations.
set -u

PENDING=${1:-}
ROOT=${2:-}
EXPECTED_TOKEN=${3:-}
EXPECTED_STATE=${4:-}
[ -n "$PENDING" ] && [ -n "$ROOT" ] && [ -n "$EXPECTED_STATE" ] || exit 1
case "$PENDING" in /*) ;; *) PENDING="$PWD/$PENDING" ;; esac
[ -L "$PENDING" ] && exit 1
HANDOFF_DIR=${PENDING%/*}
STATE_DIR=${HANDOFF_DIR%/*}
PENDING_NAME=${PENDING##*/}
EFFECTIVE_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}
EFFECTIVE_STATE=${FM_STATE_OVERRIDE:-$EFFECTIVE_HOME/state}
case "$EFFECTIVE_STATE" in /*) ;; *) EFFECTIVE_STATE="$PWD/$EFFECTIVE_STATE" ;; esac
case "$EXPECTED_STATE" in /*) ;; *) EXPECTED_STATE="$PWD/$EXPECTED_STATE" ;; esac
FM_STATE_OVERRIDE=$EFFECTIVE_STATE
# shellcheck source=bin/fm-wake-lib.sh
FM_WAKE_STATE_INIT=skip
. "$ROOT/bin/fm-wake-lib.sh" || exit 1
unset FM_WAKE_STATE_INIT
EFFECTIVE_STATE=$FM_VALIDATED_STATE_PATH
fm_validate_effective_state_path "$EXPECTED_STATE" existing || exit 1
EXPECTED_STATE=$FM_VALIDATED_STATE_PATH
fm_validate_effective_state_path "$STATE_DIR" existing || exit 1
STATE_DIR=$FM_VALIDATED_STATE_PATH
[ "$EXPECTED_STATE" = "$EFFECTIVE_STATE" ] || exit 1
[ "$STATE_DIR" = "$EXPECTED_STATE" ] || exit 1
[ "${HANDOFF_DIR##*/}" = .turnend-handoffs ] || exit 1
HANDOFF_DIR="$EXPECTED_STATE/.turnend-handoffs"
PENDING="$HANDOFF_DIR/$PENDING_NAME"
[ -d "$HANDOFF_DIR" ] && [ ! -L "$HANDOFF_DIR" ] || exit 1
case "$PENDING" in "$HANDOFF_DIR"/grok-*.pending) ;; *) exit 1 ;; esac
ACKNOWLEDGED="$PENDING.acknowledged"
if [ ! -f "$PENDING" ]; then
  if [ -f "$ACKNOWLEDGED" ] && [ ! -L "$ACKNOWLEDGED" ]; then
    rm -f "$ACKNOWLEDGED" 2>/dev/null || true
  fi
  exit 0
fi
[ -n "$EXPECTED_TOKEN" ] || EXPECTED_TOKEN=$(sed -n '1p' "$PENDING" 2>/dev/null || true)
[ -n "$EXPECTED_TOKEN" ] || exit 1

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
LOCK_RECORD=$(printf '%s\n%s\n%s' "$EXPECTED_TOKEN" "$LOCK_PID" "$LOCK_IDENTITY")
READY="$PENDING.ready"
READY_RECORD=$(printf '%s\n%s\n%s' "$EXPECTED_TOKEN" "$LOCK_PID" "$LOCK_IDENTITY")
READY_TMP=
DELIVERY_PID=
TIMER_PID=
DELIVERY_IDENTITY=
TIMER_IDENTITY=
acquire_delivery_lock() {
  ( set -C; printf '%s\n' "$LOCK_RECORD" > "$DELIVERY_LOCK" ) 2>/dev/null
}
if ! acquire_delivery_lock; then
  [ -f "$DELIVERY_LOCK" ] && [ ! -L "$DELIVERY_LOCK" ] || exit 0
  old_record=$(cat "$DELIVERY_LOCK" 2>/dev/null || true)
  old_pid=$(printf '%s\n' "$old_record" | sed -n '2p')
  old_identity=$(printf '%s\n' "$old_record" | sed '1,2d')
  case "$old_pid" in
    ''|*[!0-9]*)
      old_pid=$(printf '%s\n' "$old_record" | sed -n '1p')
      old_identity=$(printf '%s\n' "$old_record" | sed '1d')
      ;;
  esac
  if fm_pid_alive "$old_pid" \
    && [ "$(fm_pid_identity "$old_pid" 2>/dev/null || true)" = "$old_identity" ]; then
    exit 0
  fi
  [ "$(cat "$DELIVERY_LOCK" 2>/dev/null || true)" = "$old_record" ] || exit 0
  rm -f "$DELIVERY_LOCK" || exit 0
  acquire_delivery_lock || exit 0
fi
# shellcheck disable=SC2329 # Invoked by name from the EXIT trap.
cleanup() {
  if [ -n "$READY_TMP" ] && [ -f "$READY_TMP" ] && [ ! -L "$READY_TMP" ]; then
    rm -f "$READY_TMP" 2>/dev/null || true
  fi
  if [ -f "$READY" ] && [ ! -L "$READY" ] \
    && [ "$(cat "$READY" 2>/dev/null || true)" = "$READY_RECORD" ]; then
    rm -f "$READY" 2>/dev/null || true
  fi
  if [ -f "$DELIVERY_LOCK" ] && [ ! -L "$DELIVERY_LOCK" ] \
    && [ "$(cat "$DELIVERY_LOCK" 2>/dev/null || true)" = "$LOCK_RECORD" ]; then
    rm -f "$DELIVERY_LOCK" 2>/dev/null || true
  fi
}
child_owned_by_worker() {
  local pid=$1 identity=$2 active_pid
  fm_pid_alive "$pid" || return 1
  while IFS= read -r active_pid; do
    [ "$active_pid" = "$pid" ] && return 0
  done < <(jobs -pr 2>/dev/null)
  if [ -n "$identity" ]; then
    [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "$identity" ]
    return
  fi
  return 1
}
# shellcheck disable=SC2329 # Invoked by the signal trap callback.
stop_active_children() {
  local pid identity attempt
  for pid in "$TIMER_PID" "$DELIVERY_PID"; do
    [ -n "$pid" ] || continue
    if [ "$pid" = "$TIMER_PID" ]; then identity=$TIMER_IDENTITY; else identity=$DELIVERY_IDENTITY; fi
    child_owned_by_worker "$pid" "$identity" || continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  attempt=0
  while [ "$attempt" -lt 40 ] && { fm_pid_alive "$DELIVERY_PID" || fm_pid_alive "$TIMER_PID"; }; do
    sleep 0.05
    attempt=$((attempt + 1))
  done
  for pid in "$TIMER_PID" "$DELIVERY_PID"; do
    [ -n "$pid" ] || continue
    if [ "$pid" = "$TIMER_PID" ]; then identity=$TIMER_IDENTITY; else identity=$DELIVERY_IDENTITY; fi
    if child_owned_by_worker "$pid" "$identity"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
  done
  DELIVERY_PID=
  TIMER_PID=
  DELIVERY_IDENTITY=
  TIMER_IDENTITY=
}
# shellcheck disable=SC2329 # Invoked by name from signal traps.
handle_signal() {
  trap - TERM INT
  stop_active_children
  cleanup
  exit 1
}
trap cleanup EXIT
trap handle_signal TERM INT

[ "$(sed -n '1p' "$PENDING" 2>/dev/null || true)" = "$EXPECTED_TOKEN" ] || exit 0
READY_TMP=$(mktemp "$HANDOFF_DIR/.grok-ready.XXXXXX") || exit 1
printf '%s\n' "$READY_RECORD" > "$READY_TMP" || exit 1
chmod 600 "$READY_TMP" 2>/dev/null || true
fm_publish_file_no_follow "$READY_TMP" "$READY" replace || { rm -f "$READY_TMP"; exit 1; }
READY_TMP=

run_delivery() {
  local rc deadline term_deadline
  GROK_HOME="${GROK_HOME:-$HOME/.grok}" \
    grok --resume "$SESSION_ID" \
      --cwd "$ROOT" \
      --output-format plain \
      -p "$MESSAGE" >/dev/null 2>&1 &
  DELIVERY_PID=$!
  DELIVERY_IDENTITY=$(fm_pid_identity "$DELIVERY_PID" 2>/dev/null || true)
  deadline=$((SECONDS + TIMEOUT))
  term_deadline=0
  while child_owned_by_worker "$DELIVERY_PID" "$DELIVERY_IDENTITY"; do
    if [ "$term_deadline" -eq 0 ] && [ "$SECONDS" -ge "$deadline" ]; then
      if child_owned_by_worker "$DELIVERY_PID" "$DELIVERY_IDENTITY"; then
        kill -TERM "$DELIVERY_PID" 2>/dev/null || true
      fi
      term_deadline=$((SECONDS + 2))
    elif [ "$term_deadline" -ne 0 ] && [ "$SECONDS" -ge "$term_deadline" ]; then
      if child_owned_by_worker "$DELIVERY_PID" "$DELIVERY_IDENTITY"; then
        kill -KILL "$DELIVERY_PID" 2>/dev/null || true
      fi
      break
    fi
    sleep 1 &
    TIMER_PID=$!
    TIMER_IDENTITY=$(fm_pid_identity "$TIMER_PID" 2>/dev/null || true)
    wait "$TIMER_PID" 2>/dev/null || true
    TIMER_PID=
    TIMER_IDENTITY=
  done
  if wait "$DELIVERY_PID"; then rc=0; else rc=$?; fi
  DELIVERY_PID=
  DELIVERY_IDENTITY=
  return "$rc"
}

quarantine_legacy_pending() {
  local record=$1 quarantine
  quarantine=$(mktemp "$PENDING.legacy-continue.quarantined.XXXXXX") || return 1
  rm -f "$quarantine" || return 1
  [ "$(cat "$PENDING" 2>/dev/null || true)" = "$record" ] || return 0
  fm_publish_file_no_follow "$PENDING" "$quarantine" exclusive
}

acknowledged_matches() {
  local record=$1
  [ -f "$ACKNOWLEDGED" ] && [ ! -L "$ACKNOWLEDGED" ] \
    && [ "$(cat "$ACKNOWLEDGED" 2>/dev/null || true)" = "$record" ]
}

cleanup_acknowledged() {
  local record=$1
  if [ -f "$PENDING" ] && [ ! -L "$PENDING" ]; then
    [ "$(cat "$PENDING" 2>/dev/null || true)" = "$record" ] || return 1
    if ! acknowledged_matches "$record"; then
      fm_publish_file_no_follow "$PENDING" "$ACKNOWLEDGED" replace || return 1
    else
      rm -f "$PENDING" || return 1
    fi
  fi
  acknowledged_matches "$record" || return 1
  rm -f "$ACKNOWLEDGED" || return 1
  [ ! -e "$ACKNOWLEDGED" ]
}

wait_for_originating_hook() {
  local hook_pid=$1 hook_identity=$2 current_identity
  while fm_pid_alive "$hook_pid"; do
    current_identity=$(fm_pid_identity "$hook_pid" 2>/dev/null || true)
    [ "$current_identity" = "$hook_identity" ] || return 0
    sleep 0.05
  done
}

ACKNOWLEDGED_RECORD=
while { [ -f "$PENDING" ] && [ ! -L "$PENDING" ]; } \
  || { [ -f "$ACKNOWLEDGED" ] && [ ! -L "$ACKNOWLEDGED" ]; }; do
  if [ ! -f "$PENDING" ]; then
    rm -f "$ACKNOWLEDGED" 2>/dev/null || sleep "$RETRY_DELAY"
    continue
  fi
  RECORD=$(cat "$PENDING" 2>/dev/null || true)
  TOKEN=$(printf '%s\n' "$RECORD" | sed -n '1p')
  HOOK_PID=$(printf '%s\n' "$RECORD" | sed -n '2p')
  HOOK_IDENTITY=$(printf '%s\n' "$RECORD" | sed -n '3p')
  SESSION_ID=$(printf '%s\n' "$RECORD" | sed -n '4p')
  REASON=$(printf '%s\n' "$RECORD" | sed '1,4d')
  [ -n "$TOKEN" ] && [ -n "$HOOK_PID" ] && [ -n "$HOOK_IDENTITY" ] && [ -n "$SESSION_ID" ] || exit 1
  wait_for_originating_hook "$HOOK_PID" "$HOOK_IDENTITY"
  if [ "$SESSION_ID" = '@continue' ]; then
    quarantine_legacy_pending "$RECORD" || exit 1
    continue
  fi
  sleep "$DELAY"
  [ "$(cat "$PENDING" 2>/dev/null || true)" = "$RECORD" ] || continue
  if [ "$ACKNOWLEDGED_RECORD" = "$RECORD" ] || acknowledged_matches "$RECORD"; then
    if cleanup_acknowledged "$RECORD"; then
      ACKNOWLEDGED_RECORD=
    else
      sleep "$RETRY_DELAY"
    fi
    continue
  fi
  if [ -e "$ACKNOWLEDGED" ]; then
    [ -f "$ACKNOWLEDGED" ] && [ ! -L "$ACKNOWLEDGED" ] || exit 1
    rm -f "$ACKNOWLEDGED" || { sleep "$RETRY_DELAY"; continue; }
  fi
  MESSAGE="TURN WOULD END BLIND - supervision is off. Resume supervision according to the session-start operating block before ending the turn.

$REASON"
  if run_delivery; then
    ACKNOWLEDGED_RECORD=$RECORD
    cleanup_acknowledged "$RECORD" || true
    continue
  fi
  sleep "$RETRY_DELAY"
done

exit 0
