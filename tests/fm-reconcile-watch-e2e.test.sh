#!/usr/bin/env bash
# Controlled end-to-end canary for the running durable watcher owner.
# It proves working -> parked, stopped-without-done, OAuth predicate completion,
# unregistered-wait failure, positive-busy suppression, and an idle harness with
# an advancing owned command within the poll cycle, not heartbeat/stale cadence.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-reconcile-lib.sh
. "$ROOT/bin/fm-reconcile-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
fm_test_tmproot TMP_ROOT fm-reconcile-watch-e2e
ACTIVE_PIDS=()

cleanup_canary() {
  local pid
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_canary EXIT

start_watch() {  # <dir> <out>
  local dir=$1 out=$2 state="$1/state" fakebin="$1/fakebin" live="$1/live" window="session:fm-task"
  PATH="$fakebin:$PATH" \
    FM_FAKE_TMUX_WINDOW="$window" \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE_FILE="$live" \
    FM_POLL=1 \
    FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 \
    FM_CHECK_TIMEOUT="${FM_CANARY_CHECK_TIMEOUT:-30}" \
    FM_RECONCILE_TASK_TIMEOUT="${FM_CANARY_RECONCILE_TIMEOUT:-}" \
    FM_STALE_ESCALATE_SECS="${FM_CANARY_STALE_ESCALATE:-999999}" \
    "$WATCH" > "$out" 2>&1 &
  CANARY_PID=$!
  ACTIVE_PIDS+=("$CANARY_PID")
}

make_canary() {  # <name> <status-line>
  local name=$1 status=$2 dir state fakebin wt status_sig turn_sig
  dir=$(make_case "$name")
  state="$dir/state"
  fakebin="$dir/fakebin"
  wt="$dir/worktree"
  mkdir -p "$wt" "$dir/project"
  fm_write_meta "$state/task.meta" \
    'window=session:fm-task' \
    "worktree=$wt" \
    "project=$dir/project" \
    'kind=ship'
  printf '%s\n' "$status" > "$state/task.status"
  : > "$state/task.turn-ended"
  if [ "$(uname)" = Darwin ]; then
    status_sig=$(stat -f '%z:%Fm' "$state/task.status")
    turn_sig=$(stat -f '%z:%Fm' "$state/task.turn-ended")
  else
    status_sig=$(stat -c '%s:%Y' "$state/task.status")
    turn_sig=$(stat -c '%s:%Y' "$state/task.turn-ended")
  fi
  printf '%s' "$status_sig" > "$state/.seen-task_status"
  printf '%s' "$turn_sig" > "$state/.seen-task_turn-ended"
  printf 'idle pane\n' > "$dir/pane.txt"
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
cat "$FM_FAKE_CREW_STATE_FILE"
SH
  chmod +x "$fakebin/fm-crew-state.sh"
  printf '%s\n' "$dir"
}

wait_for_record_state() {  # <record> <state>
  local record=$1 expected=$2 i=0
  while [ "$i" -lt 100 ]; do
    if [ -f "$record" ] && grep -qxF "state=$expected" "$record"; then return 0; fi
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

wait_for_record_source() {  # <record> <source>
  local record=$1 expected=$2 i=0
  while [ "$i" -lt 100 ]; do
    if [ -f "$record" ] && grep -qxF "source=$expected" "$record"; then return 0; fi
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

wait_for_watch_exit() {  # <pid>
  local pid=$1 i=0
  while [ "$i" -lt 100 ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid"; return $?; }
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

stop_watch() {  # <pid>
  local pid=$1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

assert_one_wake() {  # <state> <needle>
  local state=$1 needle=$2 drained count
  drained=$(FM_STATE_OVERRIDE="$state" "$DRAIN")
  count=$(printf '%s\n' "$drained" | awk 'NF { n++ } END { print n + 0 }')
  [ "$count" -eq 1 ] || fail "expected exactly one durable wake, got $count: $drained"
  assert_contains "$drained" "$needle" "durable wake lacked expected reconciled evidence"
}

assert_restart_quiet() {  # <dir>
  local dir=$1 out="$1/restart.out" pid
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  sleep 2
  kill -0 "$pid" 2>/dev/null || fail "unchanged acknowledged state emitted a duplicate after restart: $(cat "$out")"
  stop_watch "$pid"
}

setup_fake_herdr() {  # <dir>
  local dir=$1 fakebin="$1/fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf 'herdr %s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
case "$*" in
  *'status --json'*)
    printf '{"client":{"protocol":16},"server":{"protocol":16,"running":true}}\n'
    ;;
  *'session list --json'*)
    printf '{"sessions":[{"name":"lab","socket_path":"/tmp/fm-fake-herdr.sock"}]}\n'
    ;;
  *'agent get'*)
    state=$(cat "$FM_FAKE_HERDR_AGENT_STATE" 2>/dev/null || printf 'idle')
    printf '{"ok":true,"result":{"agent":{"agent_status":"%s"}}}\n' "$state"
    ;;
  *'pane get'*)
    printf '{"ok":true,"result":{"pane":{"id":"w1:p1"}}}\n'
    ;;
  *'pane read'*)
    composer=$(cat "$FM_FAKE_HERDR_COMPOSER_FILE" 2>/dev/null || true)
    printf '│ %s │\n' "$composer"
    ;;
  *) printf '{"ok":true,"result":{}}\n' ;;
esac
SH
  chmod +x "$fakebin/herdr"
  cat > "$fakebin/herdr-event-reader" <<'SH'
#!/usr/bin/env bash
timeout=${2:-1}
printf 'reader start %s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
printf '@subscribed\n'
i=0
limit=$((timeout * 100))
while [ "$i" -lt "$limit" ]; do
  if mv "$FM_FAKE_HERDR_EVENT_FILE" "$FM_FAKE_HERDR_EVENT_FILE.claim.$$" 2>/dev/null; then
    printf 'reader claimed event\n' >> "$FM_FAKE_HERDR_LOG"
    cat "$FM_FAKE_HERDR_EVENT_FILE.claim.$$"
    rm -f "$FM_FAKE_HERDR_EVENT_FILE.claim.$$"
    exit 0
  fi
  sleep 0.01
  i=$((i + 1))
done
exit 0
SH
  chmod +x "$fakebin/herdr-event-reader"
  printf 'idle\n' > "$dir/herdr-agent-state"
  : > "$dir/herdr-composer"
  : > "$dir/herdr.log"
}

