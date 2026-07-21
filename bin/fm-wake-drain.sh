#!/usr/bin/env bash
# Atomically drain durable watcher wake records, then assert watcher liveness.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-reconcile-lib.sh
. "$SCRIPT_DIR/fm-reconcile-lib.sh"

DRAIN_TMP=
DRAIN_LOCK_HELD=false

# Defense in depth for the supervision chain: this script runs at the top of
# every wake-handling and recovery turn, so assert watcher liveness here too. A
# lapsed supervision chain then surfaces on a plain drain-and-handle turn, not
# only when a guarded supervision script (fm-peek/fm-send/...) happens to run.
# Reuse fm-guard.sh's existing graced, beacon-based banner (FM_GUARD_GRACE) - do
# not duplicate the beacon math. Because the watcher touches its beacon every
# poll cycle, a normal fire leaves a recent beacon well inside grace and stays
# silent; only a genuine stale-beyond-grace lapse with work in flight warns. Call
# after the queue is emptied so guard never re-prints its own queued-wakes notice
# for the records this run just drained, and never let a guard hiccup change the
# drain's exit status.
assert_watcher_liveness() {
  "$SCRIPT_DIR/fm-guard.sh" || true
}

# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local status=$?
  if [ "$status" -ne 0 ] && [ "$DRAIN_LOCK_HELD" = true ] && [ -n "$DRAIN_TMP" ] && [ -e "$DRAIN_TMP" ]; then
    fm_wake_restore_queue "$DRAIN_TMP" || true
  fi
  if [ "$DRAIN_LOCK_HELD" = true ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=true

if [ ! -s "$FM_WAKE_QUEUE" ]; then
  : > "$FM_WAKE_QUEUE"
  assert_watcher_liveness
  exit 0
fi

DRAIN_TMP="$STATE/.wake-queue.drain.$(fm_current_pid)"
rm -f "$DRAIN_TMP"
CLAIMED_MARKER=$(fm_wake_reconcile_claimed_marker_locked 2>/dev/null || true)
if [ -n "$CLAIMED_MARKER" ]; then
  DRAIN_KEEP="$STATE/.wake-queue.keep.$(fm_current_pid)"
  rm -f "$DRAIN_KEEP"
  awk -F '\t' -v claimed="$CLAIMED_MARKER" -v drain="$DRAIN_TMP" -v keep="$DRAIN_KEEP" '
    {
      marker = ""
      if (NF >= 5 && match($5, /\[fm-reconcile=[^]]+\]/)) marker = substr($5, RSTART, RLENGTH)
      if (marker == claimed) print > keep
      else print > drain
    }
  ' "$FM_WAKE_QUEUE" || exit 1
  [ -f "$DRAIN_TMP" ] || : > "$DRAIN_TMP"
  [ -f "$DRAIN_KEEP" ] || : > "$DRAIN_KEEP"
  mv -f "$DRAIN_KEEP" "$FM_WAKE_QUEUE" || exit 1
else
  mv "$FM_WAKE_QUEUE" "$DRAIN_TMP" || exit 1
  : > "$FM_WAKE_QUEUE" || exit 1
fi

if [ ! -s "$DRAIN_TMP" ]; then
  rm -f "$DRAIN_TMP"
  DRAIN_TMP=
  assert_watcher_liveness
  exit 0
fi

fm_wake_print_deduped "$DRAIN_TMP" || exit "$?"
while IFS=$(printf '\t') read -r _epoch _seq _kind _key payload; do
  [ -n "${payload:-}" ] || continue
  fm_reconcile_consumer_ack_reason "$STATE" "$payload" || exit 1
done < "$DRAIN_TMP"
rm -f "$DRAIN_TMP"
DRAIN_TMP=
assert_watcher_liveness
exit 0
