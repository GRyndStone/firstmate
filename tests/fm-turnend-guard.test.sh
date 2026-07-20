#!/usr/bin/env bash
# Behavior tests for the primary turn-end supervision guard (docs/turnend-guard.md).
#
# Two layers:
#   PREDICATE  - bin/fm-supervision-lib.sh, the shared beacon/status computation
#                used by fm-guard.sh and by the hook's banner details.
#   HOOK       - bin/fm-turnend-guard.sh, the shared primary hook predicate that
#                scopes in-flight work to the PRIMARY checkout only and requires
#                a live, identity-matched watcher lock plus a fresh beacon.
# All hermetic over temp dirs; no real agent session is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-supervision-lib.sh
. "$ROOT/bin/fm-supervision-lib.sh"

fm_test_tmproot TMP_ROOT fm-turnend-guard
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
  cp "$ROOT/bin/fm-supervision-instructions.sh" "$dir/bin/fm-supervision-instructions.sh"
  cp "$ROOT/bin/fm-harness.sh" "$dir/bin/fm-harness.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  mkdir -p "$dir/docs"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard-grok.sh" "$dir/bin/fm-supervision-instructions.sh" "$dir/bin/fm-harness.sh"
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
  local dir=$1 pid=$2 identity=$3 owner_kind=${4:-} owner_pid=${5:-} owner_identity=${6:-} owner_mode=${7:-} tracker_pid=${8:-} tracker_identity=${9:-} root bin_dir
  root=$(cd "$dir" && pwd)
  bin_dir=$(cd "$dir/bin" && pwd)
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$root" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$bin_dir/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
  if [ -n "$owner_kind" ]; then
    printf '%s\n' "$owner_kind" > "$dir/state/.watch.lock/owner-kind"
    printf '%s\n' "$owner_pid" > "$dir/state/.watch.lock/owner-pid"
    printf '%s\n' "$owner_identity" > "$dir/state/.watch.lock/owner-identity"
    printf '%s\n' "$owner_mode" > "$dir/state/.watch.lock/owner-mode"
    if [ -n "$tracker_pid" ]; then
      printf '%s\n' "$tracker_pid" > "$dir/state/.watch.lock/owner-tracker-pid"
      printf '%s\n' "$tracker_identity" > "$dir/state/.watch.lock/owner-tracker-identity"
    fi
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
  local dir pid identity owner_pid owner_identity tracker_identity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-live-lock-fresh")
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  sleep 60 &
  owner_pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    kill "$owner_pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    wait "$owner_pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  owner_identity=$(watcher_identity "$dir" "$owner_pid") || {
    kill "$pid" "$owner_pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    wait "$owner_pid" 2>/dev/null || true
    fail "could not identify live watcher owner"
  }
  tracker_identity=$(watcher_identity "$dir" "$$") || {
    kill "$pid" "$owner_pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    wait "$owner_pid" 2>/dev/null || true
    fail "could not identify live watcher owner tracker"
  }
  record_watcher_lock "$dir" "$pid" "$identity" arm "$owner_pid" "$owner_identity" '' "$$" "$tracker_identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  kill "$pid" 2>/dev/null || true
  kill "$owner_pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  wait "$owner_pid" 2>/dev/null || true
  expect_code 0 "$status" "hook must exit 0 with a live identity-matched watcher lock and fresh beacon"
  [ -z "$out" ] || fail "hook produced output despite a live fresh watcher lock: $out"
  pass "fm-turnend-guard: silent no-op with a live watcher lock and fresh beacon"
}