queue_herdr_events() {  # <dir> <record-lines>
  local dir=$1 records=$2 tmp="$1/herdr-events.tmp.$$"
  printf '%s\n' "$records" > "$tmp"
  mv "$tmp" "$dir/herdr-events"
}

wait_for_probe_armed() {  # <record>
  local record=$1 i=0
  while [ "$i" -lt 100 ]; do
    if [ "$(fm_reconcile_record_value "$record" background_probe_armed)" = 1 ]; then return 0; fi
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

wait_for_pulse_state() {  # <pulse> <state>
  local pulse=$1 expected=$2 i=0
  while [ "$i" -lt 200 ]; do
    if [ "$(fm_reconcile_record_value "$pulse" state)" = "$expected" ]; then return 0; fi
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

pulse_state_dump() {  # <pulse> <label>
  local pulse=$1 label=$2
  printf '%s: state=%s reason=%s\n' "$label" \
    "$(fm_reconcile_record_value "$pulse" state)" \
    "$(fm_reconcile_record_value "$pulse" state_reason)"
  [ -f "$pulse" ] && cat "$pulse" || printf '%s: pulse file absent\n' "$label"
}

start_canary_probe_child() {  # <dir> <state> <worktree> <wait-bin>
  local dir=$1 state=$2 wt=$3 wait_bin=$4 control="$1/probe-control" i=0
  mkdir -p "$control"
  cat > "$control/child.sh" <<'SH'
#!/usr/bin/env bash
set -u
cd "$FM_PROBE_WORKTREE" || exit 1
printf '%s\n' "$$" > "$FM_PROBE_CONTROL/ready"
while :; do
  if mv "$FM_PROBE_CONTROL/request" "$FM_PROBE_CONTROL/request.claim" 2>/dev/null; then
    FM_STATE_OVERRIDE="$FM_PROBE_STATE" "$FM_PROBE_WAIT" arm-background-probe-pulse task "$$" \
      > "$FM_PROBE_CONTROL/out.tmp" 2> "$FM_PROBE_CONTROL/err.tmp"
    printf '%s\n' "$?" > "$FM_PROBE_CONTROL/rc.tmp"
    mv "$FM_PROBE_CONTROL/out.tmp" "$FM_PROBE_CONTROL/out"
    mv "$FM_PROBE_CONTROL/err.tmp" "$FM_PROBE_CONTROL/err"
    mv "$FM_PROBE_CONTROL/rc.tmp" "$FM_PROBE_CONTROL/rc"
    rm -f "$FM_PROBE_CONTROL/request.claim"
  fi
  sleep 0.02
done
SH
  chmod +x "$control/child.sh"
  FM_PROBE_WORKTREE="$wt" FM_PROBE_CONTROL="$control" FM_PROBE_STATE="$state" FM_PROBE_WAIT="$wait_bin" \
    "$control/child.sh" &
  CANARY_PROBE_CHILD=$!
  ACTIVE_PIDS+=("$CANARY_PROBE_CHILD")
  while [ ! -e "$control/ready" ] && [ "$i" -lt 100 ]; do sleep 0.02; i=$((i + 1)); done
  [ "$i" -lt 100 ]
}

arm_canary_probe() {  # <dir>
  local control="$1/probe-control" i=0 rc
  rm -f "$control/rc" "$control/out" "$control/err"
  : > "$control/request.tmp"
  mv "$control/request.tmp" "$control/request"
  while [ ! -e "$control/rc" ] && [ "$i" -lt 100 ]; do sleep 0.02; i=$((i + 1)); done
  [ "$i" -lt 100 ] || return 1
  rc=$(cat "$control/rc")
  if [ "$rc" -ne 0 ]; then
    cat "$control/err" >&2
    return 1
  fi
}

test_active_review_parks_without_stale_cadence() {
  local dir state out pid
  dir=$(make_canary parked 'paused: old review head still active')
  state="$dir/state"
  out="$dir/watch.out"
  printf 'state: working · source: run-step · validating (running)\n' > "$dir/live"
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  wait_for_record_state "$state/task.reconciled" working || fail "watcher did not persist the working baseline"
  printf 'state: parked · source: run-step · parked at fix_review: 1 finding(s)\n' > "$dir/live"
  wait_for_watch_exit "$pid" || fail "watcher did not wake for active-review -> parked: $(cat "$out")"
  assert_contains "$(cat "$out")" 'reconciled-transition (working -> parked' "active review canary woke through the wrong path"
  [ -z "$(fm_reconcile_record_value "$state/task.reconciled" notified_action_token)" ] \
    || fail "watcher producer acknowledged the transition before consumer delivery"
  assert_one_wake "$state" 'working -> parked'
  [ -n "$(fm_reconcile_record_value "$state/task.reconciled" notified_action_token)" ] \
    || fail "queue drain did not acknowledge delivered transition"
  assert_restart_quiet "$dir"
  pass "canary: running watcher wakes once for active review -> parked without stale/heartbeat cadence"
}

test_stopped_without_claimed_done_preserves_turn_end_evidence() {
  local dir state out pid
  dir=$(make_canary missing-done 'paused: old head dcd61bf still awaiting review')
  state="$dir/state"
  out="$dir/watch.out"
  printf 'state: working · source: pane · harness busy\n' > "$dir/live"
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  wait_for_record_state "$state/task.reconciled" working || fail "watcher did not persist the working baseline"
  stop_watch "$pid"
  # The real turn-end hook remains the delivery evidence.  It changes while no
  # done append occurs; reconciliation must surface the live stop and record the
  # unchanged one-event sequence rather than repeating the old pause as truth.
  touch "$state/task.turn-ended"
  printf 'state: unknown · source: none · backend target gone: session:fm-task\n' > "$dir/live"
  : > "$out"
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  wait_for_watch_exit "$pid" || fail "watcher did not wake for stopped endpoint without done: $(cat "$out")"
  assert_contains "$(cat "$out")" 'status event sequence 1, last event: paused:' "missing-done wake did not prove the absent claimed event"
  assert_one_wake "$state" 'working -> unknown'
  assert_restart_quiet "$dir"
  pass "canary: delivered turn-end plus absent claimed done surfaces once as working -> stopped"
}

test_oauth_callback_completion_after_park() {
  local dir state out pid predicate token
  dir=$(make_canary oauth 'blocked: awaiting captain OAuth consent')
  state="$dir/state"
  out="$dir/watch.out"
  predicate="$dir/predicate.sh"
  cat > "$predicate" <<'SH'
#!/usr/bin/env bash
[ "$(cat "$FM_OAUTH_STATE")" = complete ] && { printf 'OAuth credential stored\n'; exit 0; }
printf 'callback listener active\n'
exit 1
SH
  chmod +x "$predicate"
  printf 'pending\n' > "$dir/oauth-state"
  fm_write_meta "$state/task.wait" \
    'schema=fm-external-wait.v1' \
    'kind=predicate' \
    'description=xAI OAuth callback' \
    "predicate=$predicate" \
    'registered_at=1'
  printf 'state: working · source: pane · harness busy\n' > "$dir/live"
  export FM_OAUTH_STATE="$dir/oauth-state"
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  wait_for_record_state "$state/task.reconciled" working || fail "watcher did not persist OAuth foreground working state"
  printf 'state: blocked · source: status-log · awaiting captain OAuth consent\n' > "$dir/live"
  wait_for_watch_exit "$pid" || fail "watcher did not surface the foreground park"
  assert_one_wake "$state" 'working -> blocked'

  : > "$out"
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  sleep 2
  kill -0 "$pid" 2>/dev/null || fail "unchanged pending OAuth wait did not stay quiet: $(cat "$out")"
  printf 'complete\n' > "$dir/oauth-state"
  wait_for_watch_exit "$pid" || fail "watcher did not wake when OAuth callback predicate completed: $(cat "$out")"
  assert_contains "$(cat "$out")" 'external-wait-complete' "OAuth completion canary woke through the wrong path"
  assert_one_wake "$state" 'OAuth credential stored'
  assert_restart_quiet "$dir"
  unset FM_OAUTH_STATE
  # Keep shellcheck from mistaking the deliberately parsed persisted token for
  # an unused result in future extensions of this canary.
  token=$(fm_reconcile_record_value "$state/task.reconciled" notified_action_token)
  [ -n "$token" ] || fail "OAuth completion acknowledgement was not persisted"
  pass "canary: running watcher wakes once when a parked OAuth callback completes"
}

test_unmanaged_task_check_has_one_execution_owner() {
  local dir state out pid count
  dir=$(make_canary unmanaged-check-owner 'working: waiting for custom poll')
  state="$dir/state"
  out="$dir/watch.out"
  count="$dir/check-count"
  cat > "$state/task.check.sh" <<'SH'
#!/usr/bin/env bash
n=$(cat "$FM_LEGACY_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((n + 1))" > "$FM_LEGACY_COUNT"
SH
  chmod +x "$state/task.check.sh"
  printf 'state: working · source: pane · harness busy\n' > "$dir/live"
  export FM_LEGACY_COUNT="$count"
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  wait_for_record_state "$state/task.reconciled" working || fail "watcher did not reconcile unmanaged task check fixture"
  sleep 0.25
  [ "$(cat "$count" 2>/dev/null || true)" = 1 ] \
    || { stop_watch "$pid"; fail "unmanaged task check executed more than once in one watcher cycle"; }
  stop_watch "$pid"
  unset FM_LEGACY_COUNT
  pass "canary: unmanaged task checks have one reconciliation owner"
}

test_inflight_blocked_wait_without_observer_fails_loudly() {
  local dir state out pid
  dir=$(make_canary inflight-unregistered 'blocked: callback listener running without registered completion observation')
  state="$dir/state"
  out="$dir/watch.out"
  printf 'state: blocked · source: status-log · callback listener running without registered completion observation\n' > "$dir/live"

  start_watch "$dir" "$out"
  pid=$CANARY_PID
  wait_for_watch_exit "$pid" || fail "watcher did not fail loudly for an in-flight blocked wait omission: $(cat "$out")"
  assert_contains "$(cat "$out")" 'external-wait-unobservable' "blocked omission woke through the wrong path"
  assert_one_wake "$state" 'blocked task has no'
  assert_restart_quiet "$dir"
  pass "canary: running watcher fails loudly once for an existing blocked wait with no observer"
}

test_unchanged_pane_with_positive_busy_evidence_stays_quiet() {
  local dir state out pid window key pane_hash now
  dir=$(make_canary positive-busy 'working: active edits with a background test')
  state="$dir/state"
  out="$dir/watch.out"
  window='session:fm-task'
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text 'idle pane')
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  now=$(date +%s)
  printf '%s\n' "$((now - 30))" > "$state/.stale-since-$key"
  printf '2\n' > "$state/.wedge-escalations-$key"
  printf 'state: working · source: pane · harness busy with active edits and background test\n' > "$dir/live"

  FM_CANARY_STALE_ESCALATE=1 start_watch "$dir" "$out"
  pid=$CANARY_PID
  sleep 3
  kill -0 "$pid" 2>/dev/null || fail "positive busy evidence did not suppress the stale alarm: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "positive busy evidence still queued a possible-wedge alarm: $(cat "$state/.wake-queue")"
  grep -F 'possible wedge' "$out" >/dev/null && fail "positive busy evidence printed a possible-wedge alarm"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "positive busy revalidation did not clear prior wedge escalation state"
  stop_watch "$pid"
  pass "canary: unchanged pane stays quiet past stale threshold under positive busy evidence"
}

test_idle_harness_with_advancing_owned_command_stays_quiet_then_wakes() {
  local dir state out pid command_pid window key pane_hash now cwd physical_wt i=0
  dir=$(make_canary owned-command 'working: background full suite is advancing')
  state="$dir/state"
  out="$dir/watch.out"
  window='session:fm-task'
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text 'idle pane')
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  now=$(date +%s)
  printf '%s\n' "$((now - 30))" > "$state/.stale-since-$key"
  printf '2\n' > "$state/.wedge-escalations-$key"

  physical_wt=$(cd "$dir/worktree" && pwd -P)
  sh -c 'cd "$1" || exit 1; end=$(( $(date +%s) + 30 )); while [ "$(date +%s)" -lt "$end" ]; do sleep 0.1; done' _ "$dir/worktree" &
  command_pid=$!
  ACTIVE_PIDS+=("$command_pid")
  while [ "$i" -lt 100 ]; do
    cwd=$(fm_reconcile_process_cwd "$command_pid" 2>/dev/null || true)
    fm_reconcile_path_is_within "$cwd" "$physical_wt" && break
    sleep 0.02
    i=$((i + 1))
  done
  [ "$i" -lt 100 ] || fail "owned-command canary process did not enter its task worktree"
  FM_OWNED_COMMAND_PROGRESS_GRACE=2 FM_STATE_OVERRIDE="$state" \
    "$ROOT/bin/fm-external-wait.sh" register-command task "$command_pid" 'background full-suite shell' >/dev/null \
    || fail "owned-command canary registration failed"
  cat > "$dir/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
exec "$FM_REAL_CREW_STATE_BIN" "$@"
SH
  chmod +x "$dir/fakebin/fm-crew-state.sh"
  export FM_REAL_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh"

  FM_CANARY_STALE_ESCALATE=1 start_watch "$dir" "$out"
  pid=$CANARY_PID
  wait_for_record_source "$state/task.reconciled" owned-command \
    || fail "running watcher did not persist the owned-command working source: $(cat "$out")"
  sleep 3
  kill -0 "$pid" 2>/dev/null || fail "idle harness with advancing owned command stale-escalated: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "advancing owned command queued a stale wake: $(cat "$state/.wake-queue")"
  grep -F 'possible wedge' "$out" >/dev/null && fail "advancing owned command printed a possible-wedge alarm"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "owned-command progress did not clear prior wedge escalation state"

  kill "$command_pid" 2>/dev/null || true
  wait "$command_pid" 2>/dev/null || true
  wait_for_watch_exit "$pid" || fail "owned-command completion did not wake the running owner: $(cat "$out")"
  assert_one_wake "$state" 'external-wait-complete'
  assert_restart_quiet "$dir"
  unset FM_REAL_CREW_STATE_BIN
  pass "canary: idle harness plus advancing task-owned command stays quiet, then completion wakes once"
}

test_fleet_reconciliation_observes_tasks_in_one_bounded_batch() {
  local dir state out pid task record lifecycle_generation start elapsed
  dir=$(make_canary parallel-batch 'working: parallel reconciliation baseline')
  state="$dir/state"
  out="$dir/watch.out"
  rm -f "$state/task.meta" "$state/task.status" "$state/task.turn-ended"
  mkdir -p "$dir/live-tasks" "$dir/started"
  for task in task-a task-b task-c; do
    mkdir -p "$dir/project-$task" "$dir/worktree-$task"
    fm_write_meta "$state/$task.meta" \
      "window=session:fm-$task" \
      "worktree=$dir/worktree-$task" \
      "project=$dir/project-$task" \
      'kind=ship'
    lifecycle_generation=$(fm_reconcile_meta_generation "$state/$task.meta") \
      || fail "could not resolve $task lifecycle generation"
    printf 'working: %s baseline\n' "$task" > "$state/$task.status"
    record="$state/$task.reconciled"
    fm_write_meta "$record" \
      'schema=fm-reconciled.v1' \
      "task=$task" \
      "lifecycle_generation=$lifecycle_generation" \
      "endpoint=session:fm-$task" \
      'state=working' \
      'source=pane' \
      'evidence=state: working · source: pane · harness busy' \
      'observed_at=1' \
      'transition_sequence=0' \
      'pending_action_token=' \
      'pending_action_reason=' \
      'notified_action_token='
    printf 'state: working · source: pane · harness busy\n' > "$dir/live-tasks/$task"
  done
  printf 'state: idle · source: pane · foreground turn ended\n' > "$dir/live-tasks/task-c"
  cat > "$dir/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
touch "$FM_PARALLEL_STARTED/$1"
i=0
while [ "$(find "$FM_PARALLEL_STARTED" -type f | wc -l | tr -d '[:space:]')" -lt 3 ] && [ "$i" -lt 100 ]; do
  sleep 0.02
  i=$((i + 1))
done
[ "$i" -lt 100 ] || exit 70
cat "$FM_PARALLEL_LIVE/$1"
SH
  chmod +x "$dir/fakebin/fm-crew-state.sh"
  export FM_PARALLEL_STARTED="$dir/started"
  export FM_PARALLEL_LIVE="$dir/live-tasks"
  start=$(date +%s)
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  wait_for_watch_exit "$pid" || fail "bounded fleet reconciliation did not surface the ready task: $(cat "$out")"
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -le 3 ] || fail "fleet reconciliation serialized task observers (${elapsed}s)"
  assert_contains "$(cat "$out")" 'working -> idle' "parallel fleet batch missed the actionable task"
  assert_one_wake "$state" 'working -> idle'
  unset FM_PARALLEL_STARTED FM_PARALLEL_LIVE
  pass "canary: fleet tasks reconcile concurrently under one bounded observation batch"
}

