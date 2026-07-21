#!/usr/bin/env bash
# Durable reconciled-state behavior tests: working transitions, stale event
# immunity, external-wait predicates, restart dedupe, and event-sequence evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECONCILE="$ROOT/bin/fm-reconcile-lib.sh"
fm_test_tmproot TMP_ROOT fm-reconcile-lib

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

make_absent_spawn_probe() {
  local dir=$1 fake="$1/fakebin"
  mkdir -p "$fake"
  cat > "$fake/tmux" <<'SH'
#!/bin/sh
case "${1:-}" in
  list-windows)
    [ "${FM_FAKE_TMUX_PROBE:-absent}" = absent ] && exit 0
    exit 2
    ;;
esac
exit 1
SH
  chmod +x "$fake/tmux"
  printf '%s\n' "$fake"
}

age_spawn_claim() {
  local claim=$1 tmp="$1.tmp-age"
  sed 's/^creation_started_at=.*/creation_started_at=1/; s/^owner_pid=.*/owner_pid=999999/' \
    "$claim" > "$tmp"
  mv "$tmp" "$claim"
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
  fm_reconcile_ack "$state" task "$token" "$(printf '%s' "$out" | cut -f3)" || fail "could not acknowledge parked transition"
  [ -z "$(observe "$state" "$live")" ] || fail "unchanged acknowledged park emitted a duplicate"
  [ "$(fm_reconcile_record_value "$record" prior_state)" = working ] || fail "prior observed state was not retained"
  [ "$(fm_reconcile_record_value "$record" last_status_event)" = 'paused: old no-mistakes head is still under review' ] \
    || fail "last status event was not exposed separately"
  pass "active review working -> parked wakes once despite a stale paused event"
}

test_notified_observation_does_not_mask_newer_live_transition() {
  local dir state live out token record
  dir=$(make_reconcile_case notified-observation)
  state="$dir/state"
  live="$dir/live"
  printf 'paused: historical review event\n' > "$state/task.status"
  printf 'state: working · source: run-step · validation running\n' > "$live"
  observe "$state" "$live" >/dev/null

  printf 'state: parked · source: run-step · review findings ready\n' > "$live"
  out=$(observe "$state" "$live")
  token=$(printf '%s' "$out" | cut -f2)
  fm_reconcile_ack "$state" task "$token" "$(printf '%s' "$out" | cut -f3)" || fail "parked transition could not be acknowledged"
  fm_reconcile_is_quiet_notified "$state" task session:fm-task \
    || fail "acknowledged parked observation was not quiet"

  printf 'state: failed · source: run-step · validation failed after review\n' > "$live"
  observe "$state" "$live" >/dev/null
  record="$state/task.reconciled"
  [ "$(fm_reconcile_record_value "$record" transition_sequence)" -gt 1 ] \
    || fail "newer failed observation did not advance the transition sequence"
  if fm_reconcile_is_quiet_notified "$state" task session:fm-task; then
    fail "acknowledged parked token masked the newer failed observation"
  fi
  pass "quiet suppression is bound to the exact notified live observation"
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
  fm_reconcile_ack "$state" task "$token" "$(printf '%s' "$out" | cut -f3)"
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
  fm_reconcile_ack "$state" task "$token" "$(printf '%s' "$out" | cut -f3)"
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
  fm_reconcile_ack "$state" task "$token" "$(printf '%s' "$out" | cut -f3)"
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
  fm_reconcile_ack "$state" task "$token" "$(printf '%s' "$out" | cut -f3)"
  [ -z "$(FM_WAIT_TEST_STATE="$dir/wait-state" observe "$state" "$live")" ] \
    || fail "completed callback predicate emitted a duplicate wake"

  printf 'failed\n' > "$dir/wait-state"
  out=$(FM_WAIT_TEST_STATE="$dir/wait-state" observe "$state" "$live")
  assert_contains "$out" 'external-wait-failed' "failed predicate did not fail loudly"
  pass "registered OAuth predicate wakes on completion, dedupes, and fails loudly"
}

test_live_process_with_unreadable_identity_fails_observation() {
  local dir state live identity out record
  dir=$(make_reconcile_case unreadable-process-identity)
  state="$dir/state"
  live="$dir/live"
  identity=$(fm_reconcile_process_identity "$$") \
    || fail "could not capture the test process identity"
  printf 'paused: waiting for a tracked process\n' > "$state/task.status"
  printf 'state: paused · source: status-log · waiting for a tracked process\n' > "$live"
  fm_write_meta "$state/task.wait" \
    'schema=fm-external-wait.v1' \
    'kind=process' \
    'description=tracked process with transiently unreadable identity' \
    "pid=$$" \
    "pid_identity=$identity" \
    'role=external-wait' \
    'registered_at=1'

  out=$(
    # shellcheck disable=SC2329
    fm_reconcile_process_identity() { return 1; }
    observe "$state" "$live"
  )
  assert_contains "$out" 'external-wait-failed' \
    "unreadable live process identity was not surfaced as an observer failure"
  assert_contains "$out" 'identity is unreadable' \
    "unreadable live process identity lost its failure evidence"
  case "$out" in *external-wait-complete*) fail "unreadable live process identity was reported complete" ;; esac
  record="$state/task.reconciled"
  [ "$(fm_reconcile_record_value "$record" wait_state)" = failed ] \
    || fail "unreadable live process identity persisted a non-failed wait state"
  pass "live process identity observation fails closed when ps is unreadable"
}

test_unchanged_terminal_wait_does_not_mask_live_transition() {
  local dir state live predicate out token
  dir=$(make_reconcile_case terminal-wait-transition)
  state="$dir/state"
  live="$dir/live"
  predicate="$dir/predicate.sh"
  printf 'working: foreground resumed after callback\n' > "$state/task.status"
  printf 'state: working · source: pane · harness busy\n' > "$live"
  cat > "$predicate" <<'SH'
#!/usr/bin/env bash
printf 'callback already complete\n'
exit 0
SH
  chmod +x "$predicate"
  fm_write_meta "$state/task.wait" \
    'schema=fm-external-wait.v1' \
    'kind=predicate' \
    'description=completed callback' \
    "predicate=$predicate" \
    'registered_at=1'

  out=$(observe "$state" "$live")
  assert_contains "$out" 'external-wait-complete' "completed wait fixture did not establish its terminal baseline"
  token=$(printf '%s' "$out" | cut -f2)
  fm_reconcile_ack "$state" task "$token" "$(printf '%s' "$out" | cut -f3)" || fail "completed wait baseline could not be acknowledged"

  printf 'state: idle · source: pane · resumed foreground turn ended\n' > "$live"
  out=$(observe "$state" "$live")
  assert_contains "$out" 'reconciled-transition (working -> idle' "unchanged terminal wait masked the later live transition"
  case "$out" in *external-wait-complete*) fail "unchanged completed wait displaced the later live transition" ;; esac
  pass "unchanged terminal waits do not mask later live transitions"
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
  fm_reconcile_ack "$state" task "$token" "$(printf '%s' "$out" | cut -f3)"
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
  fm_reconcile_ack "$state" task "$token" "$(printf '%s' "$out" | cut -f3)"
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

