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
TMP_ROOT=$(fm_test_tmproot fm-reconcile-watch-e2e)
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
    FM_RECONCILE_TASK_TIMEOUT="${FM_CANARY_RECONCILE_TIMEOUT:-35}" \
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
  local dir state out pid task record start elapsed
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
    printf 'working: %s baseline\n' "$task" > "$state/$task.status"
    record="$state/$task.reconciled"
    fm_write_meta "$record" \
      'schema=fm-reconciled.v1' \
      "task=$task" \
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
  [ "$elapsed" -lt 3 ] || fail "fleet reconciliation serialized task observers (${elapsed}s)"
  assert_contains "$(cat "$out")" 'working -> idle' "parallel fleet batch missed the actionable task"
  assert_one_wake "$state" 'working -> idle'
  unset FM_PARALLEL_STARTED FM_PARALLEL_LIVE
  pass "canary: fleet tasks reconcile concurrently under one bounded observation batch"
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
  local dir state out pid task record
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
  record="$state/task-a.reconciled"
  fm_write_meta "$record" \
    'schema=fm-reconciled.v1' \
    'task=task-a' \
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

test_active_review_parks_without_stale_cadence
test_stopped_without_claimed_done_preserves_turn_end_evidence
test_oauth_callback_completion_after_park
test_inflight_blocked_wait_without_observer_fails_loudly
test_unchanged_pane_with_positive_busy_evidence_stays_quiet
test_idle_harness_with_advancing_owned_command_stays_quiet_then_wakes
test_fleet_reconciliation_observes_tasks_in_one_bounded_batch
test_observer_crashes_and_timeouts_fail_loudly
test_later_worker_failure_is_recorded_after_first_action_selection
test_first_repository_identity_failure_is_delivered
test_watcher_exit_reaps_reconciliation_workers

echo "# fm-reconcile-watch-e2e.test.sh: all assertions passed"
