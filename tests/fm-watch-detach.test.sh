#!/usr/bin/env bash
# tests/fm-watch-detach.test.sh - the supervision watcher must outlive the
# harness task that launched it, its absence must be provable from durable state
# alone, and re-arming after that death must never leave two watchers.
#
# These are process-lifetime invariants, so they run real processes: the failure
# they guard against (a killed launcher silently taking supervision down with it)
# is invisible to any mock.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
GUARD="$ROOT/bin/fm-guard.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"

fm_test_tmproot TMP_ROOT fm-watch-detach-tests

# Watcher processes this suite created, torn down on exit. Tracked by exact pid:
# every firstmate home runs the same fm-watch.sh, so anything that reached for a
# name pattern here would sweep sibling homes' watchers too.
SPAWNED_WATCHERS=
fm_detach_test_cleanup() {
  local pid
  for pid in $SPAWNED_WATCHERS; do
    kill -KILL "$pid" 2>/dev/null || true
  done
}
fm_test_add_cleanup fm_detach_test_cleanup

# Replicate the measured harness stop: enumerate the launcher's DESCENDANT TREE
# at kill time and signal every process in it.
# Measured on macOS (Darwin 27.0.0) on 2026-07-25 and recorded in
# docs/turnend-guard.md ("Detached supervision watcher"): a child in its own
# process group died, a child in its own session died, and only a process that
# had been reparented off the launcher survived. Signalling a process group here
# instead would be a WEAKER kill than the real one, and a watcher that merely
# called setsid would pass a test it fails in production.
harness_tree_kill() {  # <root-pid> <signal>
  local root_pid=$1 sig=$2 frontier next pid child victims=
  frontier=$root_pid
  while [ -n "$frontier" ]; do
    next=
    for pid in $frontier; do
      victims="$victims $pid"
      for child in $(pgrep -P "$pid" 2>/dev/null || true); do
        next="$next $child"
      done
    done
    frontier=$next
  done
  for pid in $victims; do
    kill -"$sig" "$pid" 2>/dev/null || true
  done
}

# Live watcher pids belonging to THIS checkout. Scoped to the absolute
# fm-watch.sh path, which no sibling firstmate home shares, so the count can
# never be inflated or satisfied by another home's watcher.
watcher_pids_now() {
  pgrep -f "$WATCH" 2>/dev/null | sort
}

# Watcher pids that appeared since <snapshot> and are still alive.
new_live_watchers() {  # <snapshot>
  local before=$1 pid out=
  for pid in $(watcher_pids_now); do
    case " $before " in
      *" $pid "*) continue ;;
    esac
    is_live_non_zombie "$pid" && out="$out $pid"
  done
  printf '%s\n' "${out# }"
}