test_unobservable_parked_wait_fails_loudly_once() {
  local dir state live out token first_seq first_key second_seq second_key
  dir=$(make_reconcile_case unobservable-parked)
  state="$dir/state"
  live="$dir/live"
  printf 'paused: merge gate has no observer\n' > "$state/task.status"
  printf 'state: parked · source: run-step · merge gate has no observer\n' > "$live"
  out=$(observe "$state" "$live")
  assert_contains "$out" 'external-wait-unobservable' "parked wait omission did not fail loudly"
  assert_contains "$out" 'parked task has no' "parked omission wake did not identify its missing observer"
  token=$(printf '%s' "$out" | cut -f2)
  fm_reconcile_ack "$state" task "$token" "$(printf '%s' "$out" | cut -f3)"
  first_seq=$(fm_reconcile_record_value "$state/task.reconciled" wait_sequence)
  first_key=$(fm_reconcile_record_value "$state/task.reconciled" observation_key)
  [ -z "$(observe "$state" "$live")" ] || fail "unchanged parked observer omission stormed"
  second_seq=$(fm_reconcile_record_value "$state/task.reconciled" wait_sequence)
  second_key=$(fm_reconcile_record_value "$state/task.reconciled" observation_key)
  [ "$second_seq" = "$first_seq" ] || fail "unchanged parked observer omission advanced its wait sequence"
  [ "$second_key" = "$first_key" ] || fail "unchanged parked observer omission changed its dedupe key"
  pass "unobservable parked waits fail loudly once"
}

test_unacknowledged_transition_is_not_replaced_by_newer_state() {
  local dir state live first second token first_version second_version
  dir=$(make_reconcile_case pending-race)
  state="$dir/state"
  live="$dir/live"
  printf 'paused: historical event only\n' > "$state/task.status"
  printf 'state: working · source: pane · harness busy\n' > "$live"
  observe "$state" "$live" >/dev/null

  printf 'state: idle · source: pane · foreground turn ended\n' > "$live"
  first=$(observe "$state" "$live")
  token=$(printf '%s' "$first" | cut -f2)
  first_version=$(printf '%s' "$first" | cut -f3)
  assert_contains "$first" 'working -> idle' "pending-race fixture did not create its first transition"

  # Simulate a watcher crash after observation but before queue acknowledgement.
  # The live task moves again before the restarted watcher reconciles it.
  printf 'blocked: callback wait omitted registration\n' > "$state/task.status"
  printf 'state: blocked · source: status-log · callback wait omitted registration\n' > "$live"
  second=$(observe "$state" "$live")
  second_version=$(printf '%s' "$second" | cut -f3)
  [ "$(printf '%s' "$second" | cut -f2)" = "$token" ] \
    || fail "newer blocked evidence replaced the unacknowledged transition token"
  assert_contains "$second" 'working -> idle' "original unacknowledged transition evidence was lost"
  assert_contains "$second" 'newer observation before delivery: external-wait-unobservable' \
    "newer blocked omission was not folded into the pending wake"
  [ "$(fm_reconcile_record_value "$state/task.reconciled" state)" = blocked ] \
    || fail "latest current state was not persisted while retaining the pending event"
  [ "$second_version" != "$first_version" ] \
    || fail "folded observation did not advance the pending delivery version"
  if fm_reconcile_ack "$state" task "$token" "$first_version"; then
    fail "older queued delivery acknowledged a newer folded observation"
  fi

  fm_reconcile_ack "$state" task "$token" "$second_version"
  [ -z "$(observe "$state" "$live")" ] || fail "combined pending transition emitted a duplicate after acknowledgement"
  pass "unacknowledged transition survives newer live truth without loss or replacement"
}

test_unacknowledged_transition_folds_newer_sparse_event() {
  local dir state live first second token
  dir=$(make_reconcile_case pending-event-race)
  state="$dir/state"
  live="$dir/live"
  printf 'working: implementation active\n' > "$state/task.status"
  printf 'state: working · source: pane · harness busy\n' > "$live"
  observe "$state" "$live" >/dev/null

  printf 'state: idle · source: pane · foreground turn ended\n' > "$live"
  first=$(observe "$state" "$live")
  token=$(printf '%s' "$first" | cut -f2)
  printf 'done: claimed after the pending transition\n' >> "$state/task.status"
  second=$(observe "$state" "$live")
  [ "$(printf '%s' "$second" | cut -f2)" = "$token" ] \
    || fail "newer sparse event replaced the pending transition token"
  assert_contains "$second" 'newer sparse event before delivery' \
    "newer status append was not folded into the pending wake"
  assert_contains "$second" 'done: claimed after the pending transition' \
    "pending wake did not represent the newer status evidence"
  pass "pending transitions retain newer sparse event evidence"
}

test_acknowledgement_race_preserves_notified_token() {
  local dir state live first token observer_pid i=0
  dir=$(make_reconcile_case acknowledgement-race)
  state="$dir/state"
  live="$dir/live"
  printf 'working: implementation active\n' > "$state/task.status"
  printf 'state: working · source: pane · harness busy\n' > "$live"
  observe "$state" "$live" >/dev/null
  printf 'state: idle · source: pane · foreground turn ended\n' > "$live"
  first=$(observe "$state" "$live")
  token=$(printf '%s' "$first" | cut -f2)

  cat > "$dir/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
touch "$FM_ACK_RACE_STARTED"
while [ ! -e "$FM_ACK_RACE_RELEASE" ]; do sleep 0.02; done
cat "$FM_FAKE_RECONCILED_STATE_FILE"
SH
  chmod +x "$dir/fm-crew-state.sh"
  FM_RECONCILE_CREW_STATE_BIN="$dir/fm-crew-state.sh" \
    FM_FAKE_RECONCILED_STATE_FILE="$live" \
    FM_ACK_RACE_STARTED="$dir/observer-started" \
    FM_ACK_RACE_RELEASE="$dir/observer-release" \
    fm_reconcile_observe "$state" task > "$dir/observer.out" &
  observer_pid=$!
  while [ ! -e "$dir/observer-started" ] && [ "$i" -lt 100 ]; do sleep 0.02; i=$((i + 1)); done
  [ "$i" -lt 100 ] || fail "acknowledgement-race observer did not start"
  fm_reconcile_ack "$state" task "$token" "$(printf '%s' "$first" | cut -f3)" || fail "concurrent acknowledgement failed"
  touch "$dir/observer-release"
  wait "$observer_pid" || fail "observer failed after concurrent acknowledgement"
  [ "$(fm_reconcile_record_value "$state/task.reconciled" notified_action_token)" = "$token" ] \
    || fail "later observation erased the concurrent acknowledgement"
  pass "per-task serialization preserves concurrent acknowledgements"
}

test_teardown_tombstone_prevents_record_resurrection() {
  local dir state live observer_pid i=0
  dir=$(make_reconcile_case teardown-race)
  state="$dir/state"
  live="$dir/live"
  printf 'working: implementation active\n' > "$state/task.status"
  printf 'state: working · source: pane · harness busy\n' > "$live"
  cat > "$dir/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
touch "$FM_TEARDOWN_RACE_STARTED"
while [ ! -e "$FM_TEARDOWN_RACE_RELEASE" ]; do sleep 0.02; done
cat "$FM_FAKE_RECONCILED_STATE_FILE"
SH
  chmod +x "$dir/fm-crew-state.sh"
  FM_RECONCILE_CREW_STATE_BIN="$dir/fm-crew-state.sh" \
    FM_FAKE_RECONCILED_STATE_FILE="$live" \
    FM_TEARDOWN_RACE_STARTED="$dir/observer-started" \
    FM_TEARDOWN_RACE_RELEASE="$dir/observer-release" \
    fm_reconcile_observe "$state" task > "$dir/observer.out" &
  observer_pid=$!
  while [ ! -e "$dir/observer-started" ] && [ "$i" -lt 100 ]; do sleep 0.02; i=$((i + 1)); done
  [ "$i" -lt 100 ] || fail "teardown-race observer did not start"
  fm_reconcile_teardown_begin "$state" task || fail "teardown tombstone could not be serialized"
  rm -f "$state/task.meta" "$state/task.reconciled" "$state/task.tearing-down"
  touch "$dir/observer-release"
  wait "$observer_pid" || fail "teardown-race observer failed"
  [ ! -e "$state/task.reconciled" ] || fail "in-flight observer resurrected reconciliation state after teardown"
  [ ! -s "$dir/observer.out" ] || fail "in-flight observer emitted a post-teardown action"
  pass "teardown serialization prevents reconciliation-state resurrection"
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
  fm_reconcile_ack "$state" task "$token" "$(printf '%s' "$out" | cut -f3)" || fail "delivery-race transition could not be acknowledged"

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
  fm_reconcile_ack "$state" task "$token" "$(printf '%s' "$out" | cut -f3)"
  restarted=$(FM_RECONCILE_CREW_STATE_BIN="$dir/fm-crew-state.sh" \
    FM_FAKE_RECONCILED_STATE_FILE="$live" \
    bash -c '. "$1"; fm_reconcile_observe "$2" task' _ "$RECONCILE" "$state")
  [ -z "$restarted" ] || fail "supervisor restart duplicated an acknowledged transition: $restarted"
  pass "durable observation and acknowledgement survive supervisor restart"
}

