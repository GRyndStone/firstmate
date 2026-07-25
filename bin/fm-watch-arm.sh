#!/usr/bin/env bash
# Safe, home-scoped (re-)arm of the firstmate watcher, with honest verification.
#
# The watcher (bin/fm-watch.sh) blocks until it has an actionable wake to
# surface, then prints one reason line and exits. While state/.afk exists the
# daemon owns triage and the watcher exits on every wake for the daemon to
# classify. Reliability depends on arming through a mechanism that SURVIVES the
# call and NOTIFIES on exit, so firstmate must run this script as the harness's
# own tracked background task (e.g. run_in_background). Run it as its own
# standalone background task, never bundled onto the tail of another command.
# NEVER fire it and forget with a shell `&` inside another call: that backgrounded
# child is reaped when the call returns, leaving NO watcher running and a false
# "already running" off the dying process. That exact mistake silently took
# supervision down for ~30 minutes.
# On a harness with a PreToolUse-equivalent hook, bin/fm-arm-pretool-check.sh
# applies the command-position policy before the command runs; see
# docs/arm-pretool-check.md for the blessed tree and deny reason codes. It is a
# pre-execution seatbelt, not a substitute for the verification here.
#
# This script starts the watcher DETACHED (bin/fm-detach.sh), then VERIFIES the
# outcome before it settles in. Detached means the watcher is deliberately not a
# descendant of this arm: when the harness stops this background task it walks
# this task's descendant tree and signals everything in it, and a watcher forked
# as an ordinary child went down with it - the fleet then ran unsupervised until
# somebody noticed. The watcher must outlive its launcher, so this arm no longer
# kills it on the way out; it just stops reporting for it. Nothing is lost by
# that: every wake reason is already durable in state/.wake-queue before the
# watcher prints it, and bin/fm-guard.sh proves an orphaned or dead watcher from
# durable state on the next fleet action. The detachment mechanism and the
# measured evidence behind it live in bin/fm-detach.sh and
# docs/turnend-guard.md ("Detached supervision watcher").
#
# Because the watcher is no longer this arm's child, this arm records the
# ownership provenance in the lock itself (owner-kind/owner-pid/owner-tracker-*)
# rather than letting the watcher derive it from its parent. The provenance is
# the same claim it always was - a live, identity-matched arm and a live,
# identity-matched harness task tracking it - and it is re-verified through
# fm_watcher_live_owner before this script reports success.
#
# Verification is unchanged by any of that. It confirms a watcher process is
# genuinely alive AND the
# liveness beacon (state/.last-watcher-beat) is fresh within FM_GUARD_GRACE (the
# single source of truth, shared with fm-watch.sh and fm-guard.sh), and prints
# exactly one unambiguous status line:
#   watcher: started pid=<N> (beacon fresh)              - it launched one and confirmed it
#   watcher: attached pid=<N> (beacon <age>s)            - arm mode found a live+fresh watcher
#                                                          holding the lock; this arm attaches and
#                                                          waits until that cycle ends
#   watcher: healthy pid=<N> (beacon <age>s)             - restart mode found a live+fresh
#                                                          watcher it did not own
#   watcher: FAILED - no live watcher with a fresh beacon  - could not confirm one
# It NEVER reports started/attached/healthy off a stale beacon or a dead/reused pid: a
# stale-beacon or dead-pid holder either self-heals (the fresh child steals the
# dead lock per the singleton self-eviction/steal path and is confirmed) or this
# returns the FAILED line. On started it waits out the detached watcher and
# propagates the wake reason; on attached it stays live until the identity-matched holder is no longer
# healthy, then exits zero so the harness background-notify fires then (not as a
# false empty wake). On restart-only healthy it exits zero after the duplicate
# child stands down. On FAILED it exits non-zero so the failure is loud. A live
# cycle already present means re-arm attaches - do not start a second watcher.
#
# --restart: stop ONLY this FM_HOME's watcher (the pid recorded in THIS home's
# state/.watch.lock) and own a fresh cycle, or report restart-only healthy if a
# live peer still holds the lock after the duplicate child stands down. It
# resolves and signals exactly that pid, so it can never touch another home's
# watcher. NEVER `pkill -f
# bin/fm-watch.sh`: that pattern matches every firstmate home's watcher
# (secondmate homes run the same script) and would kill siblings. Restart never
# takes the attach path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

