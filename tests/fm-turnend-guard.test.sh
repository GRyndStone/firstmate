#!/usr/bin/env bash
# Behavior tests for the primary turn-end supervision guard (docs/turnend-guard.md).
#
# Two layers:
#   PREDICATE  - bin/fm-supervision-lib.sh, the shared beacon/status computation
#                used by fm-guard.sh and by the hook's banner details.
#   HOOK       - bin/fm-turnend-guard.sh, the shared primary hook predicate that
#                scopes in-flight work to the PRIMARY checkout only and requires
#                a live, identity-matched watcher plus turn-surviving owner provenance.
# All hermetic over temp dirs; no real agent session is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-supervision-lib.sh
. "$ROOT/bin/fm-supervision-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-turnend-guard)
fm_git_identity fmtest fmtest@example.invalid

REQUIRED_REASON='resume supervision with bin/fm-watch-arm.sh as its own Claude Code background task'

# --- PREDICATE: bin/fm-supervision-lib.sh -----------------------------------

test_predicate_healthy_no_inflight() {
  local state="$TMP_ROOT/pred-empty/state"
  mkdir -p "$state"
  if fm_supervision_unhealthy "$state" 300; then
    fail "predicate reported unhealthy with zero in-flight tasks"
  fi
  [ "$FM_SUP_IN_FLIGHT" -eq 0 ] || fail "expected zero in-flight, got $FM_SUP_IN_FLIGHT"
  pass "fm_supervision_unhealthy: false with no state/*.meta at all"
}

test_predicate_unhealthy_no_beacon() {
  local state="$TMP_ROOT/pred-nobeat/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  fm_supervision_unhealthy "$state" 300 || fail "predicate did not fire: in-flight task, beacon never seen"
  [ "$FM_SUP_IN_FLIGHT" -eq 1 ] || fail "expected 1 in-flight, got $FM_SUP_IN_FLIGHT"
  [ "$FM_SUP_WATCHER_FRESH" = false ] || fail "beacon absent must not read as fresh"
  [ "$FM_SUP_BEACON_DESC" = never ] || fail "beacon description should be 'never', got $FM_SUP_BEACON_DESC"
  pass "fm_supervision_unhealthy: true with in-flight task and no beacon ever"
}

test_predicate_unhealthy_stale_beacon() {
  local state="$TMP_ROOT/pred-stale/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  touch -t 202001010000 "$state/.last-watcher-beat"
  fm_supervision_unhealthy "$state" 300 || fail "predicate did not fire: in-flight task, beacon far outside grace"
  [ "$FM_SUP_WATCHER_FRESH" = false ] || fail "an ancient beacon must not read as fresh"
  pass "fm_supervision_unhealthy: true with in-flight task and a beacon far outside the grace window"
}

test_predicate_healthy_fresh_beacon() {
  local state="$TMP_ROOT/pred-fresh/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  touch "$state/.last-watcher-beat"
  if fm_supervision_unhealthy "$state" 300; then
    fail "predicate fired despite a fresh beacon"
  fi
  [ "$FM_SUP_WATCHER_FRESH" = true ] || fail "a beacon touched just now must read as fresh"
  pass "fm_supervision_unhealthy: false with in-flight task and a fresh beacon"
}

test_predicate_queue_pending_flag() {
  local state="$TMP_ROOT/pred-queue/state"
  mkdir -p "$state"
  fm_supervision_status "$state" 300
  [ "$FM_SUP_QUEUE_PENDING" = false ] || fail "empty/absent wake queue must not read as pending"
  printf 'record\n' > "$state/.wake-queue"
  fm_supervision_status "$state" 300
  [ "$FM_SUP_QUEUE_PENDING" = true ] || fail "a non-empty wake queue must read as pending"
  pass "fm_supervision_status: FM_SUP_QUEUE_PENDING tracks state/.wake-queue"
}

# --- HOOK: bin/fm-turnend-guard.sh ------------------------------------------
#
# Each scenario gets its own directory carrying a copy of the two guard scripts
# under bin/, so the hook (invoked by absolute path) resolves its own FM_ROOT to
# that scenario dir regardless of the test's cwd.

install_guard_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard.sh"
  cp "$ROOT/bin/fm-turnend-guard-grok.sh" "$dir/bin/fm-turnend-guard-grok.sh"
  cp "$ROOT/bin/fm-turnend-guard-grok-deliver.sh" "$dir/bin/fm-turnend-guard-grok-deliver.sh"
  cp "$ROOT/bin/fm-supervision-instructions.sh" "$dir/bin/fm-supervision-instructions.sh"
  cp "$ROOT/bin/fm-harness.sh" "$dir/bin/fm-harness.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  mkdir -p "$dir/docs"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard-grok.sh" "$dir/bin/fm-turnend-guard-grok-deliver.sh" "$dir/bin/fm-supervision-instructions.sh" "$dir/bin/fm-harness.sh"
}

mark_codex_hook_root() {
  local dir=$1
  mkdir -p "$dir/.codex"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"fm-turnend-guard.sh"}]}]}}\n' > "$dir/.codex/hooks.json"
}

# A primary-shaped checkout: plain (non-worktree) git repo, AGENTS.md, bin/,
# state/ - everything the hook's scoping check requires to treat it as primary.
make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf '%s\n' "$dir"
}

make_adapter_primary_repo() {
  local dir=$1
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
}

# Same shape as primary, plus the .fm-secondmate-home marker bin/fm-home-seed.sh
# writes at seed time (regardless of treehouse-lease or git-clone acquisition).
make_secondmate_dir() {
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  printf 'sm-test-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# A genuine linked `git worktree` of a base repo - the shape bin/fm-spawn.sh
# always hands crewmate/scout tasks working on firstmate itself. git-dir and
# git-common-dir differ here, unlike a plain checkout.
make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/turnend-guard-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf '%s\n' "$dir"
}

run_hook() {
  local dir=$1 stop_active=$2 home
  home=$(cd "$dir" && pwd)
  printf '{"stop_hook_active":%s}' "$stop_active" | CLAUDECODE=1 FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1
}

nonexistent_pid() {
  local pid=999999
  while kill -0 "$pid" 2>/dev/null; do
    pid=$((pid + 1))
  done
  printf '%s\n' "$pid"
}

watcher_identity() {
  local dir=$1 pid=$2
  FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$dir/bin/fm-wake-lib.sh" "$pid"
}

record_watcher_lock() {
  local dir=$1 pid=$2 identity=$3 kind=${4:-} owner_pid=${5:-} owner_identity=${6:-} mode=${7:-} root bin_dir
  root=$(cd "$dir" && pwd)
  bin_dir=$(cd "$dir/bin" && pwd)
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$root" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$bin_dir/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
  if [ -n "$kind" ]; then
    printf '%s\n' "$kind" > "$dir/state/.watch.lock/owner-kind"
    printf '%s\n' "$mode" > "$dir/state/.watch.lock/owner-mode"
    printf '%s\n' "$owner_pid" > "$dir/state/.watch.lock/owner-pid"
    printf '%s\n' "$owner_identity" > "$dir/state/.watch.lock/owner-identity"
  fi
}

test_hook_silent_when_no_work_in_flight() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-idle")
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "hook must exit 0 with no in-flight work"
  [ -z "$out" ] || fail "hook produced output with no in-flight work: $out"
  pass "fm-turnend-guard: silent no-op with nothing in flight"
}

test_hook_blocks_when_fresh_beacon_has_no_live_lock() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-fresh-no-lock")
  : > "$dir/state/task1.meta"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block when a fresh beacon has no live watcher lock"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks when a fresh beacon has no live watcher lock"
}

test_hook_blocks_when_dead_lock_has_fresh_beacon() {
  local dir dead out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-dead-lock-fresh")
  dead=$(nonexistent_pid)
  : > "$dir/state/task1.meta"
  record_watcher_lock "$dir" "$dead" "dead watcher identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block when the watcher lock pid is dead despite a fresh beacon"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks on a dead watcher lock even when the beacon is fresh"
}

test_hook_silent_with_live_lock_and_fresh_beacon() {
  local dir pid identity owner_pid owner_identity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-live-lock-fresh")
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  sleep 60 &
  owner_pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  owner_identity=$(watcher_identity "$dir" "$owner_pid") || {
    kill "$pid" "$owner_pid" 2>/dev/null || true
    wait "$pid" "$owner_pid" 2>/dev/null || true
    fail "could not identify live watcher owner"
  }
  record_watcher_lock "$dir" "$pid" "$identity" arm "$owner_pid" "$owner_identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  kill "$pid" "$owner_pid" 2>/dev/null || true
  wait "$pid" "$owner_pid" 2>/dev/null || true
  expect_code 0 "$status" "hook must exit 0 with a live watcher and verified durable arm owner"
  [ -z "$out" ] || fail "hook produced output despite a durable live watcher owner: $out"
  pass "fm-turnend-guard: silent no-op with a verified durable watcher owner"
}