test_fleet_reconciliation_respects_worker_cap() {
  local dir state out pid task i count
  dir=$(make_canary bounded-pool 'working: bounded pool baseline')
  state="$dir/state"
  out="$dir/watch.out"
  rm -f "$state/task.meta" "$state/task.status" "$state/task.turn-ended"
  mkdir -p "$dir/started"
  for task in task-a task-b task-c task-d; do
    mkdir -p "$dir/project-$task" "$dir/worktree-$task"
    fm_write_meta "$state/$task.meta" \
      "window=session:fm-$task" \
      "worktree=$dir/worktree-$task" \
      "project=$dir/project-$task" \
      'kind=ship'
    printf 'working: %s baseline\n' "$task" > "$state/$task.status"
  done
  cat > "$dir/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
touch "$FM_POOL_STARTED/$1"
while [ ! -e "$FM_POOL_RELEASE" ]; do sleep 0.02; done
printf 'state: working · source: pane · harness busy\n'
SH
  chmod +x "$dir/fakebin/fm-crew-state.sh"
  export FM_POOL_STARTED="$dir/started"
  export FM_POOL_RELEASE="$dir/release"
  export FM_RECONCILE_MAX_WORKERS=2
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  i=0
  while [ "$i" -lt 100 ]; do
    count=$(find "$dir/started" -type f | wc -l | tr -d '[:space:]')
    [ "$count" -ge 2 ] && break
    sleep 0.02
    i=$((i + 1))
  done
  [ "$count" -eq 2 ] || fail "bounded pool did not start its first two workers"
  sleep 0.3
  count=$(find "$dir/started" -type f | wc -l | tr -d '[:space:]')
  [ "$count" -eq 2 ] || fail "worker pool exceeded its configured cap before release: $count"
  : > "$dir/release"
  i=0
  while [ "$i" -lt 100 ]; do
    count=$(find "$dir/started" -type f | wc -l | tr -d '[:space:]')
    [ "$count" -eq 4 ] && break
    sleep 0.02
    i=$((i + 1))
  done
  [ "$count" -eq 4 ] || fail "bounded pool did not eventually observe every task"
  stop_watch "$pid"
  unset FM_POOL_STARTED FM_POOL_RELEASE FM_RECONCILE_MAX_WORKERS
  pass "canary: fleet reconciliation honors the configured worker cap"
}