WATCH="$SCRIPT_DIR/fm-watch.sh"
WATCH_LOCK="$STATE/.watch.lock"
BEAT="$STATE/.last-watcher-beat"
# "Fresh" reuses the guard's threshold so there is one definition of liveness.
GRACE=${FM_GUARD_GRACE:-300}
# How long to wait for a freshly forked watcher to acquire the lock and beat.
CONFIRM_TIMEOUT=${FM_ARM_CONFIRM_TIMEOUT:-10}
# Poll interval while attached to an existing healthy watcher.
ATTACH_POLL=${FM_ARM_ATTACH_POLL:-0.5}
ARM_OWNER_PID=${BASHPID:-$$}
ARM_OWNER_IDENTITY=$(fm_pid_identity "$ARM_OWNER_PID" 2>/dev/null || true)
ARM_TRACKER_PID=${FM_WATCH_OWNER_TRACKER_PID:-${PPID:-}}
ARM_TRACKER_IDENTITY=$(fm_pid_identity "$ARM_TRACKER_PID" 2>/dev/null || true)

arm_owner_ready() {
  case "$ARM_TRACKER_PID" in ''|*[!0-9]*|1) return 1 ;; esac
  [ -n "$ARM_OWNER_IDENTITY" ] && [ -n "$ARM_TRACKER_IDENTITY" ] || return 1
  fm_pid_alive "$ARM_OWNER_PID" && fm_pid_alive "$ARM_TRACKER_PID"
}

record_arm_owner() {
  arm_owner_ready || return 1
  printf '%s\n' arm > "$WATCH_LOCK/owner-kind" || return 1
  printf '%s\n' '' > "$WATCH_LOCK/owner-mode" || return 1
  printf '%s\n' "$ARM_OWNER_PID" > "$WATCH_LOCK/owner-pid" || return 1
  printf '%s\n' "$ARM_OWNER_IDENTITY" > "$WATCH_LOCK/owner-identity" || return 1
  printf '%s\n' "$ARM_TRACKER_PID" > "$WATCH_LOCK/owner-tracker-pid" || return 1
  printf '%s\n' "$ARM_TRACKER_IDENTITY" > "$WATCH_LOCK/owner-tracker-identity" || return 1
  fm_watcher_live_owner "$STATE" || return 1
  [ "$FM_WATCHER_OWNER_KIND" = arm ] \
    && [ "$FM_WATCHER_OWNER_PID" = "$ARM_OWNER_PID" ] \
    && [ "$FM_WATCHER_OWNER_TRACKER_PID" = "$ARM_TRACKER_PID" ]
}

record_attached_arm_owner() {
  if fm_watcher_live_owner "$STATE"; then
    case "$FM_WATCHER_OWNER_KIND" in arm|daemon) return 0 ;; esac
  fi
  record_arm_owner
}

clear_stale_recorded_watcher_lock() {
  local lock_home lock_path lock_identity
  lock_home=$(cat "$WATCH_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$WATCH_LOCK/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 0
  [ "$lock_path" = "$WATCH" ] || return 0
  [ -n "$lock_identity" ] || return 0
  fm_lock_remove_path "$WATCH_LOCK" || true
}

# A watcher is "healthy" iff the lock names a live process that is genuinely THIS
# home's watcher (the identity match guards against a recycled/reused pid) AND the
# liveness beacon is fresh within GRACE. Sets HEALTHY_PID on success. This is the
# single honesty gate: a dead pid, a reused pid, or a stale beacon all fail it, so
# this script can never report a watcher that is not really there.
HEALTHY_PID=
healthy_watcher() {
  HEALTHY_PID=
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" || return 1
  HEALTHY_PID=$FM_WATCHER_HEALTHY_PID
}

report_attached() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: attached pid=$HEALTHY_PID (beacon ${age}s)"
}