test_hook_accepts_only_active_away_inject_daemon() {
  local dir pid identity owner_pid owner_identity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-daemon-owner")
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  sleep 60 &
  owner_pid=$!
  identity=$(watcher_identity "$dir" "$pid") || fail "could not identify daemon watcher"
  owner_identity=$(watcher_identity "$dir" "$owner_pid") || fail "could not identify daemon owner"
  record_watcher_lock "$dir" "$pid" "$identity" daemon "$owner_pid" "$owner_identity" monitor-only
  touch "$dir/state/.last-watcher-beat"

  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "daemon ownership must not authorize stop in a non-injecting mode"
  assert_contains "$out" "daemon owner or its injection target is not active" "non-injecting daemon rejection was not explained"

  printf '%s\n' away-inject > "$dir/state/.watch.lock/owner-mode"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "away-inject daemon ownership must not authorize stop while away mode is inactive"
  assert_contains "$out" "daemon owner or its injection target is not active" "inactive daemon rejection was not explained"

  : > "$dir/state/.afk"
  printf '%s\n' "$owner_pid" > "$dir/state/.supervise-daemon.pid"
  mkdir -p "$dir/state/.supervise-daemon.lock.owner.test"
  ln -s "$dir/state/.supervise-daemon.lock.owner.test" "$dir/state/.supervise-daemon.lock"
  printf '%s\n' "$owner_pid" > "$dir/state/.supervise-daemon.lock.owner.test/pid"
  printf '%s\n' "$owner_identity" > "$dir/state/.supervise-daemon.lock.owner.test/pid-identity"
  printf '%s\n' tmux > "$dir/state/.supervise-daemon.lock.owner.test/supervisor-backend"
  printf '%s\n' '%99' > "$dir/state/.supervise-daemon.lock.owner.test/supervisor-target"
  cat > "$dir/bin/fm-backend.sh" <<'SH'
#!/usr/bin/env bash
fm_backend_target_exists() {
  [ "$1" = tmux ] && [ -n "$2" ] && [ -f "$FM_HOME/state/.test-supervisor-target-live" ]
}
fm_backend_agent_alive() {
  if [ "$1" = tmux ] && [ -n "$2" ] && [ -f "$FM_HOME/state/.test-supervisor-agent-live" ]; then
    printf 'alive'
  else
    printf 'dead'
  fi
}
SH
  : > "$dir/state/.test-supervisor-target-live"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "away-inject daemon with a live bare-shell pane must not authorize stop"
  assert_contains "$out" "daemon owner or its injection target is not active" "bare-shell daemon target rejection was not explained"

  : > "$dir/state/.test-supervisor-agent-live"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "active away-inject daemon ownership with a live agent injection target must authorize stop"
  [ -z "$out" ] || fail "active away-inject daemon produced output: $out"

  printf '%s\n' firstmate:0 > "$dir/state/.supervise-daemon.lock.owner.test/supervisor-target"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "recyclable tmux selector must not authorize daemon supervision"
  assert_contains "$out" "daemon owner or its injection target is not active" "recyclable daemon target rejection was not explained"
  printf '%s\n' '%99' > "$dir/state/.supervise-daemon.lock.owner.test/supervisor-target"

  rm -f "$dir/state/.test-supervisor-target-live"
  out=$(run_hook "$dir" false); status=$?
  kill "$pid" "$owner_pid" 2>/dev/null || true
  wait "$pid" "$owner_pid" 2>/dev/null || true
  expect_code 2 "$status" "away-inject daemon with a dead injection target must not authorize stop"
  assert_contains "$out" "daemon owner or its injection target is not active" "dead daemon injection target rejection was not explained"
  pass "fm-turnend-guard: daemon ownership is bound to active away-inject mode and a live agent injection target"
}

test_hook_blocks_live_foreground_checkpoint_then_blocks_retry() {
  local dir watcher_pid watcher_identity owner_pid owner_identity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-live-foreground-checkpoint")
  : > "$dir/state/task1.meta"
  sleep 60 &
  watcher_pid=$!
  sleep 60 &
  owner_pid=$!
  watcher_identity=$(watcher_identity "$dir" "$watcher_pid") || fail "could not identify checkpoint watcher"
  owner_identity=$(watcher_identity "$dir" "$owner_pid") || fail "could not identify checkpoint owner"
  record_watcher_lock "$dir" "$watcher_pid" "$watcher_identity" checkpoint "$owner_pid" "$owner_identity"
  touch "$dir/state/.last-watcher-beat"

  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "live foreground checkpoint must not satisfy turn-surviving supervision"
  assert_contains "$out" "foreground checkpoint owner cannot survive turn yield" "guard did not explain rejected checkpoint provenance"

  kill "$watcher_pid" "$owner_pid" 2>/dev/null || true
  wait "$watcher_pid" "$owner_pid" 2>/dev/null || true
  out=$(run_hook "$dir" true); status=$?
  expect_code 2 "$status" "retry must remain blocked after the yielded checkpoint dies"
  assert_contains "$out" "prior forced continuation did not establish durable ownership" "retry did not explain the state transition"
  pass "fm-turnend-guard: foreground checkpoint cannot authorize a blind yield or retry"
}

test_hook_blocks_with_live_lock_and_stale_beacon() {
  local dir pid identity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-live-lock-stale")
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "hook must block when a live watcher lock has an ancient beacon"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks on a live watcher lock with an ancient beacon"
}

test_hook_blocks_when_unhealthy_in_primary() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-block")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block (exit 2) when in-flight work has no live watcher"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  assert_contains "$out" "TURN WOULD END BLIND" "block banner must read as an alarm"
  pass "fm-turnend-guard: blocks with the exact required reason in the primary when unhealthy"
}

test_hook_blocks_from_fm_home_state() {
  local dir home out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-fm-home")
  home="$TMP_ROOT/hook-fm-home-op"
  mkdir -p "$home/state"
  : > "$home/state/task1.meta"
  out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 2 "$status" "hook must inspect the active FM_HOME state dir"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks from active FM_HOME state, not only repo-root state"
}

test_hook_x_mode_reason_sources_cadence() {
  local dir home out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-x-mode")
  home=$(cd "$dir" && pwd)
  mkdir -p "$dir/config"
  : > "$dir/config/x-mode.env"
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block when in-flight X-mode work has no live watcher"
  assert_contains "$out" "source '$home/config/x-mode.env' first" "block reason must source the effective X-mode cadence"
  pass "fm-turnend-guard: X-mode repair reason sources the cadence config"
}

test_hook_ignores_repo_state_when_fm_home_set() {
  local dir home out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-fm-home-ignore-root")
  home="$TMP_ROOT/hook-fm-home-quiet"
  mkdir -p "$home/state"
  : > "$dir/state/task1.meta"
  out=$(printf '{"stop_hook_active":false}' | FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "hook must ignore repo-root state when FM_HOME selects another state dir"
  [ -z "$out" ] || fail "hook produced output from stale repo-root state despite FM_HOME: $out"
  pass "fm-turnend-guard: ignores stale repo-root state when FM_HOME is set"
}

test_hook_uses_state_override() {
  local dir home state out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-state-override")
  home="$TMP_ROOT/hook-state-override-home"
  state="$TMP_ROOT/hook-state-override-active"
  mkdir -p "$home/state" "$state"
  : > "$state/task1.meta"
  out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 2 "$status" "hook must let FM_STATE_OVERRIDE win over FM_HOME/state"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: uses FM_STATE_OVERRIDE ahead of FM_HOME/state"
}

test_hook_retry_requires_durable_ownership() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-loopguard")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" true); status=$?
  expect_code 2 "$status" "hook retry must remain blocked without durable ownership"
  assert_contains "$out" "prior forced continuation did not establish durable ownership" "retry state was not surfaced"
  pass "fm-turnend-guard: retry cannot end blind without durable ownership"
}

test_hook_surfaces_bounded_parked_and_idle_tasks() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-attention-detail")
  : > "$dir/state/parked-task.meta"
  : > "$dir/state/paused-task.meta"
  : > "$dir/state/working-task.meta"
  : > "$dir/state/y-working-task.meta"
  : > "$dir/state/z-late-parked.meta"
  cat > "$dir/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  parked-task) printf 'state: parked · source: run-step · parked at review\n' ;;
  paused-task) printf 'state: paused · source: status-log · external wait\n' ;;
  z-late-parked) printf 'state: parked · source: run-step · late parked task\n' ;;
  *) printf 'state: working · source: pane · harness busy\n' ;;
esac
SH
  chmod +x "$dir/bin/fm-crew-state.sh"
  out=$(FM_TURNEND_DETAIL_LIMIT=2 run_hook "$dir" false); status=$?
  expect_code 2 "$status" "unhealthy guard must block while surfacing task detail"
  assert_contains "$out" "parked-task=parked" "parked task id/state was omitted"
  assert_contains "$out" "paused-task=paused" "idle paused task id/state was omitted"
  assert_not_contains "$out" "working-task=working" "working task polluted parked/idle detail"
  assert_contains "$out" "0 additional non-working task(s) omitted; 1 task(s) unprobed" "bounded detail omitted-count disclosure was not exact"
  pass "fm-turnend-guard: fail-closed banner includes bounded parked and idle task detail"
}

test_hook_silent_in_secondmate_home() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/hook-secondmate")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "hook must never block inside a secondmate home"
  [ -z "$out" ] || fail "hook produced output inside a secondmate home: $out"
  pass "fm-turnend-guard: inert in a secondmate home (.fm-secondmate-home marker present) even when unhealthy"
}

test_hook_silent_in_crewmate_worktree() {
  local base dir out status
  base="$TMP_ROOT/hook-crew-base"
  dir="$TMP_ROOT/hook-crew-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "hook must never block inside a crewmate task worktree"
  [ -z "$out" ] || fail "hook produced output inside a crewmate task worktree: $out"
  pass "fm-turnend-guard: inert in a crewmate/scout task worktree (linked git worktree) even when unhealthy"
}

test_hook_blocks_without_jq() {
  local dir out status fakebin tool tool_path
  dir=$(make_primary_dir "$TMP_ROOT/hook-nojq")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/hook-nojq-fake")
  for tool in bash sh git cat printf date uname stat mkdir dirname tr basename ps sed; do
    tool_path=$(command -v "$tool") || fail "test host must provide $tool"
    ln -s "$tool_path" "$fakebin/$tool"
  done
  out=$(printf '{"stop_hook_active":false}' | PATH="$fakebin" bash "$dir/bin/fm-turnend-guard.sh" 2>&1)
  status=$?
  expect_code 2 "$status" "hook must fail closed when jq is unavailable and work is in flight"
  assert_contains "$out" "TURN WOULD END BLIND" "missing-jq path did not run the shared predicate"
  pass "fm-turnend-guard: missing jq cannot bypass the shared predicate"
}