test_hook_blocks_when_arm_tracker_is_dead() {
  local dir pid identity owner_pid owner_identity tracker_pid tracker_identity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-dead-arm-tracker")
  : > "$dir/state/task1.meta"
  sleep 60 & pid=$!
  sleep 60 & owner_pid=$!
  sleep 60 & tracker_pid=$!
  identity=$(watcher_identity "$dir" "$pid")
  owner_identity=$(watcher_identity "$dir" "$owner_pid")
  tracker_identity=$(watcher_identity "$dir" "$tracker_pid")
  record_watcher_lock "$dir" "$pid" "$identity" arm "$owner_pid" "$owner_identity" '' "$tracker_pid" "$tracker_identity"
  touch "$dir/state/.last-watcher-beat"
  kill "$tracker_pid" 2>/dev/null || true
  wait "$tracker_pid" 2>/dev/null || true
  out=$(run_hook "$dir" false); status=$?
  kill "$pid" "$owner_pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  wait "$owner_pid" 2>/dev/null || true
  expect_code 2 "$status" "hook must block when an arm's launch tracker has exited"
  assert_contains "$out" "healthy watcher has no live owner provenance" "dead tracker must invalidate arm provenance"
  pass "fm-turnend-guard: rejects an arm whose launch tracker has exited"
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

test_hook_retry_stays_blocked_without_restored_supervision() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-loopguard")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" true); status=$?
  expect_code 2 "$status" "hook must keep blocking when the forced continuation did not restore supervision"
  assert_contains "$out" "prior forced continuation did not drain wakes" "retry block must explain the unmet boundary"
  pass "fm-turnend-guard: stop_hook_active does not authorize a blind retry"
}

test_quiet_paused_checkpoint_reproduces_forced_continuation_loop() {
  local dir watch_pid watch_identity checkpoint_pid checkpoint_identity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-quiet-paused-checkpoint")
  printf 'window=fm-task1\nkind=ship\n' > "$dir/state/task1.meta"
  printf 'paused: deliberately waiting for the scheduled release\n' > "$dir/state/task1.status"
  sleep 60 & watch_pid=$!
  sleep 60 & checkpoint_pid=$!
  watch_identity=$(watcher_identity "$dir" "$watch_pid")
  checkpoint_identity=$(watcher_identity "$dir" "$checkpoint_pid")
  record_watcher_lock "$dir" "$watch_pid" "$watch_identity" checkpoint \
    "$checkpoint_pid" "$checkpoint_identity" checkpoint
  touch "$dir/state/.last-watcher-beat"

  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "a live foreground checkpoint must not authorize the first quiet paused turn end"
  assert_contains "$out" "foreground checkpoint owner cannot survive turn yield" \
    "checkpoint rejection did not explain its non-durable ownership"
  out=$(run_hook "$dir" true); status=$?
  kill "$checkpoint_pid" "$watch_pid" 2>/dev/null || true
  wait "$checkpoint_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  expect_code 2 "$status" "the forced continuation must remain blocked with the same foreground checkpoint"
  assert_contains "$out" "prior forced continuation did not drain wakes" \
    "checkpoint loop retry did not reproduce the forced-continuation boundary"
  pass "quiet paused metadata plus a foreground checkpoint reproduces the old forced-continuation loop"
}