wait_for_line() {  # <file> <fixed-substring> [tries]
  local file=$1 needle=$2 tries=${3:-100} i=0
  while [ "$i" -lt "$tries" ]; do
    grep -qF "$needle" "$file" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# --- AC-1: the watcher outlives the harness task that launched it ------------

test_watcher_survives_harness_kill_of_launcher() {
  # Anti-vacuity: a surviving PID is not enough - a wedged watcher keeps its pid
  # while supervising nothing. So the probe deletes state/.last-watcher-beat
  # after the kill and requires the watcher to RECREATE it, which only a watcher
  # still running its poll loop can do. The case also asserts the launcher
  # genuinely died, otherwise "the watcher survived" proves nothing at all.
  local sig dir state fakebin armout armpid watcher_pid before survivors i
  for sig in TERM HUP; do
    dir=$(make_case "survive-$sig")
    state="$dir/state"
    fakebin="$dir/fakebin"
    armout="$dir/arm.out"
    before=$(watcher_pids_now | tr '\n' ' ')

    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
    armpid=$!
    wait_for_line "$armout" 'watcher: started pid=' \
      || fail "arm ($sig) never confirmed a started watcher: $(cat "$armout")"
    watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    [ -n "$watcher_pid" ] || fail "arm ($sig) left no watcher pid in the lock"
    SPAWNED_WATCHERS="$SPAWNED_WATCHERS $watcher_pid"
    is_live_non_zombie "$watcher_pid" || fail "arm ($sig) reported a watcher that is not alive"

    harness_tree_kill "$armpid" "$sig"
    wait_for_exit "$armpid" 80
    is_live_non_zombie "$armpid" && fail "harness-style $sig did not kill the launching task"

    rm -f "$state/.last-watcher-beat"
    i=0
    while [ "$i" -lt 100 ] && [ ! -e "$state/.last-watcher-beat" ]; do
      sleep 0.1
      i=$((i + 1))
    done
    is_live_non_zombie "$watcher_pid" \
      || fail "harness-style $sig of the launching task killed the watcher (pid $watcher_pid)"
    [ -e "$state/.last-watcher-beat" ] \
      || fail "watcher survived $sig as a pid but stopped freshening its beacon"

    survivors=$(new_live_watchers "$before")
    [ "$survivors" = "$watcher_pid" ] \
      || fail "expected exactly the original watcher alive after $sig, got '$survivors'"
    kill -TERM "$watcher_pid" 2>/dev/null || true
  done
  pass "watcher survives a harness-style kill of its launching task and keeps freshening the beacon"
}

# --- AC-2: death and wedge are provable from durable state alone -------------

test_guard_alarms_on_provably_dead_watcher() {
  # Anti-vacuity: the beacon is deliberately FRESH. A guard that reasons only
  # from beacon age stays quiet here for the whole grace window even though the
  # lock already proves the watcher is gone, so this cannot pass by accident.
  # The healthy control below fails any guard that just alarms unconditionally.
  local dir state err gone live identity
  dir=$(make_case guard-dead-watcher)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  gone=$(dead_pid)
  mkdir "$state/.watch.lock"
  printf '%s\n' "$gone" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' 'watcher identity recorded before it died' > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"

  FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 \
    "$GUARD" 2> "$err" >/dev/null || fail "guard failed on a dead-watcher lock"
  grep -qF 'WATCHER DEAD' "$err" \
    || fail "guard stayed silent on a provably dead watcher behind a fresh beacon: $(cat "$err")"
  grep -qF "pid $gone" "$err" || fail "dead-watcher banner did not name the dead pid: $(cat "$err")"
  grep -qF '1 task(s) in flight' "$err" || fail "dead-watcher banner missing the in-flight count"

  # Healthy control: same fixture, but the lock names a live, identity-matched
  # process and the beacon is fresh. Total silence.
  dir=$(make_case guard-live-watcher)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  sleep 300 &
  live=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live") \
    || fail "could not identify the live stand-in watcher"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 \
    "$GUARD" 2> "$err" >/dev/null || fail "guard failed on a healthy watcher lock"
  [ ! -s "$err" ] || fail "guard alarmed on a healthy live watcher: $(cat "$err")"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "guard proves a dead watcher from the lock alone, with no kill notification and no grace wait"
}

test_guard_alarms_on_wedged_watcher() {
  # A wedged watcher is the case a pid-liveness check cannot see: the process is
  # alive and identity-matched, but its beacon stopped advancing. It must be
  # named as wedged (not as merely absent), because a plain re-arm cannot
  # displace a live lock holder - only --restart can.
  # Anti-vacuity: the same live holder with a FRESH beacon must stay silent, so
  # the alarm cannot come from the fixture's mere existence.
  local dir state err live identity
  dir=$(make_case guard-wedged-watcher)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  sleep 300 &
  live=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live") \
    || fail "could not identify the wedged stand-in watcher"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch -t 200001010000 "$state/.last-watcher-beat"

  FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 \
    "$GUARD" 2> "$err" >/dev/null || fail "guard failed on a wedged watcher lock"
  grep -qF 'WATCHER WEDGED' "$err" \
    || fail "guard did not identify a live-but-not-beating watcher as wedged: $(cat "$err")"
  grep -qF "pid $live" "$err" || fail "wedged banner did not name the wedged pid: $(cat "$err")"
  ! grep -qF 'WATCHER DEAD' "$err" || fail "guard called a live wedged watcher dead: $(cat "$err")"
  grep -qF -- '--restart' "$err" \
    || fail "wedged banner did not give the only repair that can displace a live holder: $(cat "$err")"

  # Anti-vacuity control: refresh the beacon, same live holder, expect silence.
  touch "$state/.last-watcher-beat"
  FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 \
    "$GUARD" 2> "$err" >/dev/null || fail "guard failed on the refreshed-beacon control"
  [ ! -s "$err" ] || fail "guard still alarmed once the same watcher's beacon was fresh: $(cat "$err")"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "guard names a live-but-wedged watcher from durable state and points at the restart repair"
}

# --- AC-3: re-arming after a launcher death stays a singleton ----------------

test_rearm_after_launcher_death_adopts_the_orphan() {
  # Anti-vacuity: "one watcher" is not enough on its own - a re-arm that failed
  # outright would also leave one. So this asserts the survivor is the SAME pid
  # as before the kill, that the re-arm reported attach rather than started or
  # FAILED, and that the orphan's ownership record was re-pointed at the new
  # arm, which is what the turn-end guard reads.
  local dir state fakebin armout armout2 armpid armpid2 watcher_pid before survivors owner_pid
  dir=$(make_case rearm-after-death)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  armout2="$dir/arm2.out"
  before=$(watcher_pids_now | tr '\n' ' ')

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for_line "$armout" 'watcher: started pid=' \
    || fail "arm never confirmed a started watcher: $(cat "$armout")"
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$watcher_pid" ] || fail "arm left no watcher pid in the lock"
  SPAWNED_WATCHERS="$SPAWNED_WATCHERS $watcher_pid"

  harness_tree_kill "$armpid" TERM
  wait_for_exit "$armpid" 80
  is_live_non_zombie "$watcher_pid" || fail "watcher did not survive the launcher kill, so re-arm has nothing to adopt"

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout2" &
  armpid2=$!
  wait_for_line "$armout2" "watcher: attached pid=$watcher_pid" \
    || fail "re-arm did not adopt the orphaned watcher: $(cat "$armout2")"
  ! grep -qF 'watcher: started' "$armout2" || fail "re-arm started a second watcher behind the orphan: $(cat "$armout2")"
  ! grep -qF 'watcher: FAILED' "$armout2" || fail "re-arm reported FAILED against a live orphan: $(cat "$armout2")"

  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$watcher_pid" ] \
    || fail "re-arm displaced the orphan's lock instead of adopting it"
  survivors=$(new_live_watchers "$before")
  [ "$survivors" = "$watcher_pid" ] \
    || fail "expected exactly one live watcher for this home after re-arm, got '$survivors'"
  owner_pid=$(cat "$state/.watch.lock/owner-pid" 2>/dev/null || true)
  [ "$owner_pid" = "$armpid2" ] \
    || fail "re-arm did not re-point the orphan's ownership record at itself (owner-pid '$owner_pid', arm $armpid2)"

  kill "$armpid2" 2>/dev/null || true
  wait "$armpid2" 2>/dev/null || true
  kill -TERM "$watcher_pid" 2>/dev/null || true
  pass "re-arm after a launcher death adopts the surviving watcher instead of racing a second one"
}

test_watcher_survives_harness_kill_of_launcher
test_guard_alarms_on_provably_dead_watcher
test_guard_alarms_on_wedged_watcher
test_rearm_after_launcher_death_adopts_the_orphan