test_observer_crashes_and_timeouts_fail_loudly() {
  local dir state out pid
  dir=$(make_canary observer-failure 'working: observer failure fixture')
  state="$dir/state"
  out="$dir/watch.out"
  cat > "$dir/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
exit 70
SH
  chmod +x "$dir/fakebin/fm-crew-state.sh"
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  wait_for_watch_exit "$pid" || fail "crashed observer was silently ignored: $(cat "$out")"
  assert_contains "$(cat "$out")" 'observer-failure' "crashed observer woke through the wrong path"
  assert_contains "$(cat "$out")" 'status 70' "crashed observer status was not preserved"
  assert_one_wake "$state" 'observer-failure'

  cat > "$dir/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
sleep 10
printf 'state: working · source: pane · harness busy\n'
SH
  chmod +x "$dir/fakebin/fm-crew-state.sh"
  : > "$out"
  FM_CANARY_RECONCILE_TIMEOUT=1 start_watch "$dir" "$out"
  pid=$CANARY_PID
  wait_for_watch_exit "$pid" || fail "timed-out observer was silently ignored: $(cat "$out")"
  assert_contains "$(cat "$out")" 'observer-failure' "timed-out observer woke through the wrong path"
  assert_contains "$(cat "$out")" 'timed out after 1s' "observer timeout budget was not reported"
  assert_one_wake "$state" 'timed out after 1s'

  cat > "$dir/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: working · source: pane · harness busy\n'
printf 'unexpected extra observer line\n'
SH
  chmod +x "$dir/fakebin/fm-crew-state.sh"
  : > "$out"
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  wait_for_watch_exit "$pid" || fail "malformed live-state output was silently accepted: $(cat "$out")"
  assert_contains "$(cat "$out")" 'observer-failure' "malformed live-state output did not become an observer failure"
  assert_contains "$(cat "$out")" 'malformed live-state output' "malformed live-state failure lost its evidence"
  assert_one_wake "$state" 'malformed live-state output'
  pass "canary: observer crashes, timeouts, and malformed output fail loudly"
}