test_normal_daemon_owner_is_durable_and_wake_drain_is_mandatory() {
  local dir watch_pid watch_identity daemon_pid daemon_identity daemon2_pid daemon2_identity out status drain
  dir=$(make_primary_dir "$TMP_ROOT/hook-normal-daemon")
  : > "$dir/state/task1.meta"
  sleep 60 & watch_pid=$!
  sleep 60 & daemon_pid=$!
  watch_identity=$(watcher_identity "$dir" "$watch_pid")
  daemon_identity=$(watcher_identity "$dir" "$daemon_pid")
  record_watcher_lock "$dir" "$watch_pid" "$watch_identity" daemon "$daemon_pid" "$daemon_identity" normal-inject
  mkdir -p "$dir/state/.supervise-daemon.lock"
  printf '%s\n' "$daemon_pid" > "$dir/state/.supervise-daemon.pid"
  printf '%s\n' "$daemon_pid" > "$dir/state/.supervise-daemon.lock/pid"
  printf '%s\n' "$daemon_identity" > "$dir/state/.supervise-daemon.lock/pid-identity"
  touch "$dir/state/.last-watcher-beat"

  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "live identity-bound normal daemon must authorize turn end"
  [ -z "$out" ] || fail "healthy normal daemon produced guard output: $out"

  FM_HOME="$dir" bash -c '. "$1"; fm_wake_append signal task1 "signal: task1.status"; fm_wake_append signal task1 "signal: task1.status"' \
    _ "$dir/bin/fm-wake-lib.sh"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "undrained wakes must block even with a healthy normal daemon"
  assert_contains "$out" "queued wakes are not drained" "normal daemon guard did not require wake drain"
  drain=$(FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" "$ROOT/bin/fm-wake-drain.sh")
  [ "$(printf '%s\n' "$drain" | grep -c 'signal: task1.status' || true)" -eq 1 ] \
    || fail "duplicate queued wake did not drain exactly once: $drain"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "drained queue plus healthy normal daemon must authorize turn end"

  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "dead normal daemon must fail closed despite a live watcher"

  sleep 60 & daemon2_pid=$!
  daemon2_identity=$(watcher_identity "$dir" "$daemon2_pid")
  printf '%s\n' "$daemon2_pid" > "$dir/state/.supervise-daemon.pid"
  printf '%s\n' "$daemon2_pid" > "$dir/state/.supervise-daemon.lock/pid"
  printf '%s\n' "identity mismatch" > "$dir/state/.supervise-daemon.lock/pid-identity"
  printf '%s\n' "$daemon2_pid" > "$dir/state/.watch.lock/owner-pid"
  printf '%s\n' "$daemon2_identity" > "$dir/state/.watch.lock/owner-identity"
  out=$(run_hook "$dir" false); status=$?
  kill "$daemon2_pid" "$watch_pid" 2>/dev/null || true
  wait "$daemon2_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  expect_code 2 "$status" "identity-mismatched daemon lock must fail closed"
  pass "normal daemon ownership is identity-bound and queued wakes must drain exactly once"
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

test_hook_blocks_without_working_jq() {
  local dir out status fakebin
  dir=$(make_primary_dir "$TMP_ROOT/hook-nojq")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/hook-nojq-fake")
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
exit 127
SH
  chmod +x "$fakebin/jq"
  out=$(printf '{"stop_hook_active":false}' | PATH="$fakebin:$PATH" bash "$dir/bin/fm-turnend-guard.sh" 2>&1)
  status=$?
  expect_code 2 "$status" "hook must fail closed when jq is unavailable"
  assert_contains "$out" "TURN WOULD END BLIND" "hook must still enforce the predicate without jq"
  pass "fm-turnend-guard: does not require jq to block a blind turn end"
}

test_hook_blocks_without_stdin() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-nostdin")
  : > "$dir/state/task1.meta"
  out=$(bash "$dir/bin/fm-turnend-guard.sh" < /dev/null 2>&1); status=$?
  expect_code 2 "$status" "hook must fail closed on empty/absent stdin"
  assert_contains "$out" "TURN WOULD END BLIND" "empty stdin must not bypass the shared predicate"
  pass "fm-turnend-guard: empty stdin cannot authorize a blind turn end"
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

test_grok_adapter_rechecks_until_healthy() {
  local dir fakebin log out status
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
calls=\$(grep -c '^active=' "$log" 2>/dev/null || true)
[ "\$calls" -lt 2 ] || rm -f "$dir/state/task1.meta"
EOF
  chmod +x "$fakebin/grok"
  out=$(printf '{"sessionId":"session-test","hookEventName":"stop"}' | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "grok adapter must fail open after queuing a forced resume"
  [ -z "$out" ] || fail "grok adapter printed output: $out"
  assert_contains "$(cat "$log")" 'active=1' "grok adapter must mark its forced resume as loop-guarded"
  assert_contains "$(cat "$log")" '<--resume>' "grok adapter must resume the current session"
  assert_contains "$(cat "$log")" '<session-test>' "grok adapter must pass the hook session id"
  assert_not_contains "$(cat "$log")" '<--permission-mode>' "grok adapter must not add a stronger permission mode"
  assert_not_contains "$(cat "$log")" '<bypassPermissions>' "grok adapter must not bypass permissions on forced resume"
  assert_contains "$(cat "$log")" 'TURN WOULD END BLIND' "grok adapter must carry the guard reason into the forced resume"
  [ "$(grep -c '^active=' "$log")" -eq 2 ] || fail "grok adapter did not recheck and resume until the predicate passed"
  pass "fm-turnend-guard-grok: rechecks the shared predicate after every forced resume"
}

test_grok_adapter_loop_guard_skips_resume() {
  local dir fakebin log out status
  dir=$(make_primary_dir "$TMP_ROOT/grok-adapter-loop")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-adapter-loop-fakebin")
  log="$TMP_ROOT/grok-adapter-loop-call.log"
  cat > "$fakebin/grok" <<EOF
#!/usr/bin/env bash
printf 'called\n' >> "$log"
EOF
  chmod +x "$fakebin/grok"
  out=$(printf '{"sessionId":"session-test","hookEventName":"stop"}' | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" GROK_TURNEND_GUARD_ACTIVE=1 bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "grok adapter must allow its own forced resume turn to end"
  [ -z "$out" ] || fail "grok adapter printed output while loop-guarded: $out"
  [ ! -e "$log" ] || fail "grok adapter spawned another resume while loop-guarded: $(cat "$log")"
  pass "fm-turnend-guard-grok: loop guard prevents a nested resume loop"
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
  assert_contains "$content" 'followupDispatching' "OpenCode plugin must suppress only reentrant follow-up dispatch"
  assert_not_contains "$content" 'skipNextIdle' "OpenCode plugin must not skip the next real idle predicate check"
  assert_contains "$content" 'worktree' "OpenCode plugin must anchor the guard from the git worktree path"
  pass ".opencode primary plugin: session.idle forces one follow-up through the shared guard"
}

test_opencode_plugin_anchors_guard_to_worktree() {
  local plugin parent worktree_dir wrong_dir out status
  plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  [ -f "$plugin" ] || fail "tracked OpenCode primary plugin is missing"
  parent="$TMP_ROOT/opencode-plugin-parent"
  git init -q "$parent"
  worktree_dir="$parent/nested/opencode-plugin-worktree"
  wrong_dir="$TMP_ROOT/opencode-plugin-cwd/subdir"
  mkdir -p "$worktree_dir/bin" "$wrong_dir"
  cat > "$worktree_dir/bin/fm-turnend-guard.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'guard-fired\n' >&2
exit 2
EOF
  chmod +x "$worktree_dir/bin/fm-turnend-guard.sh"
  out=$(PLUGIN="$plugin" DIRECTORY="$wrong_dir" WORKTREE="$worktree_dir" node 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let promptBody = "";
const client = {
  session: {
    promptAsync: async (request) => {
      promptBody = request.body.parts[0].text;
    },
  },
};
const hooks = await mod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.DIRECTORY,
  worktree: process.env.WORKTREE,
});
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
if (!promptBody.includes("guard-fired")) {
  console.error(`missing prompt body: ${promptBody}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode plugin must run the guard from worktree even when directory is elsewhere"
  [ -z "$out" ] || fail "OpenCode plugin worktree-root test printed output: $out"
  pass ".opencode primary plugin: guard path is anchored to worktree, not directory"
}

test_opencode_plugin_rechecks_after_forced_followup() {
  local plugin worktree_dir log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  worktree_dir="$TMP_ROOT/opencode-plugin-recheck"
  log="$TMP_ROOT/opencode-plugin-recheck.log"
  mkdir -p "$worktree_dir/bin"
  cat > "$worktree_dir/bin/fm-turnend-guard.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'guard-fired\n' >&2
exit 2
EOF
  chmod +x "$worktree_dir/bin/fm-turnend-guard.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$worktree_dir" FM_GUARD_LOG="$log" node 2>&1 <<'EOF'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
const client = { session: { promptAsync: async () => { prompts += 1; } } };
const hooks = await mod.FmPrimaryTurnendGuard({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
const idle = { event: { type: "session.idle", properties: { sessionID: "session-test" } } };
await hooks.event(idle);
await hooks.event(idle);
if (prompts !== 2) throw new Error(`expected two forced follow-ups, saw ${prompts}`);
const runs = readFileSync(process.env.FM_GUARD_LOG, "utf8").trim().split("\n").length;
if (runs !== 2) throw new Error(`expected two predicate checks, saw ${runs}`);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode plugin must recheck the predicate after a forced follow-up"
  [ -z "$out" ] || fail "OpenCode predicate-recheck test printed output: $out"
  pass ".opencode primary plugin: every real idle event rechecks the shared predicate"
}

test_pi_extension_forces_followup() {
  local ext content
  ext="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  [ -f "$ext" ] || fail "tracked pi primary extension is missing"
  content=$(cat "$ext")
  assert_contains "$content" 'agent_settled' "pi extension must run after one logical agent run settles"
  assert_contains "$content" 'fm-turnend-guard.sh' "pi extension must invoke the shared guard"
  assert_contains "$content" 'sendUserMessage' "pi extension must force a follow-up turn"
  assert_contains "$content" 'deliverAs: "followUp"' "pi extension must queue the follow-up safely"
  assert_contains "$content" 'guardFollowupDispatching' "pi extension must suppress only reentrant follow-up dispatch"
  assert_not_contains "$content" 'guardFollowupActive' "pi extension must not skip the next real settled predicate check"
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
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let prompts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message, options) {
    prompts += 1;
    if (!message.includes("TURN WOULD END BLIND")) throw new Error(`unexpected prompt: ${message}`);
    if (options?.deliverAs !== "followUp") throw new Error("guard prompt was not a follow-up");
    await handlers.get("agent_settled")?.({ type: "agent_settled" }, {});
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (handlers.has("turn_end")) throw new Error("guard still treats internal Pi turns as logical runs");
const settled = handlers.get("agent_settled");
if (!settled) throw new Error("agent_settled handler was not registered");

await settled({ type: "agent_settled" }, {});
if (prompts !== 1) throw new Error(`no-tool run injected ${prompts} follow-ups`);

for (let i = 0; i < 3; i += 1) {
  await handlers.get("turn_end")?.({ type: "turn_end", turnIndex: i }, {});
}
await settled({ type: "agent_settled" }, {});
if (prompts !== 2) throw new Error(`multi-tool run produced ${prompts - 1} follow-ups`);

const guardRuns = readFileSync(process.env.FM_GUARD_LOG, "utf8").trim().split("\n").length;
if (guardRuns !== 2) throw new Error(`guard predicate ran ${guardRuns} times for two logical runs`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must inject once for no-tool and multi-tool logical runs"
  [ -z "$out" ] || fail "Pi logical-run guard test printed output: $out"
  pass ".pi primary extension: no-tool and multi-tool runs each inject exactly one guard follow-up"
}

test_pi_extension_retries_after_followup_delivery_failure() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-delivery-failure-root"
  home="$TMP_ROOT/pi-delivery-failure-home"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
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
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
let attempts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage() {
    attempts += 1;
    if (attempts === 1) throw new Error("synthetic delivery failure");
    await handlers.get("agent_settled")?.({ type: "agent_settled" }, {});
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const settled = handlers.get("agent_settled");
await settled({ type: "agent_settled" }, {});
await settled({ type: "agent_settled" }, {});
if (attempts !== 2) throw new Error(`expected delivery retry, saw ${attempts} attempts`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard latch must reset after follow-up delivery failure"
  [ -z "$out" ] || fail "Pi delivery-failure guard test printed output: $out"
  pass ".pi primary extension: delivery failure resets the logical-run latch"
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
test_hook_blocks_when_arm_tracker_is_dead
test_hook_blocks_with_live_lock_and_stale_beacon
test_hook_blocks_when_unhealthy_in_primary
test_hook_blocks_from_fm_home_state
test_hook_x_mode_reason_sources_cadence
test_hook_ignores_repo_state_when_fm_home_set
test_hook_uses_state_override
test_hook_retry_stays_blocked_without_restored_supervision
test_quiet_paused_checkpoint_reproduces_forced_continuation_loop
test_normal_daemon_owner_is_durable_and_wake_drain_is_mandatory
test_hook_silent_in_secondmate_home
test_hook_silent_in_crewmate_worktree
test_hook_blocks_without_working_jq
test_hook_blocks_without_stdin
test_hook_runs_fast
test_grok_adapter_rechecks_until_healthy
test_grok_adapter_loop_guard_skips_resume
test_settings_hook_uses_claude_project_dir
test_codex_hook_invokes_shared_guard
test_codex_hook_uses_process_pwd_when_payload_cwd_is_outside_root
test_codex_hook_ignores_nested_git_root_guard
test_opencode_plugin_forces_followup
test_opencode_plugin_anchors_guard_to_worktree
test_opencode_plugin_rechecks_after_forced_followup
test_pi_extension_forces_followup
test_pi_extension_injects_once_per_logical_agent_run
test_pi_extension_retries_after_followup_delivery_failure
test_grok_hook_invokes_adapter
