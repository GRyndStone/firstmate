#!/usr/bin/env bash
# Durable reconciled-state behavior tests: working transitions, stale event
# immunity, external-wait predicates, restart dedupe, and event-sequence evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECONCILE="$ROOT/bin/fm-reconcile-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-reconcile-lib)

[ -f "$RECONCILE" ] || fail "missing durable reconciliation owner: $RECONCILE"
# shellcheck source=bin/fm-reconcile-lib.sh
. "$RECONCILE"

make_reconcile_case() {
  local name=$1 dir state wt fake
  dir="$TMP_ROOT/$name"
  state="$dir/state"
  wt="$dir/worktree"
  fake="$dir/fm-crew-state.sh"
  mkdir -p "$state" "$wt" "$dir/project"
  fm_write_meta "$state/task.meta" \
    "window=session:fm-task" \
    "worktree=$wt" \
    "project=$dir/project" \
    "kind=ship"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
cat "$FM_FAKE_RECONCILED_STATE_FILE"
SH
  chmod +x "$fake"
  printf '%s\n' "$dir"
}

observe() {
  local state=$1 live=$2
  FM_RECONCILE_CREW_STATE_BIN="$state/../fm-crew-state.sh" \
    FM_FAKE_RECONCILED_STATE_FILE="$live" \
    fm_reconcile_observe "$state" task
}

test_active_review_parks_once_past_stale_pause() {
  local dir state live out token record
  dir=$(make_reconcile_case active-review)
  state="$dir/state"
  live="$dir/live"
  printf 'paused: old no-mistakes head is still under review\n' > "$state/task.status"
  printf 'state: working · source: run-step · validating (running)\n' > "$live"

  out=$(observe "$state" "$live")
  [ -z "$out" ] || fail "initial positive working observation should establish a quiet baseline: $out"
  record="$state/task.reconciled"
  [ "$(fm_reconcile_record_value "$record" state)" = working ] || fail "working baseline was not persisted"

  printf 'state: parked · source: run-step · parked at fix_review: 2 finding(s)\n' > "$live"
  out=$(observe "$state" "$live")
  assert_contains "$out" $'action\t' "working -> parked did not become actionable"
  assert_contains "$out" 'reconciled-transition' "parked wake lacks transition evidence"
  token=$(printf '%s' "$out" | cut -f2)
  fm_reconcile_ack "$state" task "$token" || fail "could not acknowledge parked transition"
  [ -z "$(observe "$state" "$live")" ] || fail "unchanged acknowledged park emitted a duplicate"
  [ "$(fm_reconcile_record_value "$record" prior_state)" = working ] || fail "prior observed state was not retained"
  [ "$(fm_reconcile_record_value "$record" last_status_event)" = 'paused: old no-mistakes head is still under review' ] \
    || fail "last status event was not exposed separately"
  pass "active review working -> parked wakes once despite a stale paused event"
}

test_stopped_endpoint_without_claimed_done_wakes_once() {
  local dir state live out token record
  dir=$(make_reconcile_case missing-done)
  state="$dir/state"
  live="$dir/live"
  printf 'paused: old head dcd61bf awaiting validation\n' > "$state/task.status"
  printf 'state: working · source: pane · harness busy\n' > "$live"
  observe "$state" "$live" >/dev/null

  printf 'state: unknown · source: none · backend target gone: session:fm-task\n' > "$live"
  out=$(observe "$state" "$live")
  assert_contains "$out" 'working -> unknown' "stopped endpoint without done event did not wake"
  token=$(printf '%s' "$out" | cut -f2)
  fm_reconcile_ack "$state" task "$token"
  [ -z "$(observe "$state" "$live")" ] || fail "stopped endpoint transition re-fired after acknowledgement"
  record="$state/task.reconciled"
  [ "$(fm_reconcile_record_value "$record" status_sequence)" = 1 ] || fail "observed status sequence is not verifiable"
  case "$(fm_reconcile_record_value "$record" last_status_event)" in
    *done:*) fail "test fixture unexpectedly acquired a done event" ;;
  esac
  pass "working -> stopped endpoint wakes once when the claimed done event is absent"
}