report_healthy() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: healthy pid=$HEALTHY_PID (beacon ${age}s)"
}

# Stay alive until the attached identity-matched healthy holder is gone.
# If a different healthy watcher appears mid-attach (rare steal), re-attach.
# Does not reprint the starter arm's wake reason line; exit 0 lets the harness
# notify, and firstmate drains state/.wake-queue on background completion.
attach_and_wait() {
  local attached_pid=$1
  while :; do
    if healthy_watcher; then
      if [ "$HEALTHY_PID" != "$attached_pid" ]; then
        attached_pid=$HEALTHY_PID
        report_attached
      fi
      sleep "$ATTACH_POLL"
      continue
    fi
    # Attached cycle ended (pid gone, identity mismatch, or beacon no longer fresh).
    exit 0
  done
}

watch_output_has_wake() {
  local out=$1
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null
}

print_watch_output() {
  local out=$1
  [ -s "$out" ] && cat "$out"
}

# The detached watcher's stderr lands in the same capture file rather than this
# arm's stderr, so surface it on the failure path or its diagnostics (a stale
# lock, a live holder that will not stand down) would be silently dropped.
print_watch_diagnostics() {
  local out=$1
  [ -s "$out" ] && cat "$out" >&2
}

# Wait out a watcher that is not our child, so `wait` is unavailable.
detached_wait() {
  local pid=$1
  while fm_pid_alive "$pid"; do
    sleep "$ATTACH_POLL"
  done
}

# An arm that was killed cannot delete its own capture file, and its watcher may
# still be writing to it, so sweep here instead: drop only captures whose owning
# arm pid is gone. Unlinking one a live watcher still holds open is harmless -
# only that dead arm would ever have read this copy, and the wake reasons in it
# are already durable in state/.wake-queue. Non-numeric suffixes are leftovers
# from the pre-detachment mktemp naming and are always orphans.
sweep_orphan_arm_captures() {
  local capture suffix
  for capture in "$STATE"/.watch-arm-output.*; do
    [ -e "$capture" ] || continue
    suffix=${capture##*.watch-arm-output.}
    case "$suffix" in
      "$ARM_OWNER_PID") continue ;;
      ''|*[!0-9]*) rm -f "$capture" 2>/dev/null || true; continue ;;
    esac
    fm_pid_alive "$suffix" && continue
    rm -f "$capture" 2>/dev/null || true
  done
}

# FAILED means this arm never confirmed its own watcher as the home's singleton.
# That process is therefore not the lock holder, so stopping the exact pid this
# arm launched cannot touch this home's real watcher and can never reach a
# sibling home's watcher. Leaving it would let it take the lock moments later and
# race the re-arm firstmate is about to make - the duplicate hazard that only
# appears once watchers outlive their launchers.
stand_down_unconfirmed_watcher() {
  [ -n "$child" ] || return 0
  fm_pid_alive "$child" || return 0
  [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" = "$child" ] && return 0
  kill -TERM "$child" 2>/dev/null || true
}

mode=arm
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --restart) mode=restart ;;
  *) echo "usage: $(basename "$0") [--restart]" >&2; exit 2 ;;
esac

arm_owner_ready || {
  echo "watcher: FAILED - no turn-surviving owner tracks this arm"
  exit 1
}

child=
child_out=
sweep_orphan_arm_captures

if [ "$mode" = restart ]; then
  # Home-scoped stop: only the watcher pid recorded in THIS home's lock.
  lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  if fm_pid_alive "$lock_pid"; then
    if fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$lock_pid" "$FM_HOME"; then
      kill -TERM "$lock_pid" 2>/dev/null || true
      # Wait for it to actually exit before relaunching, so the fresh watcher
      # either takes a released lock or reclaims a now-dead-pid stale lock instead
      # of seeing the dying one as a live holder and no-opping.
      i=0
      while [ "$i" -lt 50 ] && fm_pid_alive "$lock_pid"; do
        sleep 0.1
        i=$((i + 1))
      done
    else
      clear_stale_recorded_watcher_lock
    fi
  fi
