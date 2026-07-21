#!/usr/bin/env bash
# Validated external-wait registration tests: predicate and process completion,
# identity-bound owned-command progress, scope refusal, pending quieting, and
# exact-once acknowledgement.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WAIT="$ROOT/bin/fm-external-wait.sh"
RECONCILE="$ROOT/bin/fm-reconcile-lib.sh"
fm_test_tmproot TMP_ROOT fm-external-wait
state="$TMP_ROOT/state"
wt="$TMP_ROOT/worktree"
live="$TMP_ROOT/live"
fake="$TMP_ROOT/fm-crew-state.sh"
mkdir -p "$state" "$wt" "$TMP_ROOT/project"
fm_write_meta "$state/task.meta" \
  'window=session:fm-task' \
  'generation=lifecycle-one' \
  "worktree=$wt" \
  "project=$TMP_ROOT/project" \
  'kind=ship'
printf 'blocked: waiting on observable external work\n' > "$state/task.status"
printf 'state: blocked · source: status-log · waiting on observable external work\n' > "$live"
cat > "$fake" <<'SH'
#!/usr/bin/env bash
cat "$FM_FAKE_RECONCILED_STATE_FILE"
SH
chmod +x "$fake"

# shellcheck source=bin/fm-reconcile-lib.sh
. "$RECONCILE"

observe() {
  FM_RECONCILE_CREW_STATE_BIN="$fake" \
    FM_FAKE_RECONCILED_STATE_FILE="$live" \
    fm_reconcile_observe "$state" task
}

test_predicate_registration_and_missing_failure() {
  local predicate out token err
  predicate="$TMP_ROOT/predicate.sh"
  err="$TMP_ROOT/missing.err"
  cat > "$predicate" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$predicate"
  FM_STATE_OVERRIDE="$state" "$WAIT" register-predicate task "$predicate" 'filesystem completion condition' >/dev/null \
    || fail "valid predicate registration failed"
  [ -z "$(observe)" ] || fail "new pending predicate should establish a quiet baseline"
  [ -z "$(observe)" ] || fail "unchanged pending predicate should remain quiet"
  cat > "$predicate" <<'SH'
#!/usr/bin/env bash
printf 'callback ledger advanced but remains pending\n'
exit 1
SH
  chmod +x "$predicate"
  out=$(observe)
  assert_contains "$out" 'external-wait-changed' "changed pending predicate evidence did not wake"
  token=$(printf '%s' "$out" | cut -f2)
  fm_reconcile_ack "$state" task "$token" "$(printf '%s' "$out" | cut -f3)" || fail "could not acknowledge changed predicate evidence"
  [ -z "$(observe)" ] || fail "unchanged advanced predicate evidence emitted a duplicate"
  rm -f "$predicate"
  out=$(observe)
  assert_contains "$out" 'external-wait-failed' "a registered predicate disappearing did not fail loudly"
  assert_contains "$out" 'predicate missing or not executable' "missing predicate failure lost its evidence"
  token=$(printf '%s' "$out" | cut -f2)
  fm_reconcile_ack "$state" task "$token" "$(printf '%s' "$out" | cut -f3)" || fail "could not acknowledge missing-predicate failure"
  [ -z "$(observe)" ] || fail "acknowledged missing predicate emitted a duplicate"
  if FM_STATE_OVERRIDE="$state" "$WAIT" register-predicate task "$TMP_ROOT/no-such-predicate" 2> "$err"; then
    fail "registration accepted a missing completion predicate"
  fi
  assert_contains "$(cat "$err")" 'existing executable file' "registration refusal was not actionable"
  pass "predicate registration stays quiet while pending and fails once when its observer disappears"
}

test_process_completion_signal() {
  local pid out token
  sleep 30 &
  pid=$!
  FM_STATE_OVERRIDE="$state" "$WAIT" register-process task "$pid" 'tracked OAuth callback helper' >/dev/null \
    || fail "live process registration failed"
  [ -z "$(observe)" ] || fail "new live process wait should be quiet"
  [ -z "$(observe)" ] || fail "unchanged live process wait should remain quiet"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  out=$(observe)
  assert_contains "$out" 'external-wait-complete' "tracked process exit did not emit completion"
  assert_contains "$out" "registered process $pid exited" "process completion lost its exact evidence"
  token=$(printf '%s' "$out" | cut -f2)
  fm_reconcile_ack "$state" task "$token" "$(printf '%s' "$out" | cut -f3)" || fail "could not acknowledge tracked process completion"
  [ -z "$(observe)" ] || fail "acknowledged process completion emitted a duplicate"
  pass "tracked process identity emits exactly one model-free completion signal"
}