test_hook_blocks_without_stdin() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-nostdin")
  : > "$dir/state/task1.meta"
  out=$(bash "$dir/bin/fm-turnend-guard.sh" < /dev/null 2>&1); status=$?
  expect_code 2 "$status" "hook must fail closed on empty stdin when work is in flight"
  assert_contains "$out" "TURN WOULD END BLIND" "empty-input path did not run the shared predicate"
  pass "fm-turnend-guard: empty input cannot bypass the shared predicate"
}

test_hook_blocks_with_malformed_stdin() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-malformed-stdin")
  : > "$dir/state/task1.meta"
  out=$(printf '{not-json' | bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 2 "$status" "hook must fail closed on malformed stdin when work is in flight"
  assert_contains "$out" "TURN WOULD END BLIND" "malformed-input path did not run the shared predicate"
  pass "fm-turnend-guard: malformed input cannot bypass the shared predicate"
}

test_hook_runs_fast() {
  local dir start elapsed_s
  dir=$(make_primary_dir "$TMP_ROOT/hook-timing")
  : > "$dir/state/task1.meta"
  start=$SECONDS
  run_hook "$dir" false >/dev/null
  elapsed_s=$((SECONDS - start))
  [ "$elapsed_s" -lt 3 ] || fail "hook took ${elapsed_s}s, expected well under a second (generous 3s CI margin)"
  pass "fm-turnend-guard: runs well under the generous timing margin (${elapsed_s}s)"
}