test_same_repository_endpoint_replacement_preserves_working_baseline() {
  local dir state live out token record
  dir=$(make_reconcile_case endpoint-replacement)
  state="$dir/state"
  live="$dir/live"
  printf 'working: implementation active\n' > "$state/task.status"
  printf 'state: working · source: pane · harness busy\n' > "$live"
  observe "$state" "$live" >/dev/null
  record="$state/task.reconciled"
  [ -n "$(fm_reconcile_record_value "$record" repository_identity)" ] \
    || fail "working baseline omitted its repository identity"

  fm_write_meta "$state/task.meta" \
    'window=session:fm-task-recovered' \
    "worktree=$dir/worktree" \
    "project=$dir/project" \
    'kind=ship'
  printf 'state: idle · source: pane · recovered endpoint is idle\n' > "$live"
  out=$(observe "$state" "$live")
  assert_contains "$out" 'working -> idle' "same-repository endpoint replacement lost its working baseline"
  token=$(printf '%s' "$out" | cut -f2)
  fm_reconcile_ack "$state" task "$token"
  [ -z "$(observe "$state" "$live")" ] || fail "recovered endpoint transition duplicated after acknowledgement"
  pass "same-repository endpoint replacement preserves and reconciles the working baseline"
}

test_positive_working_source_loss_wakes_past_stale_working_event() {
  local dir state live out token
  dir=$(make_reconcile_case stale-working-source)
  state="$dir/state"
  live="$dir/live"
  printf 'working: historical build event\n' > "$state/task.status"
  printf 'state: working · source: pane · harness busy\n' > "$live"
  observe "$state" "$live" >/dev/null

  printf 'state: working · source: status-log · working: historical build event\n' > "$live"
  out=$(observe "$state" "$live")
  assert_contains "$out" 'from positive pane evidence' "stale working event masked loss of positive pane evidence"
  assert_contains "$out" 'source now status-log' "source-loss wake did not expose the stale status-log fallback"
  token=$(printf '%s' "$out" | cut -f2)
  fm_reconcile_ack "$state" task "$token"
  [ -z "$(observe "$state" "$live")" ] || fail "acknowledged positive-source loss emitted a duplicate"
  pass "loss of positive working evidence wakes even when stale status prose still says working"
}

test_external_wait_completion_and_failures() {
  local dir state live predicate out token
  dir=$(make_reconcile_case external-wait)
  state="$dir/state"
  live="$dir/live"
  predicate="$dir/predicate.sh"
  printf 'blocked: awaiting OAuth consent callback\n' > "$state/task.status"
  printf 'state: blocked · source: status-log · awaiting OAuth consent callback\n' > "$live"
  cat > "$predicate" <<'SH'
#!/usr/bin/env bash
case "$(cat "$FM_WAIT_TEST_STATE")" in
  pending) printf 'callback listener active\n'; exit 1 ;;
  complete) printf 'OAuth credential stored\n'; exit 0 ;;
  *) printf 'callback predicate failed\n'; exit 3 ;;
esac
SH
  chmod +x "$predicate"
  printf 'pending\n' > "$dir/wait-state"
  fm_write_meta "$state/task.wait" \
    'schema=fm-external-wait.v1' \
    'kind=predicate' \
    'description=xAI OAuth callback' \
    "predicate=$predicate" \
    'registered_at=1'

  FM_WAIT_TEST_STATE="$dir/wait-state" observe "$state" "$live" >/dev/null
  [ -z "$(FM_WAIT_TEST_STATE="$dir/wait-state" observe "$state" "$live")" ] \
    || fail "unchanged pending external wait should remain quiet"

  printf 'complete\n' > "$dir/wait-state"
  out=$(FM_WAIT_TEST_STATE="$dir/wait-state" observe "$state" "$live")
  assert_contains "$out" 'external-wait-complete' "OAuth callback completion did not wake through its predicate"
  token=$(printf '%s' "$out" | cut -f2)
  fm_reconcile_ack "$state" task "$token"
  [ -z "$(FM_WAIT_TEST_STATE="$dir/wait-state" observe "$state" "$live")" ] \
    || fail "completed callback predicate emitted a duplicate wake"

  printf 'failed\n' > "$dir/wait-state"
  out=$(FM_WAIT_TEST_STATE="$dir/wait-state" observe "$state" "$live")
  assert_contains "$out" 'external-wait-failed' "failed predicate did not fail loudly"
  pass "registered OAuth predicate wakes on completion, dedupes, and fails loudly"
}

test_signaled_predicate_is_not_reported_complete() {
  local dir perl_bin rc
  dir=$(make_reconcile_case signaled-predicate)
  perl_bin=$(command -v perl 2>/dev/null || true)
  if [ -z "$perl_bin" ]; then
    pass "signaled predicate fallback skipped without perl"
    return
  fi
  mkdir -p "$dir/perl-only"
  ln -s "$perl_bin" "$dir/perl-only/perl"
  PATH="$dir/perl-only" fm_reconcile_bounded 2 /bin/sh -c 'kill -TERM $$'
  rc=$?
  [ "$rc" -ne 0 ] || fail "signaled predicate fallback was reported as successful completion"
  pass "signaled predicate fallback preserves a nonzero failure status"
}