wait_for_process_cwd() {  # <pid> <root>
  local pid=$1 root=$2 i=0 cwd
  root=$(cd "$root" && pwd -P)
  while [ "$i" -lt 100 ]; do
    cwd=$(fm_reconcile_process_cwd "$pid" 2>/dev/null || true)
    fm_reconcile_path_is_within "$cwd" "$root" && return 0
    sleep 0.02
    i=$((i + 1))
  done
  return 1
}

test_owned_command_progress_and_scope() {
  local pid outside out token err detail registration physical_wt
  err="$TMP_ROOT/command-scope.err"

  sleep 30 &
  outside=$!
  if FM_STATE_OVERRIDE="$state" "$WAIT" register-command task "$outside" 'unowned command' 2> "$err"; then
    kill "$outside" 2>/dev/null || true
    wait "$outside" 2>/dev/null || true
    fail "register-command accepted a process outside the task worktree"
  fi
  kill "$outside" 2>/dev/null || true
  wait "$outside" 2>/dev/null || true
  assert_contains "$(cat "$err")" 'outside task task worktree/tasktmp' "scope refusal lacked linked-task guidance"

  sh -c 'cd "$1" || exit 1; end=$(( $(date +%s) + 30 )); while [ "$(date +%s)" -lt "$end" ]; do sleep 0.1; done' _ "$wt" &
  pid=$!
  wait_for_process_cwd "$pid" "$wt" || { kill "$pid" 2>/dev/null || true; fail "owned command did not enter task worktree"; }
  FM_OWNED_COMMAND_PROGRESS_GRACE=2 FM_STATE_OVERRIDE="$state" \
    "$WAIT" register-command task "$pid" 'advancing full-suite shell' >/dev/null \
    || { kill "$pid" 2>/dev/null || true; fail "valid task-owned command registration failed"; }
  physical_wt=$(cd "$wt" && pwd -P)
  registration=$(fm_reconcile_wait_registration "$state" task)
  printf '%s' "$registration" | jq -e \
    --arg worktree "$physical_wt" \
    '.kind == "process" and .role == "working-command" and .owner_worktree == $worktree and .progress_grace_seconds == 2' >/dev/null \
    || { kill "$pid" 2>/dev/null || true; fail "owned-command registration was not exposed structurally"; }
  detail=$(fm_reconcile_owned_command_observe "$state" task) \
    || { kill "$pid" 2>/dev/null || true; fail "fresh task-owned command was not positive working evidence"; }
  assert_contains "$detail" 'descendant progress observed' "owned-command evidence omitted progress freshness"
  printf 'state: working · source: owned-command · %s\n' "$detail" > "$live"
  [ -z "$(observe)" ] || fail "new progressing command should establish a quiet working baseline"
  sleep 1
  detail=$(fm_reconcile_owned_command_observe "$state" task) \
    || { kill "$pid" 2>/dev/null || true; fail "advancing descendant tree did not remain positive working evidence"; }
  assert_contains "$detail" 'descendant progress observed' "advancing command lost its progress evidence"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  printf 'state: idle · source: pane · foreground harness idle\n' > "$live"
  out=$(observe)
  assert_contains "$out" 'external-wait-complete' "owned command exit did not emit immediate completion"
  token=$(printf '%s' "$out" | cut -f2)
  fm_reconcile_ack "$state" task "$token" "$(printf '%s' "$out" | cut -f3)" || fail "could not acknowledge owned-command completion"
  [ -z "$(observe)" ] || fail "acknowledged owned-command completion emitted a duplicate"
  pass "task-owned command progress is positive working evidence, scope is enforced, and exit wakes once"
}

test_stalled_owned_command_ages_out() {
  local pid detail out token
  sh -c 'cd "$1" || exit 1; exec sleep 30' _ "$wt" &
  pid=$!
  wait_for_process_cwd "$pid" "$wt" || { kill "$pid" 2>/dev/null || true; fail "stalled command did not enter task worktree"; }
  FM_OWNED_COMMAND_PROGRESS_GRACE=1 FM_STATE_OVERRIDE="$state" \
    "$WAIT" register-command task "$pid" 'intentionally stalled command' >/dev/null \
    || { kill "$pid" 2>/dev/null || true; fail "stalled command registration failed"; }
  detail=$(fm_reconcile_owned_command_observe "$state" task) \
    || { kill "$pid" 2>/dev/null || true; fail "new command did not receive its bounded initial progress grace"; }
  printf 'state: working · source: owned-command · %s\n' "$detail" > "$live"
  [ -z "$(observe)" ] || fail "stalled-command case could not establish its working baseline"
  sleep 2
  if fm_reconcile_owned_command_observe "$state" task >/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "unchanged command process tree remained positive working evidence beyond its grace"
  fi
  printf 'state: idle · source: pane · registered command progress expired\n' > "$live"
  out=$(observe)
  assert_contains "$out" 'reconciled-transition (working -> idle from positive owned-command evidence' \
    "stalled owned command did not surface its loss of positive progress"
  token=$(printf '%s' "$out" | cut -f2)
  fm_reconcile_ack "$state" task "$token" "$(printf '%s' "$out" | cut -f3)" || fail "could not acknowledge stalled-command transition"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "a live but non-progressing registered command ages out instead of masking a wedge indefinitely"
}