fi

# If a genuinely live+fresh watcher already holds the lock, do not start a second
# one - attach to that cycle and wait until it ends so the harness notify fires
# then, not as an immediate empty wake. (--restart skips this: it just stopped
# this home's watcher and wants a fresh one.)
if [ "$mode" = arm ] && healthy_watcher; then
  record_attached_arm_owner || {
    echo "watcher: FAILED - no turn-surviving owner tracks this arm"
    exit 1
  }
  report_attached
  attach_and_wait "$HEALTHY_PID"
fi

# Start a watcher DETACHED from this arm's process tree and confirm it before
# settling in. Being detached is the point: when the harness stops this
# background task it signals this task's whole descendant tree, and a watcher
# forked as an ordinary child died with it. So these signal traps deliberately
# leave the watcher running - it keeps observing the fleet and freshening
# state/.last-watcher-beat, its wake reasons are already durable in
# state/.wake-queue, and bin/fm-guard.sh proves the missing OWNER from durable
# state on the next fleet action so firstmate re-arms and re-adopts it.
# The capture file is left behind on this path too, because the surviving
# watcher is still writing to it; the next arm sweeps it.
trap 'exit 129' HUP
trap 'exit 143' TERM INT

child_out="$STATE/.watch-arm-output.$ARM_OWNER_PID"
child=$("$SCRIPT_DIR/fm-detach.sh" "$child_out" "$WATCH") || child=
case "$child" in
  ''|*[!0-9]*)
    child=
    echo "watcher: FAILED - no live watcher with a fresh beacon"
    print_watch_diagnostics "$child_out"
    rm -f "$child_out" 2>/dev/null || true
    exit 1
    ;;
esac
child_done=0

# Verify the outcome: poll until this child is the confirmed healthy watcher, or
# until some other watcher legitimately holds the singleton (a startup race), or
# until the child gives up. Only then print the honest line.
deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
while :; do
  if healthy_watcher; then
    if [ "$HEALTHY_PID" = "$child" ]; then
      # The watcher is not our parent's child any more, so it cannot derive this
      # arm's provenance from its own PPID: record it here, and re-read it back
      # through fm_watcher_live_owner so a claim that does not verify still fails.
      record_arm_owner || break
      echo "watcher: started pid=$child (beacon fresh)"
      detached_wait "$child"
      print_watch_output "$child_out"
      rc=0
      watch_output_has_wake "$child_out" || rc=1
      rm -f "$child_out" 2>/dev/null || true
      exit "$rc"
    fi
    # Another watcher won the singleton; ours stood down.
    if [ "$mode" = arm ]; then
      record_attached_arm_owner || {
        echo "watcher: FAILED - no turn-surviving owner tracks this arm"
        stand_down_unconfirmed_watcher
        rm -f "$child_out" 2>/dev/null || true
        exit 1
      }
      report_attached
      stand_down_unconfirmed_watcher
      rm -f "$child_out" 2>/dev/null || true
      child=
      child_out=
      trap - HUP TERM INT
      attach_and_wait "$HEALTHY_PID"
    fi
    report_healthy
    stand_down_unconfirmed_watcher
    rm -f "$child_out" 2>/dev/null || true
    exit 0
  fi
  if [ "$child_done" -eq 0 ] && ! fm_pid_alive "$child"; then
    child_done=1
    # A detached watcher's exit status is not reachable, so its own printed wake
    # line is the evidence that it exited on a wake rather than gave up.
    if watch_output_has_wake "$child_out"; then
      print_watch_output "$child_out"
      rm -f "$child_out" 2>/dev/null || true
      exit 0
    fi
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

trap - HUP TERM INT
echo "watcher: FAILED - no live watcher with a fresh beacon"
print_watch_diagnostics "$child_out"
stand_down_unconfirmed_watcher
rm -f "$child_out" 2>/dev/null || true
exit 1