test_unobservable_pause_fails_loudly_and_busy_stays_quiet() {
  local dir state live out token
  dir=$(make_reconcile_case missing-predicate)
  state="$dir/state"
  live="$dir/live"
  printf 'paused: waiting for a callback with no observer\n' > "$state/task.status"
  printf 'state: paused · source: status-log · waiting for a callback with no observer\n' > "$live"
  out=$(observe "$state" "$live")
  assert_contains "$out" 'external-wait-unobservable' "pause without a completion predicate did not fail loudly"
  token=$(printf '%s' "$out" | cut -f2)
  fm_reconcile_ack "$state" task "$token"
  [ -z "$(observe "$state" "$live")" ] || fail "unchanged already-notified invalid pause stormed"

  printf 'state: working · source: pane · harness busy\n' > "$live"
  [ -z "$(observe "$state" "$live")" ] || fail "positive busy evidence should be absorbed"
  [ -z "$(observe "$state" "$live")" ] || fail "unchanged positive busy evidence should remain quiet"
  pass "unobservable pause fails once while positive busy evidence stays quiet"
}

test_inflight_unregistered_blocked_wait_fails_loudly_once() {
  local dir state live out token predicate restarted
  dir=$(make_reconcile_case inflight-blocked)
  state="$dir/state"
  live="$dir/live"
  predicate="$dir/predicate.sh"
  printf 'blocked: callback listener was started without an observer\n' > "$state/task.status"
  printf 'state: blocked · source: status-log · callback listener was started without an observer\n' > "$live"

  out=$(observe "$state" "$live")
  assert_contains "$out" 'external-wait-unobservable' "in-flight blocked wait omission did not fail loudly"
  assert_contains "$out" 'blocked task has no' "blocked omission wake did not identify its missing observer"
  token=$(printf '%s' "$out" | cut -f2)
  fm_reconcile_ack "$state" task "$token"
  restarted=$(FM_RECONCILE_CREW_STATE_BIN="$dir/fm-crew-state.sh" \
    FM_FAKE_RECONCILED_STATE_FILE="$live" \
    bash -c '. "$1"; fm_reconcile_observe "$2" task' _ "$RECONCILE" "$state")
  [ -z "$restarted" ] || fail "already-notified blocked omission stormed after restart: $restarted"

  cat > "$predicate" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$predicate"
  fm_write_meta "$state/task.wait" \
    'schema=fm-external-wait.v1' \
    'kind=predicate' \
    'description=late callback observer repair' \
    "predicate=$predicate" \
    'registered_at=1'
  [ -z "$(observe "$state" "$live")" ] || fail "registering a pending observer for an in-flight wait emitted a duplicate"
  [ "$(fm_reconcile_record_value "$state/task.reconciled" wait_state)" = pending ] \
    || fail "late observer registration was not reconciled as pending"
  pass "existing blocked wait omissions fail loudly once and can be repaired in flight"
}

test_unacknowledged_transition_is_not_replaced_by_newer_state() {
  local dir state live first second token
  dir=$(make_reconcile_case pending-race)
  state="$dir/state"
  live="$dir/live"
  printf 'paused: historical event only\n' > "$state/task.status"
  printf 'state: working · source: pane · harness busy\n' > "$live"
  observe "$state" "$live" >/dev/null

  printf 'state: idle · source: pane · foreground turn ended\n' > "$live"
  first=$(observe "$state" "$live")
  token=$(printf '%s' "$first" | cut -f2)
  assert_contains "$first" 'working -> idle' "pending-race fixture did not create its first transition"

  # Simulate a watcher crash after observation but before queue acknowledgement.
  # The live task moves again before the restarted watcher reconciles it.
  printf 'blocked: callback wait omitted registration\n' > "$state/task.status"
  printf 'state: blocked · source: status-log · callback wait omitted registration\n' > "$live"
  second=$(observe "$state" "$live")
  [ "$(printf '%s' "$second" | cut -f2)" = "$token" ] \
    || fail "newer blocked evidence replaced the unacknowledged transition token"
  assert_contains "$second" 'working -> idle' "original unacknowledged transition evidence was lost"
  assert_contains "$second" 'newer observation before delivery: external-wait-unobservable' \
    "newer blocked omission was not folded into the pending wake"
  [ "$(fm_reconcile_record_value "$state/task.reconciled" state)" = blocked ] \
    || fail "latest current state was not persisted while retaining the pending event"

  fm_reconcile_ack "$state" task "$token"
  [ -z "$(observe "$state" "$live")" ] || fail "combined pending transition emitted a duplicate after acknowledgement"
  pass "unacknowledged transition survives newer live truth without loss or replacement"
}