test_stale_teardown_tombstone_stops_suppressing_observation() {
  local dir state live out
  dir=$(make_reconcile_case stale-tombstone)
  state="$dir/state"
  live="$dir/live"
  printf 'working: implementation active\n' > "$state/task.status"
  printf 'state: working · source: pane · harness busy\n' > "$live"
  observe "$state" "$live" >/dev/null
  touch "$state/task.tearing-down"
  printf 'state: idle · source: pane · foreground turn ended\n' > "$live"
  [ -z "$(observe "$state" "$live")" ] || fail "fresh teardown tombstone did not suppress observation"
  touch -t 200001010000 "$state/task.tearing-down"
  out=$(observe "$state" "$live")
  assert_contains "$out" 'working -> idle' "stale teardown tombstone suppressed reconciliation indefinitely"
  pass "stale teardown tombstones fail back to live observation"
}

test_predicate_output_is_capped_with_exit_status_preserved() {
  local dir state live predicate out evidence
  dir=$(make_reconcile_case predicate-output-cap)
  state="$dir/state"
  live="$dir/live"
  predicate="$dir/noisy-predicate.sh"
  printf 'blocked: noisy external predicate\n' > "$state/task.status"
  printf 'state: blocked · source: status-log · noisy external predicate\n' > "$live"
  cat > "$predicate" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 10000 ]; do printf x; i=$((i + 1)); done
exit 7
SH
  chmod +x "$predicate"
  fm_write_meta "$state/task.wait" \
    'schema=fm-external-wait.v1' \
    'kind=predicate' \
    'description=noisy predicate' \
    "predicate=$predicate" \
    'registered_at=1'
  out=$(FM_EXTERNAL_WAIT_OUTPUT_MAX_BYTES=64 observe "$state" "$live")
  assert_contains "$out" 'predicate exited 7' "capped predicate output lost the predicate exit status"
  evidence=$(fm_reconcile_record_value "$state/task.reconciled" wait_evidence)
  [ "${#evidence}" -le 128 ] || fail "predicate evidence exceeded its configured output cap: ${#evidence} bytes"
  pass "predicate output is capped while its exit status remains actionable"
}

test_malformed_live_state_values_are_rejected() {
  if fm_reconcile_parse_state_line 'state: invented · source: pane · invalid state'; then
    fail "live-state parser accepted a noncanonical state"
  fi
  if fm_reconcile_parse_state_line 'state: working · source: invented · invalid source'; then
    fail "live-state parser accepted a noncanonical source"
  fi
  if fm_reconcile_parse_state_line $'state: working · source: pane · valid first line\nunexpected second line'; then
    fail "live-state parser accepted trailing observer output"
  fi
  pass "live-state parser rejects noncanonical and multiline observations"
}

test_owned_command_does_not_override_first_terminal_observation() {
  local dir state live pid identity physical_wt out
  command -v pgrep >/dev/null 2>&1 || { pass "owned-command run override skipped without pgrep"; return; }
  dir=$(make_reconcile_case owned-command-run-override)
  state="$dir/state"
  live="$dir/live"
  physical_wt=$(cd "$dir/worktree" && pwd -P)
  sh -c 'cd "$1" || exit 1; while :; do sleep 0.1; done' _ "$physical_wt" &
  pid=$!
  sleep 0.1
  identity=$(fm_reconcile_process_identity "$pid") || { kill "$pid" 2>/dev/null || true; fail "could not identify owned command"; }
  fm_write_meta "$state/task.wait" \
    'schema=fm-external-wait.v1' \
    'kind=process' \
    'description=background validation' \
    "pid=$pid" \
    "pid_identity=$identity" \
    'role=working-command' \
    'progress_grace=30' \
    "owner_worktree=$physical_wt" \
    'owner_tasktmp=' \
    'registered_at=1'
  printf 'done: historical validation run\n' > "$state/task.status"
  printf 'state: done · source: run-step · historical run completed\n' > "$live"
  out=$(observe "$state" "$live")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ -z "$out" ] || fail "first terminal observation unexpectedly woke: $out"
  [ "$(fm_reconcile_record_value "$state/task.reconciled" state)" = done ] \
    || fail "progressing owned command masked the first terminal observation"
  [ "$(fm_reconcile_record_value "$state/task.reconciled" source)" = run-step ] \
    || fail "owned command replaced the first authoritative terminal source"
  pass "progressing owned commands do not mask terminal truth on first observation"
}

test_owned_command_overrides_older_persisted_idle() {
  local dir state live pid identity physical_wt
  command -v pgrep >/dev/null 2>&1 || { pass "owned-command idle override skipped without pgrep"; return; }
  dir=$(make_reconcile_case owned-command-idle-override)
  state="$dir/state"
  live="$dir/live"
  printf 'state: idle · source: pane · foreground turn ended\n' > "$live"
  observe "$state" "$live" >/dev/null
  physical_wt=$(cd "$dir/worktree" && pwd -P)
  sh -c 'cd "$1" || exit 1; while :; do sleep 0.1; done' _ "$physical_wt" &
  pid=$!
  sleep 0.1
  identity=$(fm_reconcile_process_identity "$pid") || { kill "$pid" 2>/dev/null || true; fail "could not identify owned command"; }
  fm_write_meta "$state/task.wait" \
    'schema=fm-external-wait.v1' \
    'kind=process' \
    'description=background validation' \
    "pid=$pid" \
    "pid_identity=$identity" \
    'role=working-command' \
    'progress_grace=30' \
    "owner_worktree=$physical_wt" \
    'owner_tasktmp=' \
    'registered_at=1'
  observe "$state" "$live" >/dev/null
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$(fm_reconcile_record_value "$state/task.reconciled" state)" = working ] \
    || fail "new progressing command did not override older persisted idle"
  [ "$(fm_reconcile_record_value "$state/task.reconciled" source)" = owned-command ] \
    || fail "new progressing command did not become the reconciled source"
  pass "new progressing commands override older persisted idle"
}