test_grok_adapter_forces_one_resume_when_unhealthy() {
  local dir fakebin log out status i pending delivery
  dir=$(make_primary_dir "$TMP_ROOT/grok-adapter-block")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-adapter-fakebin")
  log="$TMP_ROOT/grok-adapter-call.log"
  cat > "$fakebin/grok" <<EOF
#!/usr/bin/env bash
{
  printf 'active=%s\n' "\${GROK_TURNEND_GUARD_ACTIVE:-}"
  printf 'home=%s\n' "\${GROK_HOME:-}"
  printf 'args:'
  for arg in "\$@"; do
    printf ' <%s>' "\$arg"
  done
  printf '\n'
} >> "$log"
EOF
  chmod +x "$fakebin/grok"
  out=$(printf '{"sessionId":"session-test","hookEventName":"stop"}' | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" FM_GROK_TURNEND_DELAY=1 bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "grok adapter must durably queue a forced resume"
  [ -z "$out" ] || fail "grok adapter printed output: $out"
  [ ! -e "$log" ] || fail "Grok continuation ran recursively before the Stop hook returned"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$log" ] && break
    sleep 0.1
  done
  [ -s "$log" ] || fail "grok adapter did not run the deferred continuation"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    pending=$(find "$dir/state/.turnend-handoffs" -name 'grok-*.pending' -print -quit 2>/dev/null)
    delivery=$(find "$dir/state/.turnend-handoffs" -name 'grok-*.delivery' -print -quit 2>/dev/null)
    [ -z "$pending" ] && [ -z "$delivery" ] && break
    sleep 0.1
  done
  assert_contains "$(cat "$log")" '<--resume>' "grok adapter must resume the current session"
  assert_contains "$(cat "$log")" '<session-test>' "grok adapter must pass the hook session id"
  assert_not_contains "$(cat "$log")" '<--permission-mode>' "grok adapter must not add a stronger permission mode"
  assert_not_contains "$(cat "$log")" '<bypassPermissions>' "grok adapter must not bypass permissions on forced resume"
  assert_contains "$(cat "$log")" 'TURN WOULD END BLIND' "grok adapter must carry the guard reason into the forced resume"
  [ -z "$pending" ] || fail "successful Grok continuation left a pending handoff"
  [ -z "$delivery" ] || fail "successful Grok continuation left a delivery lock"
  pass "fm-turnend-guard-grok: schedules one bounded same-session resume after the Stop hook returns"
}

test_grok_adapter_repeats_resume_when_still_blind() {
  local dir fakebin log guard_log out status i
  dir=$(make_primary_dir "$TMP_ROOT/grok-adapter-loop")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-adapter-loop-fakebin")
  log="$TMP_ROOT/grok-adapter-loop-call.log"
  guard_log="$TMP_ROOT/grok-adapter-loop-guard.log"
  cat > "$fakebin/grok" <<EOF
#!/usr/bin/env bash
printf 'called\n' >> "$log"
EOF
  chmod +x "$fakebin/grok"
  cat > "$dir/bin/fm-turnend-guard.sh" <<EOF
#!/usr/bin/env bash
cat >/dev/null
printf 'guard\n' >> "$guard_log"
exit 2
EOF
  chmod +x "$dir/bin/fm-turnend-guard.sh"
  out=$(printf '{"sessionId":"session-test","hookEventName":"stop"}' | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" GROK_TURNEND_GUARD_ACTIVE=1 FM_GROK_TURNEND_DELAY=0 bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "grok adapter must queue another continuation after a still-blind forced turn"
  [ -z "$out" ] || fail "grok adapter printed output on repeated continuation: $out"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$log" ] && break
    sleep 0.1
  done
  [ "$(cat "$log")" = called ] || fail "Grok follow-up discarded a still-blocking predicate result"
  [ "$(cat "$guard_log")" = guard ] || fail "Grok follow-up skipped the shared predicate"
  pass "fm-turnend-guard-grok: every still-blind Stop schedules another continuation"
}

test_grok_adapter_preserves_failed_delivery_handoff() {
  local dir fakebin attempts out status i pending attempt_count
  dir=$(make_primary_dir "$TMP_ROOT/grok-adapter-delivery-failure")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-adapter-delivery-failure-fakebin")
  attempts="$TMP_ROOT/grok-adapter-delivery-failure-attempts"
  cat > "$fakebin/grok" <<EOF
#!/usr/bin/env bash
printf 'attempt\n' >> "$attempts"
[ "\$(wc -l < "$attempts" | tr -d ' ')" -ge 2 ]
EOF
  chmod +x "$fakebin/grok"
  out=$(printf '{"sessionId":"session-failure","hookEventName":"stop"}' | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" FM_GROK_TURNEND_DELAY=0 FM_GROK_TURNEND_RETRY_DELAY=1 bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "grok adapter must return after durably scheduling delivery"
  [ -z "$out" ] || fail "grok adapter printed output while scheduling failed delivery: $out"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$attempts" ] && break
    sleep 0.1
  done
  [ -s "$attempts" ] || fail "failed Grok continuation was never attempted"
  pending=$(find "$dir/state/.turnend-handoffs" -name 'grok-*.pending' -print -quit 2>/dev/null)
  [ -n "$pending" ] || fail "failed Grok continuation did not retain its durable pending handoff"
  assert_contains "$(cat "$pending")" "session-failure" "Grok pending handoff lost its exact session id"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    attempt_count=$(wc -l < "$attempts" | tr -d ' ')
    pending=$(find "$dir/state/.turnend-handoffs" -name 'grok-*.pending' -print -quit 2>/dev/null)
    [ "$attempt_count" -ge 2 ] && [ -z "$pending" ] && break
    sleep 0.1
  done
  [ "$attempt_count" -ge 2 ] || fail "Grok failed delivery lost its live retry owner"
  [ -z "$pending" ] || fail "successful Grok retry did not clear the acknowledged handoff"
  pass "fm-turnend-guard-grok: failed deferred delivery retains retry ownership"
}

test_grok_worker_waits_for_originating_hook_exit() {
  local dir fakebin log pending origin_pid origin_identity worker_pid i
  dir=$(make_primary_dir "$TMP_ROOT/grok-origin-barrier")
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-origin-barrier-fakebin")
  log="$TMP_ROOT/grok-origin-barrier.log"
  cat > "$fakebin/grok" <<EOF
#!/usr/bin/env bash
printf 'called\n' >> "$log"
EOF
  chmod +x "$fakebin/grok"
  sleep 1 &
  origin_pid=$!
  origin_identity=$(. "$dir/bin/fm-wake-lib.sh"; fm_pid_identity "$origin_pid")
  mkdir -p "$dir/state/.turnend-handoffs"
  pending="$dir/state/.turnend-handoffs/grok-origin.pending"
  {
    printf 'origin-token\n%s\n%s\nsession-origin\norigin barrier\n' "$origin_pid" "$origin_identity"
  } > "$pending"
  PATH="$fakebin:$PATH" FM_GROK_TURNEND_DELAY=0 FM_GROK_TURNEND_RETRY_DELAY=1 bash "$dir/bin/fm-turnend-guard-grok-deliver.sh" "$pending" "$dir" &
  worker_pid=$!
  sleep 0.2
  [ ! -e "$log" ] || fail "Grok resume began while the originating Stop hook identity was alive"
  wait "$origin_pid"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$log" ] && break
    sleep 0.1
  done
  wait "$worker_pid"
  [ -s "$log" ] || fail "Grok resume did not start after the originating hook exited"
  pass "fm-turnend-guard-grok: resume waits for originating Stop-hook process exit"
}

test_grok_session_delivery_is_singleton() {
  local dir fakebin calls active overlap first_status second_status first_pid second_pid i
  dir=$(make_primary_dir "$TMP_ROOT/grok-session-singleton")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-session-singleton-fakebin")
  calls="$TMP_ROOT/grok-session-singleton-calls"
  active="$TMP_ROOT/grok-session-singleton-active"
  overlap="$TMP_ROOT/grok-session-singleton-overlap"
  cat > "$fakebin/grok" <<EOF
#!/usr/bin/env bash
if ! mkdir "$active" 2>/dev/null; then
  : > "$overlap"
  exit 1
fi
printf 'called\n' >> "$calls"
sleep 0.4
rmdir "$active"
EOF
  chmod +x "$fakebin/grok"
  (
    printf '{"sessionId":"session-singleton","hookEventName":"stop"}' \
      | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" FM_GROK_TURNEND_DELAY=0 bash "$dir/bin/fm-turnend-guard-grok.sh" >/dev/null 2>&1
    printf '%s\n' "$?" > "$TMP_ROOT/grok-session-singleton-first.status"
  ) &
  first_pid=$!
  (
    printf '{"sessionId":"session-singleton","hookEventName":"stop"}' \
      | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" FM_GROK_TURNEND_DELAY=0 bash "$dir/bin/fm-turnend-guard-grok.sh" >/dev/null 2>&1
    printf '%s\n' "$?" > "$TMP_ROOT/grok-session-singleton-second.status"
  ) &
  second_pid=$!
  wait "$first_pid"
  wait "$second_pid"
  first_status=$(cat "$TMP_ROOT/grok-session-singleton-first.status")
  second_status=$(cat "$TMP_ROOT/grok-session-singleton-second.status")
  expect_code 0 "$first_status" "first concurrent Grok Stop must acquire or observe singleton ownership"
  expect_code 0 "$second_status" "second concurrent Grok Stop must acquire or observe singleton ownership"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$calls" ] && [ ! -d "$active" ] && break
    sleep 0.1
  done
  [ ! -e "$overlap" ] || fail "same-session Grok resumes overlapped"
  [ "$(wc -l < "$calls" | tr -d ' ')" -eq 1 ] || fail "concurrent same-session Stops replaced an acknowledged singleton owner"
  pass "fm-turnend-guard-grok: pending replacement and token readiness are one serialized transition"
}

test_grok_healthy_stop_invalidates_stale_pending() {
  local dir fakebin started release out status i pending delivery
  dir=$(make_primary_dir "$TMP_ROOT/grok-stale-pending")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-stale-pending-fakebin")
  started="$TMP_ROOT/grok-stale-pending-started"
  release="$TMP_ROOT/grok-stale-pending-release"
  cat > "$fakebin/grok" <<EOF
#!/usr/bin/env bash
: > "$started"
while [ ! -f "$release" ]; do sleep 0.05; done
exit 1
EOF
  chmod +x "$fakebin/grok"
  out=$(printf '{"sessionId":"session-recovered","hookEventName":"stop"}' | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" FM_GROK_TURNEND_DELAY=0 FM_GROK_TURNEND_RETRY_DELAY=1 bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "blind Grok Stop must queue retained work"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$started" ] && break
    sleep 0.1
  done
  [ -f "$started" ] || fail "stale-pending setup never entered delivery"
  cat > "$dir/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 0
SH
  chmod +x "$dir/bin/fm-turnend-guard.sh"
  out=$(printf '{"sessionId":"session-recovered","hookEventName":"stop"}' | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "healthy Grok Stop must invalidate retained work"
  pending=$(find "$dir/state/.turnend-handoffs" -name 'grok-*.pending' -print -quit 2>/dev/null)
  [ -z "$pending" ] || fail "healthy Grok Stop retained an obsolete handoff"
  : > "$release"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    delivery=$(find "$dir/state/.turnend-handoffs" -name 'grok-*.delivery' -print -quit 2>/dev/null)
    [ -z "$delivery" ] && break
    sleep 0.1
  done
  [ -z "$delivery" ] || fail "stale Grok retry owner did not stop after recovery"
  pass "fm-turnend-guard-grok: healthy Stop invalidates stale pending delivery"
}

test_grok_missing_guard_fails_closed_through_retry_owner() {
  local dir fakebin log out status i pending delivery
  dir=$(make_primary_dir "$TMP_ROOT/grok-missing-guard")
  : > "$dir/state/task1.meta"
  rm -f "$dir/bin/fm-turnend-guard.sh"
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-missing-guard-fakebin")
  log="$TMP_ROOT/grok-missing-guard.log"
  cat > "$fakebin/grok" <<EOF
#!/usr/bin/env bash
printf 'args:' >> "$log"
for arg in "\$@"; do printf ' <%s>' "\$arg" >> "$log"; done
printf '\n' >> "$log"
EOF
  chmod +x "$fakebin/grok"
  out=$(printf '{"sessionId":"session-missing-guard","hookEventName":"stop"}' | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" FM_GROK_TURNEND_DELAY=0 bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "known Grok primary with a missing shared guard must queue fail-closed delivery"
  [ -z "$out" ] || fail "missing-guard Grok adapter printed output: $out"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$log" ] && break
    sleep 0.1
  done
  [ -s "$log" ] || fail "missing shared guard did not start Grok's retry owner"
  assert_contains "$(cat "$log")" "shared turn-end guard is unavailable" "Grok missing-guard continuation lost its fail-closed reason"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    pending=$(find "$dir/state/.turnend-handoffs" -name 'grok-*.pending' -print -quit 2>/dev/null)
    delivery=$(find "$dir/state/.turnend-handoffs" -name 'grok-*.delivery' -print -quit 2>/dev/null)
    [ -z "$pending" ] && [ -z "$delivery" ] && break
    sleep 0.1
  done
  [ -z "$pending" ] && [ -z "$delivery" ] || fail "acknowledged missing-guard Grok handoff retained state"
  pass "fm-turnend-guard-grok: missing shared guard enters durable fail-closed delivery"
}

test_grok_handoff_preparation_failure_is_nonzero() {
  local dir fakebin out status
  dir=$(make_primary_dir "$TMP_ROOT/grok-handoff-preparation")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-handoff-preparation-fakebin")
  cat > "$fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/mktemp"
  out=$(printf '{"sessionId":"session-preparation-failure","hookEventName":"stop"}' | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "Grok handoff preparation failure exited healthy"
  pass "fm-turnend-guard-grok: handoff preparation failure is conservatively nonzero"
}

test_grok_missing_session_is_loud_unsupported_exception() {
  local dir fakebin log out status
  dir=$(make_primary_dir "$TMP_ROOT/grok-missing-session")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-missing-session-fakebin")
  log="$TMP_ROOT/grok-missing-session.log"
  cat > "$fakebin/grok" <<EOF
#!/usr/bin/env bash
printf 'args:' >> "$log"
for arg in "\$@"; do printf ' <%s>' "\$arg" >> "$log"; done
printf '\n' >> "$log"
EOF
  chmod +x "$fakebin/grok"
  out=$(printf '{"hookEventName":"stop"}' | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" FM_GROK_TURNEND_DELAY=0 bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "missing Grok session id is an explicit passive product exception"
  assert_contains "$out" 'UNSUPPORTED' "missing-session Grok exception was not loud"
  assert_contains "$out" 'exact sessionId' "missing-session Grok exception did not name the missing identity"
  [ ! -e "$log" ] || fail "missing Grok session id scheduled an ambiguous continuation"
  [ ! -d "$dir/state/.turnend-handoffs" ] || fail "missing Grok session id created handoff state"
  assert_not_contains "$out" '@continue' "missing-session Grok exception retained the ambiguous fallback"
  pass "fm-turnend-guard-grok: missing exact session identity fails open loudly without delivery"
}

test_grok_worker_launch_requires_token_readiness() {
  local dir fakebin out status
  dir=$(make_primary_dir "$TMP_ROOT/grok-worker-readiness")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-worker-readiness-fakebin")
  cat > "$dir/bin/fm-turnend-guard-grok-deliver.sh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$dir/bin/fm-turnend-guard-grok-deliver.sh"
  out=$(printf '{"sessionId":"readiness-failure","hookEventName":"stop"}' | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "Grok adapter accepted a worker that never acknowledged its token"
  [ -n "$(find "$dir/state/.turnend-handoffs" -name 'grok-*.pending' -print -quit 2>/dev/null)" ] \
    || fail "Grok readiness failure discarded the durable handoff"
  pass "fm-turnend-guard-grok: worker launch requires a token-bound readiness acknowledgement"
}

test_grok_worker_signal_reaps_delivery_children() {
  local dir fakebin pending ps_log real_ps worker_pid i candidates children child_count pid command timer_pid descendants
  dir=$(make_primary_dir "$TMP_ROOT/grok-signal-reap")
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-signal-reap-fakebin")
  cat > "$fakebin/grok" <<'SH'
#!/usr/bin/env bash
trap 'exit 1' TERM INT
while :; do sleep 1; done
SH
  chmod +x "$fakebin/grok"
  ps_log="$TMP_ROOT/grok-signal-ps.log"
  real_ps=$(command -v ps) || fail "signal-reap test requires ps"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
previous=
for argument in "$@"; do
  if [ "$previous" = -p ]; then
    printf '%s\n' "$argument" >> "${FM_TEST_PS_LOG:?}"
    break
  fi
  previous=$argument
done
exec "${FM_TEST_REAL_PS:?}" "$@"
SH
  chmod +x "$fakebin/ps"
  mkdir -p "$dir/state/.turnend-handoffs"
  pending="$dir/state/.turnend-handoffs/grok-signal.pending"
  printf 'signal-token\n999999\nmissing-origin\nsignal-session\nsignal cleanup\n' > "$pending"
  PATH="$fakebin:$PATH" FM_GROK_TURNEND_DELAY=0 FM_GROK_TURNEND_DELIVERY_TIMEOUT=120 \
    FM_TEST_PS_LOG="$ps_log" FM_TEST_REAL_PS="$real_ps" \
    bash "$dir/bin/fm-turnend-guard-grok-deliver.sh" "$pending" "$dir" signal-token &
  worker_pid=$!
  children=
  child_count=0
  for i in $(seq 1 100); do
    candidates=$(awk -v worker="$worker_pid" '$1 ~ /^[0-9]+$/ && $1 != worker && !seen[$1]++ { print $1 }' "$ps_log" 2>/dev/null || true)
    children=
    for pid in $candidates; do
      kill -0 "$pid" 2>/dev/null && children="${children}${children:+ }$pid"
    done
    child_count=$(printf '%s\n' "$children" | awk '{ count += NF } END { print count + 0 }')
    [ "$child_count" -ge 2 ] && break
    sleep 0.02
  done
  [ "$child_count" -ge 2 ] || fail "Grok signal-reap setup did not start both delivery children"
  timer_pid=
  for pid in $children; do
    command=$("$real_ps" -p "$pid" -o command= 2>/dev/null || true)
    case "$command" in
      *'sleep 1'*) timer_pid=$pid ;;
    esac
  done
  [ -n "$timer_pid" ] || fail "Grok signal-reap setup did not identify the direct timer child"
  descendants=$("$real_ps" -o pid= -P "$timer_pid" 2>/dev/null || true)
  [ -z "$(printf '%s' "$descendants" | tr -d '[:space:]')" ] \
    || fail "Grok timer child unexpectedly owned a descendant: $descendants"
  kill -TERM "$worker_pid"
  wait "$worker_pid" 2>/dev/null || true
  for pid in $children; do
    kill -0 "$pid" 2>/dev/null && fail "Grok worker signal left child $pid alive"
  done
  [ ! -e "$pending.delivery" ] || fail "Grok worker signal released children but retained its singleton lock"
  pass "fm-turnend-guard-grok: TERM reaps exact resume and timer children before lock release"
}

test_settings_hook_uses_claude_project_dir() {
  local settings command
  settings="$ROOT/.claude/settings.json"
  [ -f "$settings" ] || fail "tracked .claude/settings.json is missing"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "Stop hook command is missing from .claude/settings.json"
  assert_contains "$command" 'CLAUDE_PROJECT_DIR' "Stop hook must resolve via CLAUDE_PROJECT_DIR, not a cwd-relative path"
  assert_contains "$command" 'fm-turnend-guard.sh' "Stop hook must still invoke fm-turnend-guard.sh"
  case "$command" in
    bin/fm-turnend-guard.sh|./bin/fm-turnend-guard.sh)
      fail "Stop hook must not use a bare relative path (cwd-dependent): $command"
      ;;
  esac
  pass ".claude/settings.json: Stop hook uses CLAUDE_PROJECT_DIR-anchored command"
}

test_codex_hook_invokes_shared_guard() {
  local settings command
  settings="$ROOT/.codex/hooks.json"
  [ -f "$settings" ] || fail "tracked .codex/hooks.json is missing"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "Stop hook command is missing from .codex/hooks.json"
  assert_contains "$command" 'pwd -P' "codex hook must anchor from the hook process working directory"
  assert_contains "$command" '.codex/hooks.json' "codex hook must verify the hook-loaded firstmate root"
  assert_contains "$command" 'fm-turnend-guard.sh' "codex hook must invoke the shared guard"
  assert_not_contains "$command" '.cwd' "codex hook must not use payload cwd to select the guard executable"
  assert_not_contains "$command" 'command -v jq' "codex hook must not fail open when jq is unavailable"
  pass ".codex/hooks.json: Stop hook invokes the shared primary guard"
}

test_codex_hook_uses_process_pwd_when_payload_cwd_is_outside_root() {
  local settings command dir expected_root outside payload out status
  settings="$ROOT/.codex/hooks.json"
  [ -f "$settings" ] || fail "tracked .codex/hooks.json is missing"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "Stop hook command is missing from .codex/hooks.json"
  dir=$(make_primary_dir "$TMP_ROOT/codex-hook-root")
  mark_codex_hook_root "$dir"
  expected_root=$(cd "$dir" && pwd -P)
  outside="$TMP_ROOT/codex-hook-outside"
  mkdir -p "$outside"
  cat > "$dir/bin/fm-turnend-guard.sh" <<'EOF'
#!/usr/bin/env bash
printf 'guard=%s\n' "$0"
cat
EOF
  chmod +x "$dir/bin/fm-turnend-guard.sh"
  payload=$(jq -cn --arg cwd "$outside" '{cwd:$cwd,stop_hook_active:false}')
  out=$(printf '%s' "$payload" | (cd "$dir" && bash -c "$command") 2>&1); status=$?
  expect_code 0 "$status" "codex hook must execute successfully when payload cwd is outside the firstmate root"
  assert_contains "$out" "guard=$expected_root/bin/fm-turnend-guard.sh" "codex hook must use the hook process root"
  assert_contains "$out" "$payload" "codex hook must pass the original payload to the guard"
  pass ".codex/hooks.json: Stop hook uses hook process root when payload cwd is outside"
}

test_codex_hook_ignores_nested_git_root_guard() {
  local settings command dir nested subdir expected_root payload out status
  settings="$ROOT/.codex/hooks.json"
  [ -f "$settings" ] || fail "tracked .codex/hooks.json is missing"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "Stop hook command is missing from .codex/hooks.json"
  dir=$(make_primary_dir "$TMP_ROOT/codex-hook-outer")
  mark_codex_hook_root "$dir"
  expected_root=$(cd "$dir" && pwd -P)
  nested="$dir/projects/other"
  mkdir -p "$nested"
  git init -q "$nested"
  git -C "$nested" commit -q --allow-empty -m init
  mkdir -p "$nested/bin" "$nested/.codex"
  : > "$nested/AGENTS.md"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"fm-turnend-guard.sh"}]}]}}\n' > "$nested/.codex/hooks.json"
  cat > "$nested/bin/fm-turnend-guard.sh" <<'EOF'
#!/usr/bin/env bash
printf 'nested guard executed\n'
exit 99
EOF
  chmod +x "$nested/bin/fm-turnend-guard.sh"
  cat > "$dir/bin/fm-turnend-guard.sh" <<'EOF'
#!/usr/bin/env bash
printf 'guard=%s\n' "$0"
cat
EOF
  chmod +x "$dir/bin/fm-turnend-guard.sh"
  subdir="$nested/deep/path"
  mkdir -p "$subdir"
  payload=$(jq -cn --arg cwd "$subdir" '{cwd:$cwd,stop_hook_active:false}')
  out=$(printf '%s' "$payload" | (cd "$dir" && bash -c "$command") 2>&1); status=$?
  expect_code 0 "$status" "codex hook must not execute a nested project guard"
  assert_contains "$out" "guard=$expected_root/bin/fm-turnend-guard.sh" "codex hook must keep using the outer firstmate guard"
  assert_not_contains "$out" "nested guard executed" "codex hook must not execute nested project code"
  pass ".codex/hooks.json: Stop hook ignores nested git root guard scripts"
}