test_delivery_race_preserves_later_status_and_turn_events() {
  local dir state live out token record observed_status observed_turn seen_status seen_turn
  dir=$(make_reconcile_case delivery-race)
  state="$dir/state"
  live="$dir/live"
  printf 'working: implementation active\n' > "$state/task.status"
  : > "$state/task.turn-ended"
  printf 'state: working · source: pane · harness busy\n' > "$live"
  observe "$state" "$live" >/dev/null

  printf 'state: idle · source: pane · foreground turn ended\n' > "$live"
  out=$(observe "$state" "$live")
  token=$(printf '%s' "$out" | cut -f2)
  assert_contains "$out" 'working -> idle' "delivery-race fixture did not persist its transition"
  record="$state/task.reconciled"
  observed_status=$(fm_reconcile_record_value "$record" status_signal_signature)
  observed_turn=$(fm_reconcile_record_value "$record" turn_signal_signature)

  # A claimed done append and a later turn-end receipt land after observation
  # but before the watcher finishes enqueue/ack.  Advancing from current file
  # stats here would silently consume both newer events.
  sleep 1
  printf 'done: claimed after the reconciled observation\n' >> "$state/task.status"
  touch "$state/task.turn-ended"
  fm_reconcile_advance_seen "$state" task || fail "delivery-race suppressors could not be advanced"
  fm_reconcile_ack "$state" task "$token" || fail "delivery-race transition could not be acknowledged"

  seen_status=$(cat "$state/.seen-task_status")
  seen_turn=$(cat "$state/.seen-task_turn-ended")
  [ "$seen_status" = "$observed_status" ] \
    || fail "status suppressor advanced past the exact reconciled observation"
  [ "$seen_turn" = "$observed_turn" ] \
    || fail "turn-end suppressor advanced past the exact reconciled observation"
  [ "$seen_status" != "$(fm_reconcile_signal_signature "$state/task.status")" ] \
    || fail "later claimed done append was silently marked seen during delivery"
  [ "$seen_turn" != "$(fm_reconcile_signal_signature "$state/task.turn-ended")" ] \
    || fail "later turn-end receipt was silently marked seen during delivery"
  pass "enqueue/ack delivery advances only observed event signatures and preserves later races"
}

test_restart_preserves_transition_dedup() {
  local dir state live out token restarted
  dir=$(make_reconcile_case restart)
  state="$dir/state"
  live="$dir/live"
  printf 'working: implementation active\n' > "$state/task.status"
  printf 'state: working · source: pane · harness busy\n' > "$live"
  observe "$state" "$live" >/dev/null
  printf 'state: idle · source: pane · backend reports idle\n' > "$live"
  out=$(observe "$state" "$live")
  token=$(printf '%s' "$out" | cut -f2)
  fm_reconcile_ack "$state" task "$token"
  restarted=$(FM_RECONCILE_CREW_STATE_BIN="$dir/fm-crew-state.sh" \
    FM_FAKE_RECONCILED_STATE_FILE="$live" \
    bash -c '. "$1"; fm_reconcile_observe "$2" task' _ "$RECONCILE" "$state")
  [ -z "$restarted" ] || fail "supervisor restart duplicated an acknowledged transition: $restarted"
  pass "durable observation and acknowledgement survive supervisor restart"
}

test_active_review_parks_once_past_stale_pause
test_stopped_endpoint_without_claimed_done_wakes_once
test_same_repository_endpoint_replacement_preserves_working_baseline
test_positive_working_source_loss_wakes_past_stale_working_event
test_external_wait_completion_and_failures
test_signaled_predicate_is_not_reported_complete
test_unobservable_pause_fails_loudly_and_busy_stays_quiet
test_inflight_unregistered_blocked_wait_fails_loudly_once
test_unacknowledged_transition_is_not_replaced_by_newer_state
test_delivery_race_preserves_later_status_and_turn_events
test_restart_preserves_transition_dedup

echo "# fm-reconcile-lib.test.sh: all assertions passed"