test_owned_command_overrides_historical_wait_events() {
  local historical dir state live pid identity physical_wt
  command -v pgrep >/dev/null 2>&1 || { pass "owned-command historical wait override skipped without pgrep"; return; }
  for historical in paused blocked parked; do
    dir=$(make_reconcile_case "owned-command-$historical-override")
    state="$dir/state"
    live="$dir/live"
    printf 'state: %s · source: status-log · historical wait event\n' "$historical" > "$live"
    observe "$state" "$live" >/dev/null
    physical_wt=$(cd "$dir/worktree" && pwd -P)
    sh -c 'cd "$1" || exit 1; while :; do sleep 0.1; done' _ "$physical_wt" &
    pid=$!
    sleep 0.1
    identity=$(fm_reconcile_process_identity "$pid") || { kill "$pid" 2>/dev/null || true; fail "could not identify owned command"; }
    fm_write_meta "$state/task.wait" \
      'schema=fm-external-wait.v1' \
      'kind=process' \
      'description=background validation' \
      "pid=$pid" \
      "pid_identity=$identity" \
      'role=working-command' \
      'progress_grace=30' \
      "owner_worktree=$physical_wt" \
      'owner_tasktmp=' \
      'registered_at=1'
    observe "$state" "$live" >/dev/null
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [ "$(fm_reconcile_record_value "$state/task.reconciled" state)" = working ] \
      || fail "progressing owned command did not override historical $historical event"
    [ "$(fm_reconcile_record_value "$state/task.reconciled" source)" = owned-command ] \
      || fail "progressing owned command did not own reconciliation over historical $historical event"
  done
  pass "progressing owned commands override historical wait events"
}