test_opencode_plugin_forces_followup() {
  local plugin content
  plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  [ -f "$plugin" ] || fail "tracked OpenCode primary plugin is missing"
  content=$(cat "$plugin")
  assert_contains "$content" 'session.idle' "OpenCode plugin must run on session.idle"
  assert_contains "$content" 'fm-turnend-guard.sh' "OpenCode plugin must invoke the shared guard"
  assert_contains "$content" 'promptAsync' "OpenCode plugin must force a follow-up turn"
  assert_contains "$content" 'followupDeliveryActive' "OpenCode plugin must deduplicate only overlapping SDK delivery"
  assert_contains "$content" '.turnend-handoffs' "OpenCode plugin must persist failed continuation delivery"
  assert_not_contains "$content" 'skipNextIdle' "OpenCode plugin must not skip the predicate after its follow-up"
  assert_contains "$content" 'worktree' "OpenCode plugin must anchor the guard from the git worktree path"
  pass ".opencode primary plugin: session.idle forces one follow-up through the shared guard"
}

test_opencode_plugin_anchors_guard_to_worktree() {
  local plugin worktree_dir wrong_dir log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  [ -f "$plugin" ] || fail "tracked OpenCode primary plugin is missing"
  worktree_dir="$TMP_ROOT/opencode-plugin-worktree"
  wrong_dir="$TMP_ROOT/opencode-plugin-cwd/subdir"
  log="$TMP_ROOT/opencode-plugin-guard.log"
  make_adapter_primary_repo "$worktree_dir"
  mkdir -p "$worktree_dir/bin" "$wrong_dir"
  cat > "$worktree_dir/bin/fm-turnend-guard.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'guard-fired\n' >&2
exit 2
EOF
  chmod +x "$worktree_dir/bin/fm-turnend-guard.sh"
  out=$(PLUGIN="$plugin" DIRECTORY="$wrong_dir" WORKTREE="$worktree_dir" FM_GUARD_LOG="$log" node 2>&1 <<'EOF'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let promptBody = "";
let prompts = 0;
let releaseFirst;
let markFirstStarted;
const firstStarted = new Promise((resolve) => { markFirstStarted = resolve; });
const client = {
  session: {
    promptAsync: async (request) => {
      prompts += 1;
      promptBody = request.body.parts[0].text;
      if (prompts === 1) {
        markFirstStarted();
        await new Promise((resolve) => { releaseFirst = resolve; });
      }
    },
  },
};
const hooks = await mod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.DIRECTORY,
  worktree: process.env.WORKTREE,
});
const firstIdle = hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
await firstStarted;
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
releaseFirst();
await firstIdle;
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
if (!promptBody.includes("guard-fired")) {
  console.error(`missing prompt body: ${promptBody}`);
  process.exit(1);
}
if (prompts !== 2) throw new Error(`expected one follow-up per still-blind idle, saw ${prompts}`);
const guardRuns = readFileSync(process.env.FM_GUARD_LOG, "utf8").trim().split("\n").length;
if (guardRuns !== 3) throw new Error(`three idle events ran predicate ${guardRuns} times`);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode plugin must run the guard from worktree even when directory is elsewhere"
  [ -z "$out" ] || fail "OpenCode plugin worktree-root test printed output: $out"
  pass ".opencode primary plugin: forced follow-up reruns the worktree-anchored predicate"
}