test_background_probe_is_durable_and_fail_closed() {
  local pid predicate registration out token version restarted
  predicate="$TMP_ROOT/background-probe.sh"
  cat > "$predicate" <<'SH'
#!/usr/bin/env bash
printf 'ledger revision 1 pending\n'
exit 1
SH
  chmod +x "$predicate"
  predicate="$(cd "$(dirname "$predicate")" && pwd -P)/$(basename "$predicate")"
  sh -c 'cd "$1" || exit 1; exec sleep 30' _ "$wt" &
  pid=$!
  wait_for_process_cwd "$pid" "$wt" || { kill "$pid" 2>/dev/null || true; fail "background-probe child did not enter task worktree"; }
  printf 'paused: supervising a background ledger probe\n' > "$state/task.status"
  printf 'state: paused · source: status-log · supervising a background ledger probe\n' > "$live"
  FM_STATE_OVERRIDE="$state" "$WAIT" register-background-probe task "$pid" "$predicate" 'background corpus build' >/dev/null \
    || { kill "$pid" 2>/dev/null || true; fail "valid background-probe registration failed"; }
  registration=$(fm_reconcile_wait_registration "$state" task)
  printf '%s' "$registration" | jq -e \
    --arg predicate "$predicate" \
    '.kind == "process" and .role == "background-probe" and .predicate == $predicate and .probe_initial_evidence == "ledger revision 1 pending"' >/dev/null \
    || { kill "$pid" 2>/dev/null || true; fail "background-probe ownership was not exposed structurally"; }
  [ -z "$(observe)" ] || { kill "$pid" 2>/dev/null || true; fail "background-probe paused baseline was not quiet"; }
  [ "$(fm_reconcile_record_value "$state/task.reconciled" background_probe_armed)" = 1 ] \
    || { kill "$pid" 2>/dev/null || true; fail "background-probe paused baseline was not armed durably"; }
  fm_reconcile_background_probe_can_absorb "$state" task session:fm-task \
    || { kill "$pid" 2>/dev/null || true; fail "unchanged background-probe baseline was not absorbable"; }

  printf 'state: working · source: pane · one-shot progress probe\n' > "$live"
  [ -z "$(observe)" ] || { kill "$pid" 2>/dev/null || true; fail "background-probe pulse start unexpectedly woke"; }
  printf 'state: paused · source: status-log · supervising a background ledger probe\n' > "$live"
  restarted=$(FM_RECONCILE_CREW_STATE_BIN="$fake" FM_FAKE_RECONCILED_STATE_FILE="$live" \
    bash -c '. "$1"; fm_reconcile_observe "$2" task' _ "$RECONCILE" "$state")
  [ -z "$restarted" ] || { kill "$pid" 2>/dev/null || true; fail "identical background-probe return woke after restart: $restarted"; }
  printf 'state: working · source: pane · repeated progress probe\n' > "$live"
  [ -z "$(observe)" ] || { kill "$pid" 2>/dev/null || true; fail "repeated background-probe pulse start unexpectedly woke"; }
  printf 'state: idle · source: pane · returned to the paused endpoint\n' > "$live"
  [ -z "$(observe)" ] || { kill "$pid" 2>/dev/null || true; fail "repeated background-probe return emitted a wake"; }

  sed 's/revision 1/revision 2/' "$predicate" > "$predicate.tmp"
  mv "$predicate.tmp" "$predicate"
  chmod +x "$predicate"
  out=$(observe)
  assert_contains "$out" 'external-wait-changed' "changed still-pending background-probe evidence did not wake"
  token=$(printf '%s' "$out" | cut -f2)
  version=$(printf '%s' "$out" | cut -f3)
  fm_reconcile_ack "$state" task "$token" "$version" || fail "could not acknowledge changed background-probe evidence"
  [ -z "$(observe)" ] || fail "acknowledged background-probe evidence change duplicated"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  out=$(observe)
  assert_contains "$out" 'external-wait-failed' "background-probe child exit did not fail loudly"
  assert_contains "$out" 'child' "background-probe child failure lost its ownership evidence"
  token=$(printf '%s' "$out" | cut -f2)
  version=$(printf '%s' "$out" | cut -f3)
  fm_reconcile_ack "$state" task "$token" "$version" || fail "could not acknowledge background-probe child failure"
  [ -z "$(observe)" ] || fail "acknowledged background-probe child failure duplicated"
  pass "owned background probes absorb identical pause returns and surface evidence or child failure once"
}