test_observer_budget_includes_configured_check_timeout() {
  local dir out
  dir=$(make_case observer-budget)
  out=$(FM_STATE_OVERRIDE="$dir/state" FM_CHECK_TIMEOUT=60 FM_RECONCILE_CREW_READ_TIMEOUT=7 bash -c '
    . "$1"
    printf "%s\n" "$RECONCILE_TASK_TIMEOUT"
  ' _ "$WATCH") || fail "could not inspect the watcher observer budget"
  [ "$out" = 67 ] || fail "observer budget $out did not include 7s crew read plus 60s check timeout"
  pass "observer timeout budgets crew-state reads plus configured check execution"
}

test_first_repository_identity_failure_is_delivered() {
  local dir state out pid
  dir=$(make_canary first-identity-failure 'working: identity proof fixture')
  state="$dir/state"
  out="$dir/watch.out"
  rm -rf "$dir/project"
  printf 'state: working · source: pane · harness busy\n' > "$dir/live"
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  wait_for_watch_exit "$pid" || fail "watcher did not deliver the first repository identity failure: $(cat "$out")"
  assert_contains "$(cat "$out")" 'observer-failure (repository identity cannot be resolved' \
    "first repository identity failure was rejected as unproven ordinary state"
  assert_one_wake "$state" 'repository identity cannot be resolved'
  assert_restart_quiet "$dir"
  pass "canary: first repository identity proof failures deliver while ordinary unproven actions stay closed"
}

test_later_worker_failure_is_recorded_after_first_action_selection() {
  local dir state out pid task record lifecycle_generation
  dir=$(make_canary later-worker-failure 'working: batch failure fixture')
  state="$dir/state"
  out="$dir/watch.out"
  rm -f "$state/task.meta" "$state/task.status" "$state/task.turn-ended"
  for task in task-a task-b; do
    mkdir -p "$dir/project-$task" "$dir/worktree-$task"
    fm_write_meta "$state/$task.meta" \
      "window=session:fm-$task" \
      "worktree=$dir/worktree-$task" \
      "project=$dir/project-$task" \
      'kind=ship'
    printf 'working: %s baseline\n' "$task" > "$state/$task.status"
  done
  lifecycle_generation=$(fm_reconcile_meta_generation "$state/task-a.meta") \
    || fail "could not resolve task-a lifecycle generation"
  record="$state/task-a.reconciled"
  fm_write_meta "$record" \
    'schema=fm-reconciled.v1' \
    'task=task-a' \
    "lifecycle_generation=$lifecycle_generation" \
    'endpoint=session:fm-task-a' \
    'state=working' \
    'source=pane' \
    'evidence=state: working · source: pane · harness busy' \
    'observed_at=1' \
    'transition_sequence=0' \
    'pending_action_token=' \
    'notified_action_token='
  cat > "$dir/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  task-a) printf 'state: idle · source: pane · foreground ended\n' ;;
  task-b) exit 70 ;;
esac
SH
  chmod +x "$dir/fakebin/fm-crew-state.sh"
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  wait_for_watch_exit "$pid" || fail "first batch action did not wake: $(cat "$out")"
  assert_contains "$(cat "$out")" 'working -> idle' "first batch action was not selected"
  [ "$(fm_reconcile_record_value "$state/task-b.reconciled" observer_state)" = failed ] \
    || fail "later worker failure was not persisted after selecting the first action"
  assert_contains "$(fm_reconcile_record_value "$state/task-b.reconciled" observer_evidence)" 'status 70' \
    "later worker failure lost its exit evidence"
  assert_one_wake "$state" 'working -> idle'
  pass "canary: every batch worker failure is recorded after first-action selection"
}