test_opencode_plugin_preserves_failed_delivery_handoff() {
  local plugin worktree_dir home healthy out status
  plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  worktree_dir="$TMP_ROOT/opencode-delivery-failure-root"
  home="$TMP_ROOT/opencode-delivery-failure-home"
  healthy="$TMP_ROOT/opencode-delivery-failure-healthy"
  make_adapter_primary_repo "$worktree_dir"
  mkdir -p "$worktree_dir/bin" "$home/state"
  cat > "$worktree_dir/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
if [ -f "${FM_GUARD_HEALTHY:?}" ]; then
  exit 0
fi
printf 'OpenCode delivery failure guard\n' >&2
exit 2
SH
  chmod +x "$worktree_dir/bin/fm-turnend-guard.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$worktree_dir" FM_HOME="$home" FM_GUARD_HEALTHY="$healthy" FM_TURNEND_HANDOFF_RETRY_MS=10 node 2>&1 <<'EOF'
import { existsSync, readdirSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let attempts = 0;
const client = {
  session: {
    promptAsync: async () => {
      attempts += 1;
      if (attempts < 3) throw new Error("synthetic OpenCode delivery failure");
    },
  },
};
const hooks = await mod.FmPrimaryTurnendGuard({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
const idle = { event: { type: "session.idle", properties: { sessionID: "session-failure" } } };
await hooks.event(idle);
const handoffDir = `${process.env.FM_HOME}/state/.turnend-handoffs`;
if (!existsSync(handoffDir) || !readdirSync(handoffDir).some((name) => name.startsWith("opencode-") && name.endsWith(".pending"))) {
  throw new Error("failed delivery did not leave a durable handoff");
}
for (let i = 0; i < 50 && attempts < 3; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (attempts < 3) throw new Error(`retry owner stopped after ${attempts} delivery attempts`);
if (readdirSync(handoffDir).some((name) => name.startsWith("opencode-") && name.endsWith(".pending"))) {
  throw new Error("acknowledged OpenCode delivery did not clear the durable handoff");
}
writeFileSync(process.env.FM_GUARD_HEALTHY, "healthy\n");
await hooks.event(idle);
if (readdirSync(handoffDir).some((name) => name.startsWith("opencode-") && name.endsWith(".pending"))) {
  throw new Error("acknowledged OpenCode continuation did not clear the durable handoff");
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode guard must persist and retry failed continuation delivery"
  [ -z "$out" ] || fail "OpenCode delivery-failure test printed output: $out"
  pass ".opencode primary plugin: retry owner retains handoff until SDK acknowledgement"
}

test_opencode_plugin_fails_closed_when_guard_cannot_launch() {
  local plugin worktree_dir home out status
  plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  worktree_dir="$TMP_ROOT/opencode-guard-launch-root"
  home="$TMP_ROOT/opencode-guard-launch-home"
  make_adapter_primary_repo "$worktree_dir"
  mkdir -p "$worktree_dir/bin" "$home/state"
  out=$(PLUGIN="$plugin" WORKTREE="$worktree_dir" FM_HOME="$home" node 2>&1 <<'EOF'
import { existsSync, readdirSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let body = "";
const client = { session: { promptAsync: async (request) => { body = request.body.parts[0].text; } } };
const hooks = await mod.FmPrimaryTurnendGuard({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "launch-failure" } } });
if (!body.includes("failed with exit 125")) throw new Error(`guard launch failure was not delivered: ${body}`);
const handoffDir = `${process.env.FM_HOME}/state/.turnend-handoffs`;
if (!existsSync(handoffDir)) throw new Error("guard launch failure did not create its handoff directory");
if (readdirSync(handoffDir).some((name) => name.endsWith(".pending"))) {
  throw new Error("acknowledged guard-launch continuation retained a pending handoff");
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode guard launch failure must force a fail-closed handoff"
  [ -z "$out" ] || fail "OpenCode guard-launch test printed output: $out"
  pass ".opencode primary plugin: shared-guard launch failure is fail closed"
}

test_opencode_retry_owner_is_referenced_until_healthy() {
  local plugin worktree_dir home healthy out status
  plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  worktree_dir="$TMP_ROOT/opencode-retry-owner-root"
  home="$TMP_ROOT/opencode-retry-owner-home"
  healthy="$TMP_ROOT/opencode-retry-owner-healthy"
  make_adapter_primary_repo "$worktree_dir"
  mkdir -p "$worktree_dir/bin" "$home/state"
  cat > "$worktree_dir/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
[ -f "${FM_GUARD_HEALTHY:?}" ] && exit 0
printf 'OpenCode retry owner guard\n' >&2
exit 2
SH
  chmod +x "$worktree_dir/bin/fm-turnend-guard.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$worktree_dir" FM_HOME="$home" FM_GUARD_HEALTHY="$healthy" FM_TURNEND_HANDOFF_RETRY_MS=300000 node 2>&1 <<'EOF'
import { existsSync, readdirSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const nativeSetTimeout = globalThis.setTimeout;
const nativeClearTimeout = globalThis.clearTimeout;
const activeTimers = new Set();
globalThis.setTimeout = (callback, delay, ...args) => {
  let timer;
  timer = nativeSetTimeout(() => {
    activeTimers.delete(timer);
    callback(...args);
  }, delay);
  activeTimers.add(timer);
  return timer;
};
globalThis.clearTimeout = (timer) => {
  activeTimers.delete(timer);
  nativeClearTimeout(timer);
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => { throw new Error("synthetic rejection"); } } };
const hooks = await mod.FmPrimaryTurnendGuard({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
const idle = { event: { type: "session.idle", properties: { sessionID: "retry-owner" } } };
await hooks.event(idle);
const handoffDir = `${process.env.FM_HOME}/state/.turnend-handoffs`;
if (!existsSync(handoffDir) || !readdirSync(handoffDir).some((name) => name.endsWith(".pending"))) {
  throw new Error("rejected OpenCode delivery did not retain its handoff");
}
if (![...activeTimers].some((timer) => timer.hasRef?.())) {
  throw new Error("OpenCode retry owner timer was not process-retaining");
}
writeFileSync(process.env.FM_GUARD_HEALTHY, "healthy\n");
await hooks.event(idle);
if (activeTimers.size !== 0) throw new Error("healthy invalidation left the OpenCode retry owner active");
if (readdirSync(handoffDir).some((name) => name.endsWith(".pending"))) {
  throw new Error("healthy invalidation retained an obsolete OpenCode handoff");
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode retry timer must retain the process until healthy invalidation"
  [ -z "$out" ] || fail "OpenCode referenced-retry-owner test printed output: $out"
  pass ".opencode primary plugin: retry ownership ends only on healthy invalidation"
}

test_opencode_crewmate_does_not_recover_primary_handoff() {
  local plugin base crew home out status
  plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  base="$TMP_ROOT/opencode-crew-base"
  crew="$TMP_ROOT/opencode-crew-worktree"
  home="$TMP_ROOT/opencode-crew-home"
  make_adapter_primary_repo "$base"
  git -C "$base" worktree add -q -b crew "$crew"
  mkdir -p "$home/state/.turnend-handoffs"
  printf '{"token":"retained","sessionID":"primary-session","message":"primary continuation"}\n' \
    > "$home/state/.turnend-handoffs/opencode-retained.pending"
  out=$(PLUGIN="$plugin" WORKTREE="$crew" FM_HOME="$home" node 2>&1 <<'EOF'
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
const client = { session: { promptAsync: async () => { prompts += 1; } } };
const hooks = await mod.FmPrimaryTurnendGuard({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "primary-session" } } });
await new Promise((resolve) => setTimeout(resolve, 30));
if (prompts !== 0) throw new Error("linked crewmate delivered the primary handoff");
if (!existsSync(`${process.env.FM_HOME}/state/.turnend-handoffs/opencode-retained.pending`)) {
  throw new Error("linked crewmate cleared the primary handoff");
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode linked crewmate must not recover primary handoffs"
  [ -z "$out" ] || fail "OpenCode crewmate-scope test printed output: $out"
  pass ".opencode primary plugin: linked crewmates cannot recover primary handoffs"
}

test_opencode_persistence_failure_retains_retry_owner() {
  local plugin repo home out status
  plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  repo="$TMP_ROOT/opencode-persist-root"
  home="$TMP_ROOT/opencode-persist-home"
  make_adapter_primary_repo "$repo"
  mkdir -p "$repo/bin" "$home/state"
  printf 'blocked\n' > "$home/state/.turnend-handoffs"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'persistence retry guard\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_TURNEND_HANDOFF_RETRY_MS=10 node 2>&1 <<'EOF'
import { unlinkSync } from "node:fs";
import { pathToFileURL } from "node:url";

const nativeSetTimeout = globalThis.setTimeout;
const activeTimers = new Set();
globalThis.setTimeout = (callback, delay, ...args) => {
  let timer;
  timer = nativeSetTimeout(() => { activeTimers.delete(timer); callback(...args); }, delay);
  activeTimers.add(timer);
  return timer;
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
const client = { session: { promptAsync: async () => { prompts += 1; } } };
const hooks = await mod.FmPrimaryTurnendGuard({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "persist-retry" } } });
if (![...activeTimers].some((timer) => timer.hasRef?.())) throw new Error("persistence failure had no process-retaining owner");
unlinkSync(`${process.env.FM_HOME}/state/.turnend-handoffs`);
for (let i = 0; i < 50 && prompts === 0; i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
if (prompts !== 1) throw new Error(`persistence recovery delivered ${prompts} continuations`);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode persistence failure must retain retry ownership"
  [ -z "$out" ] || fail "OpenCode persistence-retry test printed output: $out"
  pass ".opencode primary plugin: synchronous persistence failure retains a retry owner"
}

test_opencode_cleanup_failure_retains_acknowledged_owner() {
  local plugin repo home out status
  plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  repo="$TMP_ROOT/opencode-cleanup-root"
  home="$TMP_ROOT/opencode-cleanup-home"
  make_adapter_primary_repo "$repo"
  mkdir -p "$repo/bin" "$home/state"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'cleanup retry guard\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_TURNEND_HANDOFF_RETRY_MS=10 node 2>&1 <<'EOF'
import { chmodSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";

let prompts = 0;
const client = { session: { promptAsync: async () => {
  prompts += 1;
  chmodSync(`${process.env.FM_HOME}/state/.turnend-handoffs`, 0o500);
} } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const hooks = await mod.FmPrimaryTurnendGuard({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "cleanup-retry" } } });
const key = createHash("sha256").update("cleanup-retry").digest("hex").slice(0, 24);
const pending = `${process.env.FM_HOME}/state/.turnend-handoffs/opencode-${key}.pending`;
if (!existsSync(pending)) throw new Error("cleanup failure discarded the acknowledged OpenCode handoff");
chmodSync(`${process.env.FM_HOME}/state/.turnend-handoffs`, 0o700);
for (let i = 0; i < 50 && existsSync(pending); i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
if (existsSync(pending)) throw new Error("OpenCode cleanup retry never confirmed record absence");
if (prompts !== 1) throw new Error(`OpenCode cleanup retry redelivered ${prompts} prompts`);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode acknowledged cleanup failure must retain retry ownership"
  [ -z "$out" ] || fail "OpenCode cleanup-retry test printed output: $out"
  pass ".opencode primary plugin: acknowledged owner persists until cleanup is confirmed"
}

test_pi_extension_forces_followup() {
  local ext content
  ext="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  [ -f "$ext" ] || fail "tracked pi primary extension is missing"
  content=$(cat "$ext")
  assert_contains "$content" 'agent_settled' "pi extension must run after one logical agent run settles"
  assert_contains "$content" 'agent_start' "pi extension must acknowledge only a real ensuing assistant run"
  assert_contains "$content" 'fm-turnend-guard.sh' "pi extension must invoke the shared guard"
  assert_contains "$content" 'sendUserMessage' "pi extension must force a follow-up turn"
  assert_contains "$content" 'deliverAs: "followUp"' "pi extension must queue the follow-up safely"
  assert_contains "$content" 'guardFollowupDeliveryActive' "pi extension must deduplicate only overlapping SDK delivery"
  assert_contains "$content" '.turnend-handoffs' "pi extension must persist failed continuation delivery"
  assert_not_contains "$content" 'guardFollowupActive' "pi extension must not skip the predicate or delivery after its follow-up"
  assert_not_contains "$content" 'skipNextTurnEnd' "pi extension kept the internal-turn loop guard"
  assert_contains "$content" 'session-start operating block' "pi extension must use harness-neutral repair wording"
  assert_contains "$content" '.pi-turnend-extension-loaded' "pi extension must write its loaded marker for session-start diagnostics"
  assert_contains "$content" 'lockOwnership' "pi extension loaded marker must respect the session lock"
  assert_contains "$content" 'const command = String((event.input as { command?: unknown })?.command ?? "")' "pi extension changed bash command extraction for the PreToolUse contract"
  assert_contains "$content" 'runPretoolCheck(command)' "pi extension changed the PreToolUse checker invocation"
  assert_contains "$content" 'return { block: true, reason:' "pi extension changed the checker exit-2 block result"
  assert_not_contains "$content" 'Run bin/fm-watch-arm.sh as a background task' "pi extension must not hardcode the old watcher-arm instruction"
  pass ".pi primary extension: agent_settled forces one follow-up through the shared guard"
}

test_pi_extension_injects_once_per_logical_agent_run() {
  local repo home ext log out status
  repo="$TMP_ROOT/pi-logical-run-root"
  home="$TMP_ROOT/pi-logical-run-home"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  log="$TMP_ROOT/pi-logical-run-guard.log"
  make_adapter_primary_repo "$repo"
  mkdir -p "$repo/.pi/extensions" "$repo/bin" "$home/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'logical-run guard fired\n' >&2
exit 2
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh" "$repo/bin/fm-arm-pretool-check.sh"
  out=$(PLUGIN="$ext" FM_HOME="$home" FM_GUARD_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let prompts = 0;
const nativeSetTimeout = globalThis.setTimeout;
const nativeClearTimeout = globalThis.clearTimeout;
const activeTimers = new Set();
globalThis.setTimeout = (callback, delay, ...args) => {
  let timer;
  timer = nativeSetTimeout(() => {
    activeTimers.delete(timer);
    callback(...args);
  }, delay);
  activeTimers.add(timer);
  return timer;
};
globalThis.clearTimeout = (timer) => {
  activeTimers.delete(timer);
  nativeClearTimeout(timer);
};
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  sendUserMessage(message, options) {
    prompts += 1;
    if (!message.includes("TURN WOULD END BLIND")) throw new Error(`unexpected prompt: ${message}`);
    if (options?.deliverAs !== "followUp") throw new Error("guard prompt was not a follow-up");
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
mod.default(pi);
if (handlers.has("turn_end")) throw new Error("guard still treats internal Pi turns as logical runs");
const settled = handlers.get("agent_settled");
if (!settled) throw new Error("agent_settled handler was not registered");
const started = handlers.get("agent_start");
if (!started) throw new Error("agent_start acknowledgement handler was not registered");

await settled({ type: "agent_settled" }, {});
if (prompts !== 1) throw new Error(`one logical run injected ${prompts} follow-ups`);
const pending = `${process.env.FM_HOME}/state/.turnend-handoffs/pi.pending`;
if (!existsSync(pending)) throw new Error("void sendUserMessage falsely acknowledged and cleared the handoff");
if (![...activeTimers].some((timer) => timer.hasRef?.())) throw new Error("Pi retry owner timer was not process-retaining");
await started({ type: "agent_start" }, {});
if (existsSync(pending)) throw new Error("agent_start did not acknowledge the delivered handoff");
if (activeTimers.size !== 0) throw new Error("agent_start acknowledgement left the Pi retry owner active");

for (let i = 0; i < 3; i += 1) {
  await handlers.get("turn_end")?.({ type: "turn_end", turnIndex: i }, {});
}
await settled({ type: "agent_settled" }, {});
if (prompts !== 2) throw new Error(`later logical run produced ${prompts - 1} new follow-ups`);
await started({ type: "agent_start" }, {});
if (activeTimers.size !== 0) throw new Error("later agent_start acknowledgement left the Pi retry owner active");

const guardRuns = readFileSync(process.env.FM_GUARD_LOG, "utf8").trim().split("\n").length;
if (guardRuns !== 2) throw new Error(`guard predicate ran ${guardRuns} times for two logical runs`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must inject once for no-tool and multi-tool logical runs"
  [ -z "$out" ] || fail "Pi logical-run guard test printed output: $out"
  pass ".pi primary extension: every still-blind logical run injects a future continuation"
}

test_pi_extension_retries_after_followup_delivery_failure() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-delivery-failure-root"
  home="$TMP_ROOT/pi-delivery-failure-home"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  make_adapter_primary_repo "$repo"
  mkdir -p "$repo/.pi/extensions" "$repo/bin" "$home/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'delivery failure guard\n' >&2
exit 2
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh" "$repo/bin/fm-arm-pretool-check.sh"
  out=$(PLUGIN="$ext" FM_HOME="$home" FM_TURNEND_HANDOFF_RETRY_MS=10 node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let attempts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  sendUserMessage() {
    attempts += 1;
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
mod.default(pi);
const settled = handlers.get("agent_settled");
await settled({ type: "agent_settled" }, {});
const pending = `${process.env.FM_HOME}/state/.turnend-handoffs/pi.pending`;
if (!existsSync(pending)) throw new Error("void Pi delivery did not leave a durable handoff");
for (let i = 0; i < 50 && attempts < 2; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (attempts < 2) throw new Error("Pi handoff had no live retry owner");
if (!existsSync(pending)) throw new Error("retry attempt falsely acknowledged the Pi handoff");
await handlers.get("agent_start")?.({ type: "agent_start" }, {});
if (existsSync(pending)) throw new Error("agent_start did not acknowledge the retried Pi handoff");
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must persist and retry delivery after a failure"
  [ -z "$out" ] || fail "Pi delivery-failure guard test printed output: $out"
  pass ".pi primary extension: void delivery remains owned until agent-start acknowledgement"
}

test_pi_extension_recovers_retained_handoff() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-recovery-root"
  home="$TMP_ROOT/pi-recovery-home"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  make_adapter_primary_repo "$repo"
  mkdir -p "$repo/.pi/extensions" "$repo/bin" "$home/state/.turnend-handoffs"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  printf '{"token":"retained-token","message":"retained continuation"}\n' > "$home/state/.turnend-handoffs/pi.pending"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let message = "";
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  sendUserMessage(value) { message = value; },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
mod.default(pi);
for (let i = 0; i < 50 && !message; i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
if (message !== "retained continuation") throw new Error(`retained handoff was not recovered: ${message}`);
const pending = `${process.env.FM_HOME}/state/.turnend-handoffs/pi.pending`;
if (!existsSync(pending)) throw new Error("recovered void delivery cleared before acknowledgement");
await handlers.get("agent_start")?.({ type: "agent_start" }, {});
if (existsSync(pending)) throw new Error("recovered handoff was not acknowledged by agent_start");
EOF
)
  status=$?
  expect_code 0 "$status" "Pi extension must recover retained passive handoffs on load"
  [ -z "$out" ] || fail "Pi retained-handoff recovery test printed output: $out"
  pass ".pi primary extension: retained handoff regains retry ownership after reload"
}

test_pi_extension_fails_closed_when_guard_cannot_launch() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-guard-launch-root"
  home="$TMP_ROOT/pi-guard-launch-home"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  make_adapter_primary_repo "$repo"
  mkdir -p "$repo/.pi/extensions" "$repo/bin" "$home/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let message = "";
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  sendUserMessage(value) { message = value; },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
mod.default(pi);
await handlers.get("agent_settled")?.({ type: "agent_settled" }, {});
if (!message.includes("failed with exit 125")) throw new Error(`guard launch failure was not delivered: ${message}`);
if (!existsSync(`${process.env.FM_HOME}/state/.turnend-handoffs/pi.pending`)) {
  throw new Error("guard launch failure did not retain a Pi handoff");
}
await handlers.get("agent_start")?.({ type: "agent_start" }, {});
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard launch failure must force a fail-closed handoff"
  [ -z "$out" ] || fail "Pi guard-launch test printed output: $out"
  pass ".pi primary extension: shared-guard launch failure is fail closed"
}

test_pi_crewmate_does_not_consume_primary_handoff() {
  local base crew home ext out status
  base="$TMP_ROOT/pi-crew-base"
  crew="$TMP_ROOT/pi-crew-worktree"
  home="$TMP_ROOT/pi-crew-home"
  make_adapter_primary_repo "$base"
  git -C "$base" worktree add -q -b crew "$crew"
  ext="$crew/.pi/extensions/fm-primary-turnend-guard.ts"
  mkdir -p "$crew/.pi/extensions" "$home/state/.turnend-handoffs"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  printf '{"token":"retained","message":"primary continuation"}\n' > "$home/state/.turnend-handoffs/pi.pending"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let prompts = 0;
const pi = { on(event, handler) { handlers.set(event, handler); }, sendUserMessage() { prompts += 1; } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await new Promise((resolve) => setTimeout(resolve, 30));
if (handlers.has("agent_start") || handlers.has("agent_settled")) throw new Error("linked crewmate registered primary lifecycle handlers");
if (prompts !== 0) throw new Error("linked crewmate delivered the primary handoff");
if (!existsSync(`${process.env.FM_HOME}/state/.turnend-handoffs/pi.pending`)) throw new Error("linked crewmate cleared the primary handoff");
EOF
)
  status=$?
  expect_code 0 "$status" "Pi linked crewmate must not consume primary handoffs"
  [ -z "$out" ] || fail "Pi crewmate-scope test printed output: $out"
  pass ".pi primary extension: linked crewmates cannot consume primary handoffs"
}

test_pi_readonly_session_does_not_recover_or_acknowledge_handoff() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-readonly-root"
  home="$TMP_ROOT/pi-readonly-home"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  make_adapter_primary_repo "$repo"
  mkdir -p "$repo/.pi/extensions" "$home/state/.turnend-handoffs"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  printf '{"token":"retained","message":"primary continuation"}\n' > "$home/state/.turnend-handoffs/pi.pending"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let prompts = 0;
const pi = { on(event, handler) { handlers.set(event, handler); }, sendUserMessage() { prompts += 1; } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
mod.default(pi);
writeFileSync(`${process.env.FM_HOME}/state/.lock`, "1\n");
await handlers.get("session_start")?.({ type: "session_start" }, {});
await new Promise((resolve) => setTimeout(resolve, 30));
await handlers.get("agent_start")?.({ type: "agent_start" }, {});
if (prompts !== 0) throw new Error("scheduled Pi retry ran after its process lost the session lock");
if (!existsSync(`${process.env.FM_HOME}/state/.turnend-handoffs/pi.pending`)) {
  throw new Error("read-only Pi session acknowledged the lock owner's handoff");
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi scheduled recovery and acknowledgement must recheck session-lock ownership"
  [ -z "$out" ] || fail "Pi read-only lock-owner test printed output: $out"
  pass ".pi primary extension: losing the lock cancels scheduled retry ownership without consuming handoffs"
}

test_pi_cleanup_failure_retains_acknowledged_owner() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-cleanup-root"
  home="$TMP_ROOT/pi-cleanup-home"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  make_adapter_primary_repo "$repo"
  mkdir -p "$repo/.pi/extensions" "$repo/bin" "$home/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 2
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh"
  out=$(PLUGIN="$ext" FM_HOME="$home" FM_TURNEND_HANDOFF_RETRY_MS=10 node --input-type=module 2>&1 <<'EOF'
import { chmodSync, existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let prompts = 0;
const pi = { on(event, handler) { handlers.set(event, handler); }, sendUserMessage() { prompts += 1; } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
mod.default(pi);
await handlers.get("agent_settled")?.({ type: "agent_settled" }, {});
const pending = `${process.env.FM_HOME}/state/.turnend-handoffs/pi.pending`;
chmodSync(`${process.env.FM_HOME}/state/.turnend-handoffs`, 0o500);
await handlers.get("agent_start")?.({ type: "agent_start" }, {});
if (!existsSync(pending)) throw new Error("cleanup failure discarded the acknowledged Pi handoff");
chmodSync(`${process.env.FM_HOME}/state/.turnend-handoffs`, 0o700);
for (let i = 0; i < 50 && existsSync(pending); i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
if (existsSync(pending)) throw new Error("Pi cleanup retry never confirmed record absence");
if (prompts !== 1) throw new Error(`Pi cleanup retry redelivered ${prompts} prompts`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi acknowledged cleanup failure must retain retry ownership"
  [ -z "$out" ] || fail "Pi cleanup-retry test printed output: $out"
  pass ".pi primary extension: acknowledged owner persists until cleanup is confirmed"
}

test_pi_persistence_failure_retains_retry_owner() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-persist-root"
  home="$TMP_ROOT/pi-persist-home"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  make_adapter_primary_repo "$repo"
  mkdir -p "$repo/.pi/extensions" "$repo/bin" "$home/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  printf 'blocked\n' > "$home/state/.turnend-handoffs"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'persistence retry guard\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh"
  out=$(PLUGIN="$ext" FM_HOME="$home" FM_TURNEND_HANDOFF_RETRY_MS=10 node --input-type=module 2>&1 <<'EOF'
import { unlinkSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let prompts = 0;
const nativeSetTimeout = globalThis.setTimeout;
const activeTimers = new Set();
globalThis.setTimeout = (callback, delay, ...args) => {
  let timer;
  timer = nativeSetTimeout(() => { activeTimers.delete(timer); callback(...args); }, delay);
  activeTimers.add(timer);
  return timer;
};
const pi = { on(event, handler) { handlers.set(event, handler); }, sendUserMessage() { prompts += 1; } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
mod.default(pi);
await handlers.get("agent_settled")?.({ type: "agent_settled" }, {});
if (![...activeTimers].some((timer) => timer.hasRef?.())) throw new Error("persistence failure had no process-retaining owner");
unlinkSync(`${process.env.FM_HOME}/state/.turnend-handoffs`);
for (let i = 0; i < 50 && prompts === 0; i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
if (prompts !== 1) throw new Error(`persistence recovery delivered ${prompts} continuations`);
await handlers.get("agent_start")?.({ type: "agent_start" }, {});
EOF
)
  status=$?
  expect_code 0 "$status" "Pi persistence failure must retain retry ownership"
  [ -z "$out" ] || fail "Pi persistence-retry test printed output: $out"
  pass ".pi primary extension: synchronous persistence failure retains a retry owner"
}

test_grok_hook_invokes_adapter() {
  local settings command
  settings="$ROOT/.grok/hooks/fm-primary-turnend-guard.json"
  [ -f "$settings" ] || fail "tracked grok primary hook config is missing"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "Stop hook command is missing from grok primary hook config"
  assert_contains "$command" 'GROK_WORKSPACE_ROOT' "grok hook must anchor from GROK_WORKSPACE_ROOT"
  assert_contains "$command" 'fm-turnend-guard-grok.sh' "grok hook must invoke the adapter"
  pass ".grok primary hook: Stop hook invokes the grok adapter"
}

test_predicate_healthy_no_inflight
test_predicate_unhealthy_no_beacon
test_predicate_unhealthy_stale_beacon
test_predicate_healthy_fresh_beacon
test_predicate_queue_pending_flag
test_hook_silent_when_no_work_in_flight
test_hook_blocks_when_fresh_beacon_has_no_live_lock
test_hook_blocks_when_dead_lock_has_fresh_beacon
test_hook_silent_with_live_lock_and_fresh_beacon
test_hook_accepts_only_active_away_inject_daemon
test_hook_blocks_live_foreground_checkpoint_then_blocks_retry
test_hook_blocks_with_live_lock_and_stale_beacon
test_hook_blocks_when_unhealthy_in_primary
test_hook_blocks_from_fm_home_state
test_hook_x_mode_reason_sources_cadence
test_hook_ignores_repo_state_when_fm_home_set
test_hook_uses_state_override
test_hook_retry_requires_durable_ownership
test_hook_surfaces_bounded_parked_and_idle_tasks
test_hook_silent_in_secondmate_home
test_hook_silent_in_crewmate_worktree
test_hook_blocks_without_jq
test_hook_blocks_without_stdin
test_hook_blocks_with_malformed_stdin
test_hook_runs_fast
test_grok_adapter_forces_one_resume_when_unhealthy
test_grok_adapter_repeats_resume_when_still_blind
test_grok_adapter_preserves_failed_delivery_handoff
test_grok_worker_waits_for_originating_hook_exit
test_grok_session_delivery_is_singleton
test_grok_healthy_stop_invalidates_stale_pending
test_grok_missing_guard_fails_closed_through_retry_owner
test_grok_handoff_preparation_failure_is_nonzero
test_grok_missing_session_is_loud_unsupported_exception
test_grok_worker_launch_requires_token_readiness
test_grok_worker_signal_reaps_delivery_children
test_settings_hook_uses_claude_project_dir
test_codex_hook_invokes_shared_guard
test_codex_hook_uses_process_pwd_when_payload_cwd_is_outside_root
test_codex_hook_ignores_nested_git_root_guard
test_opencode_plugin_forces_followup
test_opencode_plugin_anchors_guard_to_worktree
test_opencode_plugin_preserves_failed_delivery_handoff
test_opencode_plugin_fails_closed_when_guard_cannot_launch
test_opencode_retry_owner_is_referenced_until_healthy
test_opencode_crewmate_does_not_recover_primary_handoff
test_opencode_persistence_failure_retains_retry_owner
test_opencode_cleanup_failure_retains_acknowledged_owner
test_pi_extension_forces_followup
test_pi_extension_injects_once_per_logical_agent_run
test_pi_extension_retries_after_followup_delivery_failure
test_pi_extension_recovers_retained_handoff
test_pi_extension_fails_closed_when_guard_cannot_launch
test_pi_crewmate_does_not_consume_primary_handoff
test_pi_readonly_session_does_not_recover_or_acknowledge_handoff
test_pi_cleanup_failure_retains_acknowledged_owner
test_pi_persistence_failure_retains_retry_owner
test_grok_hook_invokes_adapter