test_registration_and_clear_revalidate_serialized_lifecycle() {
  local predicate register_pid clear_pid i err trace
  predicate="$TMP_ROOT/serialized-predicate.sh"
  err="$TMP_ROOT/serialized-register.err"
  trace="$TMP_ROOT/serialized-clear.trace"
  cat > "$predicate" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$predicate"
  FM_STATE_OVERRIDE="$state" "$WAIT" clear task >/dev/null || fail "could not clear prior registration"
  fm_reconcile_lock_acquire "$state" task
  FM_STATE_OVERRIDE="$state" "$WAIT" register-predicate task "$predicate" 'serialized registration' > /dev/null 2> "$err" &
  register_pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    find "$state" -maxdepth 1 -name 'task.wait.tmp.*' -print | grep -q . && break
    sleep 0.02
    i=$((i + 1))
  done
  [ "$i" -lt 100 ] || { fm_reconcile_lock_release "$state" task; kill "$register_pid" 2>/dev/null || true; fail "registration did not reach serialized publication"; }
  fm_write_meta "$state/task.meta" \
    'window=session:fm-task' \
    'generation=lifecycle-two' \
    "worktree=$wt" \
    "project=$TMP_ROOT/project" \
    'kind=ship'
  fm_reconcile_lock_release "$state" task
  if wait "$register_pid"; then fail "registration attached to a replacement lifecycle"; fi
  [ ! -e "$state/task.wait" ] || fail "failed old-lifecycle registration published a wait file"
  assert_contains "$(cat "$err")" 'lifecycle changed' "registration lifecycle race did not explain its refusal"

  FM_STATE_OVERRIDE="$state" "$WAIT" register-predicate task "$predicate" 'current registration' >/dev/null \
    || fail "current lifecycle predicate registration failed"
  fm_reconcile_lock_acquire "$state" task
  FM_STATE_OVERRIDE="$state" bash -x "$WAIT" clear task > /dev/null 2> "$trace" &
  clear_pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    grep -q 'fm_reconcile_lock_acquire' "$trace" 2>/dev/null && break
    sleep 0.02
    i=$((i + 1))
  done
  [ "$i" -lt 100 ] || { fm_reconcile_lock_release "$state" task; kill "$clear_pid" 2>/dev/null || true; fail "clear did not reach serialized publication"; }
  fm_write_meta "$state/task.wait" \
    'schema=fm-external-wait.v1' \
    'kind=predicate' \
    'description=replacement registration' \
    'registration_id=replacement-registration' \
    'lifecycle_generation=lifecycle-two' \
    "predicate=$predicate" \
    'registered_at=2'
  fm_reconcile_lock_release "$state" task
  if wait "$clear_pid"; then fail "clear removed a replacement wait registration"; fi
  [ -e "$state/task.wait" ] || fail "clear race deleted the replacement registration"
  assert_contains "$(cat "$trace")" 'registration changed while clear was pending' "clear race did not explain its refusal"
  pass "external-wait registration and clear serialize and revalidate lifecycle ownership"
}

test_help_without_task_id() {
  local out
  out=$(FM_STATE_OVERRIDE="$state" "$WAIT" --help) \
    || fail "external-wait help incorrectly required a task id"
  assert_contains "$out" 'exit 0 plus' "external-wait help omitted the successful predicate exit requirement"
  assert_contains "$out" 'non-empty stdout means complete' "external-wait help omitted the predicate completion signal requirement"
  assert_contains "$out" 'never completion evidence' "external-wait help treated stderr as predicate completion evidence"
  pass "external-wait help is available without task metadata"
}

test_predicate_registration_and_missing_failure
test_process_completion_signal
test_owned_command_progress_and_scope
test_stalled_owned_command_ages_out
test_background_probe_is_durable_and_fail_closed
test_registration_and_clear_revalidate_serialized_lifecycle
test_help_without_task_id

echo "# fm-external-wait.test.sh: all assertions passed"