test_watcher_exit_reaps_reconciliation_workers() {
  local dir state out pid observer_pid i=0 leftovers
  dir=$(make_canary worker-cleanup 'working: watcher cleanup fixture')
  state="$dir/state"
  out="$dir/watch.out"
  cat > "$dir/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_WORKER_PID_FILE"
sleep 30
printf 'state: working · source: pane · harness busy\n'
SH
  chmod +x "$dir/fakebin/fm-crew-state.sh"
  export FM_WORKER_PID_FILE="$dir/observer.pid"
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  while [ ! -s "$dir/observer.pid" ] && [ "$i" -lt 100 ]; do sleep 0.02; i=$((i + 1)); done
  [ "$i" -lt 100 ] || fail "reconciliation worker did not start"
  observer_pid=$(cat "$dir/observer.pid")
  stop_watch "$pid"
  i=0
  while kill -0 "$observer_pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.02; i=$((i + 1)); done
  kill -0 "$observer_pid" 2>/dev/null && fail "reconciliation worker survived watcher exit"
  leftovers=$(find "$state" -maxdepth 1 -name '.reconcile-cycle.*' -print)
  [ -z "$leftovers" ] || fail "watcher exit left reconciliation batch state behind: $leftovers"
  unset FM_WORKER_PID_FILE
  pass "canary: watcher exit reaps reconciliation workers and batch state"
}