test_registered_legacy_check_completes_once_in_reconciliation() {
  local dir state live generation check_tmp out token version
  dir=$(make_reconcile_case registered-legacy-check)
  state="$dir/state"
  live="$dir/live"
  generation=$(fm_reconcile_meta_generation "$state/task.meta")
  check_tmp="$state/task.check.tmp"
  cat > "$check_tmp" <<'SH'
#!/usr/bin/env bash
n=$(cat "$FM_LEGACY_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((n + 1))" > "$FM_LEGACY_COUNT"
printf 'merged\n'
SH
  fm_reconcile_legacy_check_register "$state" task "$generation" "$check_tmp" 'merge poll' \
    || fail "legacy check registration failed"
  printf 'state: parked · source: status-log · waiting for merge\n' > "$live"
  out=$(FM_LEGACY_COUNT="$dir/check-count" observe "$state" "$live")
  assert_contains "$out" 'external-wait-complete' "registered legacy completion did not use reconciliation"
  token=$(printf '%s' "$out" | cut -f2)
  version=$(printf '%s' "$out" | cut -f3)
  fm_reconcile_ack "$state" task "$token" "$version" || fail "legacy completion acknowledgement failed"
  [ -z "$(FM_LEGACY_COUNT="$dir/check-count" observe "$state" "$live")" ] \
    || fail "acknowledged legacy completion emitted again"
  [ "$(cat "$dir/check-count")" = 1 ] || fail "registered legacy check ran more than once after completion"
  pass "registered legacy checks complete exactly once through reconciliation"
}

test_unmanaged_legacy_check_remains_supported_with_generation_metadata() {
  local dir state live out generation
  dir=$(make_reconcile_case unmanaged-legacy-check)
  state="$dir/state"
  live="$dir/live"
  printf '#!/usr/bin/env bash\nprintf "custom condition complete\\n"\n' > "$state/task.check.sh"
  chmod +x "$state/task.check.sh"
  printf 'state: parked · source: status-log · waiting for custom condition\n' > "$live"
  out=$(observe "$state" "$live")
  generation=$(fm_reconcile_meta_generation "$state/task.meta")
  fm_reconcile_wait_load "$state" task
  [ "$FM_RECONCILE_WAIT_LIFECYCLE_GENERATION" = "$generation" ] \
    || fail "unmanaged legacy check was not bound to the current lifecycle generation"
  assert_contains "$out" 'external-wait-complete' "unmanaged legacy check was rejected under generation metadata"
  assert_contains "$out" 'custom condition complete' "unmanaged legacy check lost its completion evidence"
  assert_not_contains "$out" 'has no task lifecycle generation' "unmanaged legacy check was mistaken for a malformed managed registration"
  pass "unmanaged per-task checks remain supported across lifecycle generation upgrades"
}

test_stderr_only_success_does_not_complete_waits() {
  local dir state live predicate out
  dir=$(make_reconcile_case stderr-only-predicate)
  state="$dir/state"
  live="$dir/live"
  predicate="$dir/predicate.sh"
  printf '#!/usr/bin/env bash\nprintf "predicate warning\\n" >&2\nexit 0\n' > "$predicate"
  chmod +x "$predicate"
  fm_write_meta "$state/task.wait" \
    'schema=fm-external-wait.v1' \
    'kind=predicate' \
    'description=stderr-only predicate' \
    "predicate=$predicate" \
    'registered_at=1'
  printf 'state: blocked · source: status-log · waiting for predicate\n' > "$live"
  out=$(observe "$state" "$live")
  assert_not_contains "$out" 'external-wait-complete' "stderr-only predicate success completed its wait"
  [ "$(fm_reconcile_record_value "$state/task.reconciled" wait_state)" = pending ] \
    || fail "stderr-only predicate success did not remain pending"
  assert_contains "$(fm_reconcile_record_value "$state/task.reconciled" wait_evidence)" 'predicate warning' \
    "stderr-only predicate diagnostic was lost"

  dir=$(make_reconcile_case stderr-only-legacy)
  state="$dir/state"
  live="$dir/live"
  printf '#!/usr/bin/env bash\nprintf "legacy warning\\n" >&2\nexit 0\n' > "$state/task.check.sh"
  chmod +x "$state/task.check.sh"
  printf 'state: parked · source: status-log · waiting for legacy check\n' > "$live"
  out=$(observe "$state" "$live")
  assert_not_contains "$out" 'external-wait-complete' "stderr-only legacy success completed its wait"
  [ "$(fm_reconcile_record_value "$state/task.reconciled" wait_state)" = pending ] \
    || fail "stderr-only legacy success did not remain pending"
  assert_contains "$(fm_reconcile_record_value "$state/task.reconciled" wait_evidence)" 'legacy warning' \
    "stderr-only legacy diagnostic was lost"
  pass "stderr-only successful observers remain pending"
}

test_legacy_check_registration_requires_atomic_commit() {
  local dir state generation check_tmp registration
  dir=$(make_reconcile_case legacy-check-commit)
  state="$dir/state"
  generation=$(fm_reconcile_meta_generation "$state/task.meta")
  check_tmp="$state/task.check.tmp"
  printf '#!/usr/bin/env bash\nprintf "ready\\n"\n' > "$check_tmp"
  fm_reconcile_legacy_check_register "$state" task "$generation" "$check_tmp" 'atomic poll' \
    || fail "legacy check registration failed"
  [ -s "$state/task.wait-commit" ] || fail "legacy check registration did not publish its commit manifest"
  fm_reconcile_wait_load "$state" task
  [ "$FM_RECONCILE_WAIT_KIND" = legacy-check ] || fail "committed legacy check was not observable"
  registration=$(fm_reconcile_record_value "$state/task.wait" registration_id)
  rm -f "$state/task.wait-commit"
  fm_reconcile_wait_load "$state" task
  [ "$FM_RECONCILE_WAIT_KIND" = invalid-legacy-check ] \
    || fail "uncommitted legacy check registration was consumed"
  [ "$(fm_reconcile_legacy_check_marker "$state/task.check.sh")" = "$registration" ] \
    || fail "published legacy check lost its transaction marker"
  fm_reconcile_legacy_check_is_managed "$state" task "$state/task.check.sh" \
    || fail "uncommitted managed check fell through to the direct legacy scanner"
  pass "legacy check and wait publication requires one validated commit manifest"
}

test_failed_legacy_check_output_is_failure() {
  local dir state live generation check_tmp out
  dir=$(make_reconcile_case failed-legacy-output)
  state="$dir/state"
  live="$dir/live"
  generation=$(fm_reconcile_meta_generation "$state/task.meta")
  check_tmp="$state/task.check.tmp"
  printf '#!/usr/bin/env bash\nprintf "relay unavailable\\n" >&2\nexit 2\n' > "$check_tmp"
  fm_reconcile_legacy_check_register "$state" task "$generation" "$check_tmp" 'failing poll' \
    || fail "failing legacy check registration failed"
  printf 'state: parked · source: status-log · waiting for relay\n' > "$live"
  out=$(observe "$state" "$live")
  assert_contains "$out" 'external-wait-failed' "stderr-producing failed legacy check reported completion"
  assert_contains "$out" 'legacy check exited 2: relay unavailable' "legacy failure lost status and stderr evidence"
  [ "$(fm_reconcile_record_value "$state/task.reconciled" wait_state)" = failed ] \
    || fail "stderr-producing legacy check did not persist failed state"
  pass "failed legacy checks remain failures even when they print output"
}

test_repository_identity_failure_preserves_proven_binding() {
  local dir state live out before after
  dir=$(make_reconcile_case repository-resolution-failure)
  state="$dir/state"
  live="$dir/live"
  printf 'state: working · source: pane · harness busy\n' > "$live"
  observe "$state" "$live" >/dev/null
  before=$(fm_reconcile_record_value "$state/task.reconciled" repository_identity)
  mv "$dir/project" "$dir/project-gone"
  printf 'state: idle · source: pane · foreground stopped\n' > "$live"
  out=$(observe "$state" "$live")
  after=$(fm_reconcile_record_value "$state/task.reconciled" repository_identity)
  assert_contains "$out" 'observer-failure' "repository identity resolution failure did not fail loudly"
  assert_contains "$out" 'repository identity cannot be resolved' "repository identity failure lost its evidence"
  [ -n "$before" ] && [ "$after" = "$before" ] \
    || fail "repository identity failure erased the proven binding"
  pass "repository resolution failures preserve proven identity and fail loudly"
}

test_lifecycle_generation_prevents_metadata_aba_publication() {
  local dir state live observer_pid i=0
  dir=$(make_reconcile_case lifecycle-generation-aba)
  state="$dir/state"
  live="$dir/live"
  fm_write_meta "$state/task.meta" \
    'window=session:fm-task' \
    'generation=generation-one' \
    "worktree=$dir/worktree" \
    "project=$dir/project" \
    'kind=ship'
  printf 'state: working · source: pane · harness busy\n' > "$live"
  cat > "$dir/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
touch "$FM_ABA_STARTED"
while [ ! -e "$FM_ABA_RELEASE" ]; do sleep 0.02; done
cat "$FM_FAKE_RECONCILED_STATE_FILE"
SH
  chmod +x "$dir/fm-crew-state.sh"
  (
    # shellcheck disable=SC2329
    fm_reconcile_file_signature() { printf 'forced-identical-signature'; }
    FM_RECONCILE_CREW_STATE_BIN="$dir/fm-crew-state.sh" \
      FM_FAKE_RECONCILED_STATE_FILE="$live" \
      FM_ABA_STARTED="$dir/observer-started" \
      FM_ABA_RELEASE="$dir/observer-release" \
      fm_reconcile_observe "$state" task
  ) > "$dir/observer.out" &
  observer_pid=$!
  while [ ! -e "$dir/observer-started" ] && [ "$i" -lt 100 ]; do sleep 0.02; i=$((i + 1)); done
  [ "$i" -lt 100 ] || fail "metadata ABA observer did not start"
  fm_write_meta "$state/task.meta" \
    'window=session:fm-task' \
    'generation=generation-two' \
    "worktree=$dir/worktree" \
    "project=$dir/project" \
    'kind=ship'
  touch "$dir/observer-release"
  wait "$observer_pid" || fail "metadata ABA observer failed"
  [ ! -s "$dir/observer.out" ] || fail "old lifecycle observer published after metadata replacement"
  [ ! -e "$state/task.reconciled" ] || fail "old lifecycle observer wrote into the replacement lifecycle"
  pass "lifecycle generation prevents metadata ABA publication"
}

test_delivery_version_is_unique_across_task_lifecycles() {
  local dir state live first second first_token first_version second_token second_version old_reason
  dir=$(make_reconcile_case delivery-lifecycle-version)
  state="$dir/state"
  live="$dir/live"
  fm_write_meta "$state/task.meta" \
    'window=session:fm-task' \
    'generation=lifecycle-one' \
    "worktree=$dir/worktree" \
    "project=$dir/project" \
    'kind=ship'
  printf 'state: working · source: pane · harness busy\n' > "$live"
  observe "$state" "$live" >/dev/null
  printf 'state: idle · source: pane · foreground ended\n' > "$live"
  first=$(observe "$state" "$live")
  first_token=$(printf '%s' "$first" | cut -f2)
  first_version=$(printf '%s' "$first" | cut -f3)

  fm_write_meta "$state/task.wait" \
    'schema=fm-external-wait.v1' \
    'kind=predicate' \
    'description=old lifecycle wait' \
    'registration_id=old-lifecycle-registration' \
    'lifecycle_generation=lifecycle-one' \
    "predicate=$dir/predicate.sh" \
    'registered_at=1'
  fm_write_meta "$state/task.probe-pulse" \
    'schema=fm-background-probe-pulse.v1' \
    'state=armed' \
    'lifecycle_generation=lifecycle-one' \
    'pulse_id=old-lifecycle-pulse'
  fm_write_meta "$state/task.meta" \
    'window=session:fm-task' \
    'generation=lifecycle-two' \
    "worktree=$dir/worktree" \
    "project=$dir/project" \
    'kind=ship'
  printf 'state: working · source: pane · harness busy\n' > "$live"
  observe "$state" "$live" >/dev/null
  printf 'state: idle · source: pane · foreground ended\n' > "$live"
  second=$(observe "$state" "$live")
  second_token=$(printf '%s' "$second" | cut -f2)
  second_version=$(printf '%s' "$second" | cut -f3)
  [ "$second_token" = "$first_token" ] || fail "lifecycle replay fixture did not reuse its action token"
  [ "$second_version" != "$first_version" ] || fail "replacement lifecycle reused an old delivery version"
  [ ! -e "$state/task.wait" ] || fail "replacement lifecycle inherited an old external wait"
  [ ! -e "$state/task.probe-pulse" ] || fail "replacement lifecycle inherited an old probe pulse"

  old_reason="stale: session:fm-task old lifecycle $(fm_reconcile_action_marker task "$first_token" "$first_version")"
  fm_reconcile_consumer_ack_reason "$state" "$old_reason" \
    || fail "obsolete lifecycle marker returned an acknowledgement error"
  [ "$(fm_reconcile_record_value "$state/task.reconciled" notified_action_version)" != "$second_version" ] \
    || fail "obsolete lifecycle marker acknowledged the replacement observation"
  fm_reconcile_ack "$state" task "$second_token" "$second_version" \
    || fail "current lifecycle delivery could not be acknowledged"
  pass "delivery versions cannot be reused across task lifecycles"
}

test_process_identity_toctou_classifies_exit_as_complete() {
  local result evidence
  result=$(
    calls=0
    fm_reconcile_pid_alive() {
      calls=$((calls + 1))
      [ "$calls" -eq 1 ]
    }
    fm_reconcile_process_identity() { return 1; }
    FM_RECONCILE_WAIT_PRESENT=1
    FM_RECONCILE_WAIT_KIND=process
    FM_RECONCILE_WAIT_DESCRIPTION='exiting process'
    FM_RECONCILE_WAIT_SIGNATURE=process-race
    FM_RECONCILE_WAIT_PID=4242
    FM_RECONCILE_WAIT_PID_IDENTITY='recorded identity'
    FM_RECONCILE_WAIT_ROLE=external-wait
    FM_RECONCILE_WAIT_LIFECYCLE_GENERATION=
    FM_RECONCILE_WAIT_CURRENT_LIFECYCLE_GENERATION='legacy:1:2'
    fm_reconcile_wait_evaluate /dev/null 1
    printf '%s\t%s\n' "$FM_RECONCILE_WAIT_RESULT" "$FM_RECONCILE_WAIT_EVIDENCE"
  )
  IFS=$(printf '\t') read -r result evidence <<EOF
$result
EOF
  [ "$result" = complete ] || fail "process exit during identity read was classified as $result"
  assert_contains "$evidence" 'exited' "process exit race lost its completion evidence"
  pass "process exits between liveness and identity reads complete without a false failure"
}

test_owned_command_observation_races_classify_exit_as_complete() {
  local seam evaluation result evidence
  for seam in cwd progress; do
    evaluation=$(
      calls=0
      fm_reconcile_pid_alive() {
        calls=$((calls + 1))
        [ "$calls" -eq 1 ]
      }
      fm_reconcile_process_identity() { printf 'recorded identity'; }
      if [ "$seam" = cwd ]; then
        fm_reconcile_process_cwd() { return 1; }
        fm_reconcile_process_tree_signature() { printf progress; }
      else
        fm_reconcile_process_cwd() { printf '/tmp/fm-owned-command-race'; }
        fm_reconcile_process_tree_signature() { return 1; }
      fi
      FM_RECONCILE_WAIT_PRESENT=1
      FM_RECONCILE_WAIT_KIND=process
      FM_RECONCILE_WAIT_DESCRIPTION='exiting owned command'
      FM_RECONCILE_WAIT_SIGNATURE="process-$seam-race"
      FM_RECONCILE_WAIT_PID=4242
      FM_RECONCILE_WAIT_PID_IDENTITY='recorded identity'
      FM_RECONCILE_WAIT_ROLE=working-command
      FM_RECONCILE_WAIT_PROGRESS_GRACE=30
      FM_RECONCILE_WAIT_OWNER_WORKTREE=/tmp/fm-owned-command-race
      FM_RECONCILE_WAIT_OWNER_TASKTMP=
      FM_RECONCILE_WAIT_PROGRESS_SIGNATURE=old-progress
      FM_RECONCILE_WAIT_PROGRESS_AT=1
      FM_RECONCILE_WAIT_LIFECYCLE_GENERATION=
      FM_RECONCILE_WAIT_CURRENT_LIFECYCLE_GENERATION='legacy:1:2'
      fm_reconcile_wait_evaluate /dev/null 1
      printf '%s\t%s\n' "$FM_RECONCILE_WAIT_RESULT" "$FM_RECONCILE_WAIT_EVIDENCE"
    )
    IFS=$(printf '\t') read -r result evidence <<EOF
$evaluation
EOF
    [ "$result" = complete ] || fail "owned command exit during $seam read was classified as $result"
    assert_contains "$evidence" 'exited' "owned command $seam race lost its completion evidence"
  done
  pass "owned command exits during observation complete without false failures"
}

test_owned_command_revalidates_identity_after_progress_observation() {
  local evaluation result evidence working identity_counter
  identity_counter="$TMP_ROOT/post-identity-calls"
  printf '0\n' > "$identity_counter"
  evaluation=$(
    fm_reconcile_pid_alive() { return 0; }
    fm_reconcile_process_identity() {
      identity_calls=$(cat "$identity_counter")
      identity_calls=$((identity_calls + 1))
      printf '%s\n' "$identity_calls" > "$identity_counter"
      if [ "$identity_calls" -eq 1 ]; then printf 'recorded identity'; else printf 'replacement identity'; fi
    }
    fm_reconcile_process_cwd() { printf '/tmp/fm-owned-command-reuse'; }
    fm_reconcile_process_tree_signature() { printf 'replacement-progress'; }
    FM_RECONCILE_WAIT_PRESENT=1
    FM_RECONCILE_WAIT_KIND=process
    FM_RECONCILE_WAIT_DESCRIPTION='reused owned command pid'
    FM_RECONCILE_WAIT_SIGNATURE=process-post-identity-race
    FM_RECONCILE_WAIT_PID=4242
    FM_RECONCILE_WAIT_PID_IDENTITY='recorded identity'
    FM_RECONCILE_WAIT_ROLE=working-command
    FM_RECONCILE_WAIT_PROGRESS_GRACE=30
    FM_RECONCILE_WAIT_OWNER_WORKTREE=/tmp/fm-owned-command-reuse
    FM_RECONCILE_WAIT_OWNER_TASKTMP=
    FM_RECONCILE_WAIT_LIFECYCLE_GENERATION=
    FM_RECONCILE_WAIT_CURRENT_LIFECYCLE_GENERATION='legacy:1:2'
    fm_reconcile_wait_evaluate /dev/null 10
    printf '%s\t%s\t%s\n' "$FM_RECONCILE_WAIT_RESULT" "$FM_RECONCILE_WAIT_EVIDENCE" "$FM_RECONCILE_WAIT_WORKING"
  )
  IFS=$(printf '\t') read -r result evidence working <<EOF
$evaluation
EOF
  [ "$result" = complete ] || fail "post-observation pid reuse was classified as $result"
  [ "$working" = 0 ] || fail "post-observation pid reuse became positive working evidence"
  assert_contains "$evidence" 'identity changed' "post-observation pid reuse lost its completion evidence"
  pass "owned command identity is revalidated after progress sampling"
}

test_spawn_claim_rechecks_endpoint_after_treehouse_absence() {
  bash -c '
    . "$1/bin/fm-backend.sh"
    calls=0
    fm_backend_spawn_label_absent() {
      calls=$((calls + 1))
      [ "$calls" -eq 1 ]
    }
    fm_backend_treehouse_lease_absent() { return 0; }
    fm_backend_spawn_claim_absent tmux fm-task firstmate "" /project task
    rc=$?
    [ "$rc" -eq 1 ] && [ "$calls" -eq 2 ]
  ' _ "$ROOT" || fail "spawn claim accepted lease absence without rechecking its endpoint"
  pass "spawn claim rechecks endpoint absence after treehouse lease proof"
}

test_owned_command_cannot_mask_newer_terminal_state() {
  local dir state live pid identity physical_wt out token
  command -v pgrep >/dev/null 2>&1 || { pass "owned-command terminal authority skipped without pgrep"; return; }
  dir=$(make_reconcile_case owned-command-terminal-authority)
  state="$dir/state"
  live="$dir/live"
  physical_wt=$(cd "$dir/worktree" && pwd -P)
  sh -c 'cd "$1" || exit 1; while :; do sleep 0.1; done' _ "$physical_wt" &
  pid=$!
  sleep 0.1
  identity=$(fm_reconcile_process_identity "$pid") || { kill "$pid" 2>/dev/null || true; fail "could not identify owned command"; }
  fm_write_meta "$state/task.wait" \
    'schema=fm-external-wait.v1' \
    'kind=process' \
    'description=background validation' \
    "pid=$pid" \
    "pid_identity=$identity" \
    'role=working-command' \
    'progress_grace=30' \
    "owner_worktree=$physical_wt" \
    'owner_tasktmp=' \
    'registered_at=1'
  printf 'state: working · source: pane · harness busy\n' > "$live"
  observe "$state" "$live" >/dev/null
  printf 'done: current validation completed\n' > "$state/task.status"
  printf 'state: done · source: run-step · current run completed\n' > "$live"
  out=$(observe "$state" "$live")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_contains "$out" 'reconciled-transition (working -> done' \
    "progressing owned command masked the newer terminal transition"
  [ "$(fm_reconcile_record_value "$state/task.reconciled" state)" = "done" ] \
    || fail "newer terminal state was not persisted"
  [ "$(fm_reconcile_record_value "$state/task.reconciled" source)" = run-step ] \
    || fail "owned command replaced the authoritative terminal source"
  token=$(printf '%s' "$out" | cut -f2)
  [ -n "$token" ] || fail "terminal transition emitted no delivery token"
  pass "progressing owned commands do not mask newer terminal run-step truth"
}

test_generation_cas_and_spawn_claim_revalidate_lifecycle() {
  local dir state meta tmp stale
  dir="$TMP_ROOT/lifecycle-cas"
  state="$dir/state"
  meta="$state/task.meta"
  mkdir -p "$state"
  fm_write_meta "$meta" 'generation=lifecycle-one' 'window=session:fm-task' 'kind=scout'
  fm_reconcile_meta_update "$state" task lifecycle-one --set pr https://example.test/pr/1 --set kind ship \
    || fail "same-lifecycle metadata CAS failed"
  [ "$(fm_reconcile_meta_value "$meta" pr)" = https://example.test/pr/1 ] || fail "metadata CAS lost pr update"
  [ "$(fm_reconcile_meta_value "$meta" kind)" = ship ] || fail "metadata CAS lost kind update"
  fm_write_meta "$meta" 'generation=lifecycle-two' 'window=session:fm-task-replacement' 'kind=ship'
  if fm_reconcile_meta_update "$state" task lifecycle-one --set pr https://example.test/pr/stale; then
    fail "stale lifecycle metadata CAS overwrote a replacement"
  fi
  [ -z "$(fm_reconcile_meta_value "$meta" pr)" ] || fail "stale lifecycle metadata update reached replacement meta"

  rm -f "$meta"
  fm_reconcile_spawn_claim "$state" task spawn-one || fail "spawn lifecycle claim failed"
  if fm_reconcile_spawn_claim "$state" task spawn-two; then fail "second active spawn lifecycle acquired the same task id"; fi
  tmp="$state/task.meta.new"
  fm_write_meta "$tmp" 'generation=spawn-one' 'window=session:fm-task-new' 'kind=ship'
  fm_reconcile_spawn_publish "$state" task spawn-one "$tmp" || fail "owned spawn lifecycle could not publish metadata"
  [ ! -e "$state/task.spawn-claim" ] || fail "published spawn lifecycle retained its claim"

  fm_reconcile_spawn_claim "$state" task spawn-two || fail "replacement spawn lifecycle claim failed"
  fm_write_meta "$meta" 'generation=external-replacement' 'window=session:fm-external' 'kind=ship'
  stale="$state/task.meta.stale"
  fm_write_meta "$stale" 'generation=spawn-two' 'window=session:fm-stale' 'kind=ship'
  if fm_reconcile_spawn_publish "$state" task spawn-two "$stale"; then
    fail "spawn lifecycle published after metadata ownership changed"
  fi
  [ "$(fm_reconcile_meta_generation "$meta")" = external-replacement ] \
    || fail "failed spawn publication replaced current lifecycle metadata"
  rm -f "$stale"
  fm_reconcile_spawn_claim_release "$state" task spawn-two
  pass "metadata CAS and spawn claims reject replacement-lifecycle races"
}

test_teardown_claim_is_live_and_generation_bound() {
  local dir state tombstone
  dir="$TMP_ROOT/teardown-generation-claim"
  state="$dir/state"
  tombstone="$state/task.tearing-down"
  mkdir -p "$state"
  fm_write_meta "$state/task.meta" 'generation=lifecycle-one' 'window=session:fm-task' 'kind=scout'
  fm_reconcile_teardown_begin "$state" task lifecycle-one || fail "generation-bound teardown claim failed"
  touch -t 200001010000 "$tombstone"
  fm_reconcile_tombstone_active "$state" task \
    || fail "live teardown owner stopped holding its tombstone after the age bound"
  (
    fm_reconcile_pid_alive() { return 0; }
    fm_reconcile_process_identity() { return 1; }
    fm_reconcile_tombstone_active "$state" task
  ) || fail "live teardown owner with unreadable identity stopped holding its tombstone"
  if fm_reconcile_spawn_claim "$state" task replacement-spawn; then
    fail "replacement spawn acquired a task while its teardown owner was live"
  fi
  fm_write_meta "$state/task.meta" 'generation=lifecycle-two' 'window=session:fm-task' 'kind=scout'
  fm_reconcile_lock_acquire "$state" task
  if fm_reconcile_teardown_matches_locked "$state" task lifecycle-one; then
    fm_reconcile_lock_release "$state" task
    fail "old teardown claim matched replacement lifecycle metadata"
  fi
  fm_reconcile_lock_release "$state" task
  pass "teardown claims stay live and reject replacement lifecycle cleanup"
}

test_teardown_refuses_active_spawn_claim() {
  local dir state generation
  dir="$TMP_ROOT/teardown-active-spawn"
  state="$dir/state"
  mkdir -p "$state"
  fm_write_meta "$state/task.meta" 'generation=lifecycle-one' 'window=session:fm-task' 'kind=scout'
  generation=$(fm_reconcile_meta_generation "$state/task.meta")
  fm_reconcile_spawn_claim "$state" task "$generation" || fail "active spawn claim setup failed"
  if fm_reconcile_teardown_begin "$state" task "$generation"; then
    fail "teardown overtook an active spawn claim"
  fi
  [ ! -e "$state/task.tearing-down" ] || fail "refused teardown still published a tombstone"
  fm_reconcile_spawn_claim_release "$state" task "$generation" || fail "active spawn claim release failed"
  fm_reconcile_teardown_begin "$state" task "$generation" || fail "teardown stayed blocked after spawn claim release"
  pass "teardown serializes against active spawn claims"
}

test_partial_spawn_rescue_claim_survives_owner_exit() {
  local dir state claim rescue generation fake old_path FM_SPAWN_CLAIM_RECOVERY_SECS FM_FAKE_TMUX_PROBE
  dir="$TMP_ROOT/spawn-rescue-claim"
  state="$dir/state"
  mkdir -p "$state"
  generation=lifecycle-one
  fm_write_meta "$state/task.meta" "generation=$generation" 'window=session:fm-task' 'kind=scout'
  fm_reconcile_spawn_claim "$state" task spawn-rescue || fail "rescue spawn claim setup failed"
  fm_reconcile_spawn_claim_mark_creation_started "$state" task spawn-rescue tmux fm-task firstmate \
    || fail "rescue spawn claim could not persist its backend scope"
  rescue="$state/task.meta.rescue.test"
  fm_reconcile_spawn_claim_mark_rescue_pending "$state" task spawn-rescue "$rescue" \
    || fail "spawn claim could not enter rescue-pending state"
  claim="$state/task.spawn-claim"
  if fm_reconcile_spawn_publish "$state" task spawn-rescue "$rescue"; then
    fail "missing rescue metadata unexpectedly published"
  fi
  assert_grep 'rescue_pending=1' "$claim" "failed rescue publication released spawn ownership"
  age_spawn_claim "$claim"
  FM_SPAWN_CLAIM_RECOVERY_SECS=1
  fake=$(make_absent_spawn_probe "$dir")
  old_path=$PATH
  PATH="$fake:$PATH"
  FM_FAKE_TMUX_PROBE=unknown
  export FM_FAKE_TMUX_PROBE
  if fm_reconcile_spawn_claim "$state" task replacement; then
    fail "replacement spawn stole a rescue-pending claim before backend absence was proven"
  fi
  assert_grep 'rescue_pending=1' "$claim" "rescue-pending ownership marker was lost"
  FM_FAKE_TMUX_PROBE=absent
  fm_reconcile_teardown_begin "$state" task "$generation" \
    || fail "bounded rescue-pending reconciliation did not accept proven backend absence"
  PATH=$old_path
  [ ! -e "$claim" ] || fail "proven-absent rescue-pending claim was not released"
  pass "rescue-pending ownership releases only after bounded backend absence proof"
}

test_treehouse_rescue_reconciles_by_persisted_holder() {
  local dir project rescue fake status leased_path
  dir="$TMP_ROOT/treehouse-holder-rescue"
  project="$dir/project"
  rescue="$dir/task.meta.rescue"
  fake="$dir/fakebin"
  mkdir -p "$project" "$fake"
  cat > "$fake/treehouse" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = status ] || exit 1
printf '%s\n' "${FM_FAKE_TREEHOUSE_STATUS:-}"
exit "${FM_FAKE_TREEHOUSE_EXIT:-0}"
SH
  cat > "$fake/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in list-windows) exit 0 ;; esac
exit 1
SH
  chmod +x "$fake/treehouse" "$fake/tmux"
  fm_write_meta "$rescue" \
    'spawn_endpoint_uncertain=0' \
    'spawn_worktree_uncertain=1' \
    "project=$project" \
    'spawn_treehouse_holder=task'
  set +e
  PATH="$fake:$PATH" FM_FAKE_TREEHOUSE_STATUS="1  leased  $dir/worktree  (held by task)" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_spawn_claim_absent tmux fm-task firstmate "$2"' _ "$ROOT" "$rescue"
  status=$?
  set -e
  expect_code 1 "$status" "persisted treehouse holder must keep a live uncertain worktree claimed"
  leased_path=$(PATH="$fake:$PATH" FM_FAKE_TREEHOUSE_STATUS='1  leased  ~/worktree  (held by task)' \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_treehouse_lease_path "$2" task' _ "$ROOT" "$project") \
    || fail "treehouse lease path could not expand a home-relative inventory entry"
  [ "$leased_path" = "$HOME/worktree" ] \
    || fail "treehouse lease path expanded to '$leased_path' instead of '$HOME/worktree'"
  set +e
  PATH="$fake:$PATH" FM_FAKE_TREEHOUSE_STATUS="1  leased  $dir/worktree  (held by task)" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_spawn_claim_absent tmux fm-task firstmate "" "$2" task' _ "$ROOT" "$project"
  status=$?
  set -e
  expect_code 1 "$status" "durable creation claim released while its treehouse holder was live"
  PATH="$fake:$PATH" FM_FAKE_TREEHOUSE_STATUS="1  leased  $dir/worktree  (held by another-task)" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_spawn_claim_absent tmux fm-task firstmate "$2"' _ "$ROOT" "$rescue" \
    || fail "absent persisted treehouse holder did not release uncertain worktree ownership"
  PATH="$fake:$PATH" FM_FAKE_TREEHOUSE_STATUS="1  leased  $dir/worktree  (held by another-task)" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_spawn_claim_absent tmux fm-task firstmate "" "$2" task' _ "$ROOT" "$project" \
    || fail "durable creation claim did not reconcile an absent treehouse holder"
  set +e
  PATH="$fake:$PATH" FM_FAKE_TREEHOUSE_EXIT=1 \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_spawn_claim_absent tmux fm-task firstmate "$2"' _ "$ROOT" "$rescue"
  status=$?
  set -e
  expect_code 2 "$status" "failed treehouse inventory must keep uncertain worktree ownership unknown"
  set +e
  pass "treehouse rescue ownership reconciles by persisted lease holder"
}

test_dead_spawn_claim_after_creation_started_is_retained() {
  local dir state claim generation fake old_path FM_SPAWN_CLAIM_RECOVERY_SECS
  dir="$TMP_ROOT/spawn-creation-started-claim"
  state="$dir/state"
  mkdir -p "$state"
  generation=lifecycle-one
  fm_write_meta "$state/task.meta" "generation=$generation" 'window=session:fm-task' 'kind=scout'
  fm_reconcile_spawn_claim "$state" task spawn-creating || fail "spawn claim setup failed"
  fm_reconcile_spawn_claim_mark_creation_started "$state" task spawn-creating tmux fm-task firstmate \
    || fail "spawn claim could not persist backend-creation phase"
  claim="$state/task.spawn-claim"
  assert_grep 'creation_phase=backend-creation' "$claim" "spawn claim omitted its creation phase"
  assert_grep 'backend=tmux' "$claim" "spawn claim omitted its backend"
  assert_grep 'backend_label=fm-task' "$claim" "spawn claim omitted its backend label"
  age_spawn_claim "$claim"
  FM_SPAWN_CLAIM_RECOVERY_SECS=9999999999
  if fm_reconcile_spawn_claim "$state" task replacement; then
    fail "replacement spawn discarded a dead claim after backend creation may have begun"
  fi
  assert_grep 'creation_phase=backend-creation' "$claim" "dead creation-phase claim was not retained"
  fake=$(make_absent_spawn_probe "$dir")
  old_path=$PATH
  PATH="$fake:$PATH"
  FM_SPAWN_CLAIM_RECOVERY_SECS=1
  fm_reconcile_spawn_claim "$state" task replacement \
    || fail "bounded creation-phase reconciliation did not accept proven backend absence"
  PATH=$old_path
  assert_no_grep 'creation_phase=' "$claim" "replacement claim retained stale creation ownership"
  fm_reconcile_spawn_claim_release "$state" task replacement || fail "replacement claim release failed"
  pass "dead creation claims remain fail-closed until bounded absence proof"
}

test_active_review_parks_once_past_stale_pause
test_notified_observation_does_not_mask_newer_live_transition
test_stopped_endpoint_without_claimed_done_wakes_once
test_same_repository_endpoint_replacement_preserves_working_baseline
test_positive_working_source_loss_wakes_past_stale_working_event
test_external_wait_completion_and_failures
test_live_process_with_unreadable_identity_fails_observation
test_unchanged_terminal_wait_does_not_mask_live_transition
test_signaled_predicate_is_not_reported_complete
test_unobservable_pause_fails_loudly_and_busy_stays_quiet
test_inflight_unregistered_blocked_wait_fails_loudly_once
test_unobservable_parked_wait_fails_loudly_once
test_unacknowledged_transition_is_not_replaced_by_newer_state
test_unacknowledged_transition_folds_newer_sparse_event
test_acknowledgement_race_preserves_notified_token
test_teardown_tombstone_prevents_record_resurrection
test_delivery_race_preserves_later_status_and_turn_events
test_restart_preserves_transition_dedup
test_stale_teardown_tombstone_stops_suppressing_observation
test_predicate_output_is_capped_with_exit_status_preserved
test_malformed_live_state_values_are_rejected
test_owned_command_does_not_override_first_terminal_observation
test_owned_command_overrides_older_persisted_idle
test_owned_command_overrides_historical_wait_events
test_registered_legacy_check_completes_once_in_reconciliation
test_unmanaged_legacy_check_remains_supported_with_generation_metadata
test_stderr_only_success_does_not_complete_waits
test_legacy_check_registration_requires_atomic_commit
test_failed_legacy_check_output_is_failure
test_repository_identity_failure_preserves_proven_binding
test_lifecycle_generation_prevents_metadata_aba_publication
test_delivery_version_is_unique_across_task_lifecycles
test_process_identity_toctou_classifies_exit_as_complete
test_owned_command_observation_races_classify_exit_as_complete
test_owned_command_revalidates_identity_after_progress_observation
test_owned_command_cannot_mask_newer_terminal_state
test_generation_cas_and_spawn_claim_revalidate_lifecycle
test_teardown_claim_is_live_and_generation_bound
test_teardown_refuses_active_spawn_claim
test_partial_spawn_rescue_claim_survives_owner_exit
test_treehouse_rescue_reconciles_by_persisted_holder
test_spawn_claim_rechecks_endpoint_after_treehouse_absence
test_dead_spawn_claim_after_creation_started_is_retained

echo "# fm-reconcile-lib.test.sh: all assertions passed"
