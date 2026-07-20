#!/usr/bin/env bash
# Validated external-wait registration tests: predicate and process completion,
# identity-bound owned-command progress, scope refusal, pending quieting, and
# exact-once acknowledgement.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WAIT="$ROOT/bin/fm-external-wait.sh"
RECONCILE="$ROOT/bin/fm-reconcile-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-external-wait)
state="$TMP_ROOT/state"
wt="$TMP_ROOT/worktree"
live="$TMP_ROOT/live"
fake="$TMP_ROOT/fm-crew-state.sh"
mkdir -p "$state" "$wt"
fm_write_meta "$state/task.meta" \
  'window=session:fm-task' \
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
  rm -f "$predicate"
  out=$(observe)
  assert_contains "$out" 'external-wait-failed' "a registered predicate disappearing did not fail loudly"
  assert_contains "$out" 'predicate missing or not executable' "missing predicate failure lost its evidence"
  token=$(printf '%s' "$out" | cut -f2)
  fm_reconcile_ack "$state" task "$token" || fail "could not acknowledge missing-predicate failure"
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
  fm_reconcile_ack "$state" task "$token" || fail "could not acknowledge tracked process completion"
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
  fm_reconcile_ack "$state" task "$token" || fail "could not acknowledge owned-command completion"
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
  fm_reconcile_ack "$state" task "$token" || fail "could not acknowledge stalled-command transition"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "a live but non-progressing registered command ages out instead of masking a wedge indefinitely"
}

test_help_without_task_id() {
  FM_STATE_OVERRIDE="$state" "$WAIT" --help >/dev/null \
    || fail "external-wait help incorrectly required a task id"
  pass "external-wait help is available without task metadata"
}

test_predicate_registration_and_missing_failure
test_process_completion_signal
test_owned_command_progress_and_scope
test_stalled_owned_command_ages_out
test_help_without_task_id

echo "# fm-external-wait.test.sh: all assertions passed"