test_herdr_push_probe_pulses_are_owned_across_restart() {
  local generic generic_state generic_out generic_pid predicate wait_bin
  local dir state out pid wt child drained invalidation
  wait_bin="$ROOT/bin/fm-external-wait.sh"

  generic=$(make_canary herdr-generic 'paused: waiting on an observable upstream gate')
  generic_state="$generic/state"
  generic_out="$generic/watch.out"
  setup_fake_herdr "$generic"
  printf 'state: paused · source: status-log · waiting on an observable upstream gate\n' > "$generic/live"
  fm_write_meta "$generic_state/task.meta" \
    'window=lab:w1:p1' \
    'backend=herdr' \
    "worktree=$generic/worktree" \
    "project=$generic/project" \
    'kind=ship'
  predicate="$generic/pending.sh"
  cat > "$predicate" <<'SH'
#!/usr/bin/env bash
printf 'upstream gate pending\n'
exit 1
SH
  chmod +x "$predicate"
  FM_STATE_OVERRIDE="$generic_state" "$wait_bin" register-predicate task "$predicate" 'upstream gate' >/dev/null \
    || fail "could not register the generic paused canary predicate"
  export FM_BACKEND_HERDR_EVENTS_FORCE=1
  export FM_BACKEND_HERDR_EVENT_READER="$generic/fakebin/herdr-event-reader"
  export FM_FAKE_HERDR_EVENT_FILE="$generic/herdr-events"
  export FM_FAKE_HERDR_AGENT_STATE="$generic/herdr-agent-state"
  export FM_FAKE_HERDR_COMPOSER_FILE="$generic/herdr-composer"
  export FM_FAKE_HERDR_LOG="$generic/herdr.log"
  start_watch "$generic" "$generic_out"
  generic_pid=$CANARY_PID
  wait_for_record_state "$generic_state/task.reconciled" paused || fail "generic Herdr canary did not persist its pause"
  queue_herdr_events "$generic" $'w1:p1\tw1\tblocked\tgrok'
  wait_for_watch_exit "$generic_pid" \
    || fail "ordinary paused Herdr activity did not wake: $(cat "$generic_out"); transport: $(cat "$generic/herdr.log"); queued: $(cat "$generic/herdr-events" 2>/dev/null || true)"
  assert_one_wake "$generic_state" 'herdr: agent blocked'
  assert_restart_quiet "$generic"

  dir=$(make_canary herdr-probe 'paused: supervising an owned corpus probe')
  state="$dir/state"
  out="$dir/watch.out"
  wt="$dir/worktree"
  setup_fake_herdr "$dir"
  printf 'state: paused · source: status-log · supervising an owned corpus probe\n' > "$dir/live"
  fm_write_meta "$state/task.meta" \
    'window=lab:w1:p1' \
    'backend=herdr' \
    "worktree=$wt" \
    "project=$dir/project" \
    'kind=ship'
  predicate="$dir/probe-predicate.sh"
  cat > "$predicate" <<'SH'
#!/usr/bin/env bash
printf 'corpus ledger pending\n'
exit 1
SH
  chmod +x "$predicate"
  start_canary_probe_child "$dir" "$state" "$wt" "$wait_bin" \
    || fail "controlled Herdr background-probe child did not start"
  child=$CANARY_PROBE_CHILD
  FM_STATE_OVERRIDE="$state" "$wait_bin" register-background-probe task "$child" "$predicate" 'corpus ledger' >/dev/null \
    || fail "could not register the controlled Herdr background probe"
  export FM_BACKEND_HERDR_EVENT_READER="$dir/fakebin/herdr-event-reader"
  export FM_FAKE_HERDR_EVENT_FILE="$dir/herdr-events"
  export FM_FAKE_HERDR_AGENT_STATE="$dir/herdr-agent-state"
  export FM_FAKE_HERDR_COMPOSER_FILE="$dir/herdr-composer"
  export FM_FAKE_HERDR_LOG="$dir/herdr.log"
  export FM_CANARY_STALE_ESCALATE=2
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  wait_for_probe_armed "$state/task.reconciled" || fail "controlled Herdr background probe did not arm"

  if FM_STATE_OVERRIDE="$state" "$wait_bin" arm-background-probe-pulse task "$child" >/dev/null 2>&1; then
    fail "the watcher canary driver authenticated with a caller-supplied child pid"
  fi
  arm_canary_probe "$dir" \
    || fail "could not arm controlled Herdr pulse one"
  queue_herdr_events "$dir" $'w1:p1\tw1\tworking\tgrok\nw1:p1\tw1\tblocked\tgrok'
  wait_for_pulse_state "$state/task.probe-pulse" consumed || fail "controlled Herdr pulse one was not consumed"
  kill -0 "$pid" 2>/dev/null || fail "controlled Herdr pulse one woke the watcher: $(cat "$out")"
  [ ! -e "$state/.wake-queue" ] || fail "controlled Herdr pulse one enqueued a captain wake"
  stop_watch "$pid"

  : > "$out"
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  arm_canary_probe "$dir" \
    || fail "could not arm controlled Herdr pulse two after restart"
  queue_herdr_events "$dir" $'w1:p1\tw1\tworking\tgrok\nw1:p1\tw1\tblocked\tgrok'
  wait_for_pulse_state "$state/task.probe-pulse" consumed || fail "controlled Herdr pulse two was not consumed"
  sleep 3
  kill -0 "$pid" 2>/dev/null || fail "owned Herdr pulses tripped the stale-wedge path: $(cat "$out")"
  [ ! -e "$state/.wake-queue" ] || fail "owned Herdr pulses produced a stale-wedge wake"

  arm_canary_probe "$dir" || fail "could not arm the transient-composer Herdr pulse"
  queue_herdr_events "$dir" $'@composer\tw1:p1\tw1\t"│ captain draft │"'
  : > "$dir/herdr-composer"
  wait_for_watch_exit "$pid" || fail "transient composer input during a probe pulse did not wake: $(cat "$out")"
  wait_for_pulse_state "$state/task.probe-pulse" invalidated \
    || fail "transient composer input did not durably invalidate its pulse"
  assert_one_wake "$state" 'background-probe-invalidated'
  assert_restart_quiet "$dir"

  FM_STATE_OVERRIDE="$state" "$wait_bin" register-background-probe task "$child" "$predicate" 'corpus ledger' >/dev/null \
    || fail "could not replace the pending-composer invalidation"
  : > "$out"
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  wait_for_probe_armed "$state/task.reconciled" || fail "non-probe Herdr registration did not arm"
  queue_herdr_events "$dir" $'w1:p1\tw1\tworking\tgrok\nw1:p1\tw1\tblocked\tgrok'
  wait_for_watch_exit "$pid" \
    || fail "unowned Herdr activity while armed did not wake: $(cat "$out")"
  assert_contains "$(cat "$out")" 'background-probe-invalidated' "unowned Herdr activity used the wrong wake path"
  drained=$(FM_STATE_OVERRIDE="$state" "$DRAIN")
  [ "$(printf '%s\n' "$drained" | awk 'NF { n++ } END { print n + 0 }')" -eq 1 ] \
    || fail "unowned Herdr activity did not wake exactly once: $drained"
  assert_contains "$drained" 'background-probe-invalidated' "unowned Herdr activity lost its invalidation evidence"
  assert_restart_quiet "$dir"

  FM_STATE_OVERRIDE="$state" "$wait_bin" register-background-probe task "$child" "$predicate" 'corpus ledger' >/dev/null \
    || fail "could not replace the invalidated Herdr registration"
  : > "$out"
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  wait_for_probe_armed "$state/task.reconciled" || fail "replacement Herdr registration did not arm"
  arm_canary_probe "$dir" || fail "could not arm the predicate-failure Herdr pulse"
  cat > "$predicate" <<'SH'
#!/usr/bin/env bash
printf 'corpus predicate failed\n'
exit 2
SH
  chmod +x "$predicate"
  wait_for_watch_exit "$pid" || fail "background-probe predicate failure did not wake: $(cat "$out")"
  assert_one_wake "$state" 'background-probe-invalidated'
  assert_restart_quiet "$dir"

  cat > "$predicate" <<'SH'
#!/usr/bin/env bash
printf 'corpus ledger pending\n'
exit 1
SH
  chmod +x "$predicate"
  # The earlier pulse-ownership steps need a short stale escalate (2s) to prove
  # owned pulses do not wedge. That same short window races the observer-failure
  # step on loaded CI runners: a paused recheck can exit the watcher before
  # reconcile_cycle records observer-failure and invalidates the pulse. Raise the
  # threshold for the remaining fail-closed steps so only observer/probe paths wake.
  export FM_CANARY_STALE_ESCALATE=999999
  FM_STATE_OVERRIDE="$state" "$wait_bin" register-background-probe task "$child" "$predicate" 'corpus ledger' >/dev/null \
    || fail "could not register the observer-failure Herdr canary"
  : > "$out"
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  wait_for_probe_armed "$state/task.reconciled" || fail "observer-failure Herdr registration did not arm"
  arm_canary_probe "$dir" || fail "could not arm the observer-failure Herdr pulse"
  printf 'malformed observer result\n' > "$dir/live"
  wait_for_watch_exit "$pid" || fail "observer failure during an armed pulse did not wake: $(cat "$out")"
  assert_contains "$(cat "$out")" 'observer-failure' \
    "armed-pulse observer failure woke without observer-failure evidence: $(cat "$out")"
  wait_for_pulse_state "$state/task.probe-pulse" invalidated \
    || fail "observer failure did not invalidate the armed pulse ($(pulse_state_dump "$state/task.probe-pulse" pulse); out=$(cat "$out"); reconciled armed=$(fm_reconcile_record_value "$state/task.reconciled" background_probe_armed) reason=$(fm_reconcile_record_value "$state/task.reconciled" background_probe_invalidation_reason))"
  assert_one_wake "$state" 'observer-failure'
  printf 'state: paused · source: status-log · supervising an owned corpus probe\n' > "$dir/live"
  assert_restart_quiet "$dir"

  FM_STATE_OVERRIDE="$state" "$wait_bin" register-background-probe task "$child" "$predicate" 'corpus ledger' >/dev/null \
    || fail "could not register the crash-replay Herdr canary"
  : > "$out"
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  wait_for_probe_armed "$state/task.reconciled" || fail "crash-replay Herdr registration did not arm"
  arm_canary_probe "$dir" || fail "could not arm the crash-replay Herdr pulse"
  stop_watch "$pid"
  invalidation=$(fm_reconcile_background_probe_invalidate "$state" task 'simulated crash after durable invalidation commit') \
    || fail "could not persist the crash-replay invalidation"
  assert_contains "$invalidation" 'background-probe-invalidated' "crash seam did not persist an action"
  fm_reconcile_background_probe_pulse_set_state "$state/task.probe-pulse" armed \
    || fail "could not recreate the post-commit crash seam"
  : > "$out"
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  wait_for_watch_exit "$pid" || fail "watcher did not replay the committed probe invalidation: $(cat "$out")"
  wait_for_pulse_state "$state/task.probe-pulse" invalidated \
    || fail "crash replay left the secondary pulse armed"
  assert_one_wake "$state" 'background-probe-invalidated'
  assert_restart_quiet "$dir"

  FM_STATE_OVERRIDE="$state" "$wait_bin" register-background-probe task "$child" "$predicate" 'corpus ledger' >/dev/null \
    || fail "could not register the child-failure Herdr canary"
  : > "$out"
  start_watch "$dir" "$out"
  pid=$CANARY_PID
  wait_for_probe_armed "$state/task.reconciled" || fail "child-failure Herdr registration did not arm"
  arm_canary_probe "$dir" || fail "could not arm the child-failure Herdr pulse"
  kill "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  wait_for_watch_exit "$pid" || fail "background-probe child failure did not wake: $(cat "$out")"
  assert_one_wake "$state" 'background-probe-invalidated'
  assert_restart_quiet "$dir"

  unset FM_BACKEND_HERDR_EVENTS_FORCE FM_BACKEND_HERDR_EVENT_READER FM_FAKE_HERDR_EVENT_FILE
  unset FM_FAKE_HERDR_AGENT_STATE FM_FAKE_HERDR_COMPOSER_FILE FM_FAKE_HERDR_LOG FM_CANARY_STALE_ESCALATE
  pass "canary: real watcher owns Herdr probe pulses across restart and fails closed once"
}

test_active_review_parks_without_stale_cadence
test_stopped_without_claimed_done_preserves_turn_end_evidence
test_oauth_callback_completion_after_park
test_unmanaged_task_check_has_one_execution_owner
test_inflight_blocked_wait_without_observer_fails_loudly
test_unchanged_pane_with_positive_busy_evidence_stays_quiet
test_idle_harness_with_advancing_owned_command_stays_quiet_then_wakes
test_fleet_reconciliation_observes_tasks_in_one_bounded_batch
test_fleet_reconciliation_respects_worker_cap
test_observer_crashes_and_timeouts_fail_loudly
test_observer_budget_includes_configured_check_timeout
test_later_worker_failure_is_recorded_after_first_action_selection
test_first_repository_identity_failure_is_delivered
test_watcher_exit_reaps_reconciliation_workers
test_herdr_push_probe_pulses_are_owned_across_restart

echo "# fm-reconcile-watch-e2e.test.sh: all assertions passed"
