#!/usr/bin/env bash
# Focused tests for primary session compaction and rotation controls.
# Covers thresholds, handoff persistence, restart preservation, and one-wake
# dedupe for compact/rotate recommendations.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

fm_test_tmproot TMP_ROOT fm-session-lifecycle-tests
STATE="$TMP_ROOT/state"
DATA="$TMP_ROOT/data"
CONFIG="$TMP_ROOT/config"
mkdir -p "$STATE" "$DATA" "$CONFIG"
export FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG"
LIFE="$ROOT/bin/fm-session-lifecycle.sh"

# Disable age-based rotate by default so unit tests are time-stable.
export FM_ROTATE_MAX_AGE_SECS=0

reset_home() {
  rm -rf "$STATE" "$DATA" "$CONFIG"
  mkdir -p "$STATE" "$DATA" "$CONFIG"
}

assert_action() {
  local line=$1 want=$2
  printf '%s\n' "$line" | grep -q "action=${want}" \
    || fail "expected action=${want}, got: $line"
}

test_defaults_under_threshold() {
  local out
  reset_home
  out=$("$LIFE" evaluate) || fail "evaluate failed under defaults"
  assert_action "$out" ok
  printf '%s\n' "$out" | grep -q 'reasons=under-thresholds' || fail "ok reason: $out"
  pass "defaults stay under threshold (action=ok)"
}

test_compact_on_traffic_threshold() {
  local out
  reset_home
  out=$(FM_COMPACT_TRAFFIC_BYTES=50 "$LIFE" record-traffic 50) || fail "record-traffic failed"
  assert_action "$out" compact
  printf '%s\n' "$out" | grep -q 'traffic_since_compact=50>=50' || fail "compact reason: $out"
  pass "compact fires at traffic_since_compact threshold"
}

test_compact_on_turn_cap() {
  local out
  reset_home
  out=$(FM_COMPACT_TURN_CAP=3 "$LIFE" record-turn 3) || fail "record-turn failed"
  assert_action "$out" compact
  printf '%s\n' "$out" | grep -q 'turns_since_compact=3>=3' || fail "turn cap reason: $out"
  pass "compact fires at turn cap"
}

test_rotate_on_traffic_forced_and_age() {
  local out now
  reset_home

  out=$(FM_ROTATE_TRAFFIC_BYTES=100 FM_COMPACT_TRAFFIC_BYTES=1000000 \
    "$LIFE" record-traffic 100) || fail "rotate traffic"
  assert_action "$out" rotate
  printf '%s\n' "$out" | grep -q 'traffic_bytes=100>=100' || fail "rotate traffic reason: $out"

  reset_home
  out=$(FM_ROTATE_FORCED_CONTINUATIONS=3 "$LIFE" record-forced-continuation 3) \
    || fail "forced continuum"
  assert_action "$out" rotate
  printf '%s\n' "$out" | grep -q 'forced_continuations=3>=3' || fail "forced reason: $out"

  reset_home
  "$LIFE" ensure >/dev/null
  now=$(date +%s)
  # Age rotate: started 5 hours ago with 1-hour max age.
  # shellcheck disable=SC2016
  awk -v started=$((now - 18000)) '
    BEGIN { OFS=FS="=" }
    $1=="started_at" { print $1, started; next }
    { print }
  ' "$STATE/.primary-session" > "$STATE/.primary-session.tmp"
  mv "$STATE/.primary-session.tmp" "$STATE/.primary-session"
  out=$(FM_ROTATE_MAX_AGE_SECS=3600 "$LIFE" evaluate) || fail "age evaluate"
  assert_action "$out" rotate
  printf '%s\n' "$out" | grep -q 'age_secs=' || fail "age reason: $out"
  pass "rotate fires on traffic, forced continuations, and age"
}

test_rotate_wins_over_compact() {
  local out
  reset_home
  # Both compact (traffic since compact) and rotate (forced) would apply; rotate wins.
  out=$(FM_COMPACT_TRAFFIC_BYTES=10 FM_ROTATE_FORCED_CONTINUATIONS=1 \
    "$LIFE" record-traffic 10) || fail "seed traffic"
  out=$(FM_COMPACT_TRAFFIC_BYTES=10 FM_ROTATE_FORCED_CONTINUATIONS=1 \
    "$LIFE" record-forced-continuation 1) || fail "forced+compact"
  assert_action "$out" rotate
  pass "rotate takes precedence over compact"
}

test_mark_compacted_resets_since_counters() {
  local out
  reset_home
  FM_COMPACT_TRAFFIC_BYTES=50 "$LIFE" record-traffic 50 >/dev/null
  out=$(FM_COMPACT_TRAFFIC_BYTES=50 "$LIFE" mark-compacted --reason test) \
    || fail "mark-compacted failed"
  assert_action "$out" ok
  out=$("$LIFE" status) || fail "status after compact"
  printf '%s\n' "$out" | grep -qx 'traffic_since_compact=0' || fail "since-compact not zero: $out"
  printf '%s\n' "$out" | grep -qx 'traffic_bytes=50' || fail "total traffic must remain: $out"
  printf '%s\n' "$out" | grep -qx 'compact_count=1' || fail "compact_count: $out"
  pass "mark-compacted resets since-compact counters only"
}

test_config_file_thresholds() {
  local out
  reset_home
  cat > "$CONFIG/session-lifecycle" <<'EOF'
compact_traffic_bytes=25
rotate_forced_continuations=2
EOF
  # Unset env so file applies (export empty would still count as set).
  unset FM_COMPACT_TRAFFIC_BYTES FM_ROTATE_FORCED_CONTINUATIONS
  out=$("$LIFE" thresholds)
  printf '%s\n' "$out" | grep -qx 'compact_traffic_bytes=25' || fail "config compact: $out"
  printf '%s\n' "$out" | grep -qx 'rotate_forced_continuations=2' || fail "config forced: $out"
  # Env wins over file.
  out=$(FM_COMPACT_TRAFFIC_BYTES=99 "$LIFE" thresholds)
  printf '%s\n' "$out" | grep -qx 'compact_traffic_bytes=99' || fail "env should win: $out"
  pass "config/session-lifecycle thresholds with env override"
}

seed_fleet_inventory() {
  cat > "$STATE/crew-a.meta" <<'EOF'
kind=ship
window=fm-crew-a
project=firstmate
harness=grok
EOF
  cat > "$STATE/crew-b.meta" <<'EOF'
kind=scout
window=fm-crew-b
project=firstmate
harness=codex
EOF
  printf 'needs-decision: choose merge strategy\n' > "$STATE/crew-a.status"
  printf 'working: implementing\n' > "$STATE/crew-b.status"
  cat > "$STATE/crew-a.wait" <<'EOF'
schema=fm-external-wait.v1
kind=predicate
description=wait for CI green
role=external-wait
EOF
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_wake_append signal crew-a "status needs-decision" || fail "wake append"
  fm_wake_append check crew-b "pause recheck due" || fail "wake append 2"
}

test_handoff_persistence_and_restart_preservation() {
  local out handoff
  reset_home
  "$LIFE" ensure >/dev/null
  seed_fleet_inventory

  out=$("$LIFE" write-handoff --reason stow-before-rotate) || fail "write-handoff"
  printf '%s\n' "$out" | grep -q 'reports=2' || fail "reports count: $out"
  printf '%s\n' "$out" | grep -q 'wakes=2' || fail "wakes count: $out"
  printf '%s\n' "$out" | grep -q 'decisions=1' || fail "decisions count: $out"
  printf '%s\n' "$out" | grep -q 'rechecks=1' || fail "rechecks count: $out"
  [ -f "$STATE/.session-handoff" ] || fail "machine handoff missing"
  [ -f "$DATA/session-handoff.md" ] || fail "human handoff md missing"
  grep -q 'fm-session-handoff.v1' "$STATE/.session-handoff" || fail "schema missing"
  grep -q 'crew-a|' "$STATE/.session-handoff" || fail "direct report missing from handoff"
  grep -q 'needs-decision' "$STATE/.session-handoff" || fail "decision missing from handoff"

  out=$("$LIFE" verify-preservation) || fail "immediate verify should pass: $out"
  printf '%s\n' "$out" | grep -q 'verify-preservation: ok' || fail "ok line: $out"

  # Simulate session rotation: new session counters, fleet inventory intact.
  out=$("$LIFE" begin-session --reason rotate) || fail "begin-session: $out"
  printf '%s\n' "$out" | grep -q 'session_id=' || fail "new session_id: $out"
  handoff=$(printf '%s\n' "$out" | sed -n 's/.*handoff=//p' | awk '{print $1}')
  [ -n "$handoff" ] && [ -f "$handoff" ] || fail "handoff path from begin-session: out=$out handoff=$handoff"
  out=$("$LIFE" verify-preservation) || fail "post-rotate verify must preserve inventory"
  out=$("$LIFE" status)
  printf '%s\n' "$out" | grep -qx 'traffic_bytes=0' || fail "new session zeros traffic: $out"
  printf '%s\n' "$out" | grep -qx 'forced_continuations=0' || fail "new session zeros forced: $out"

  # Prove fail path: drop a direct report.
  rm -f "$STATE/crew-b.meta"
  if out=$("$LIFE" verify-preservation 2>&1); then
    fail "verify should fail after meta removal: $out"
  fi
  printf '%s\n' "$out" | grep -q 'missing direct report meta: crew-b' || fail "missing report msg: $out"

  # Drop a wake line.
  : > "$STATE/.wake-queue"
  if out=$("$LIFE" verify-preservation 2>&1); then
    fail "verify should fail after wake wipe: $out"
  fi
  printf '%s\n' "$out" | grep -q 'missing queued wake' || fail "missing wake msg: $out"

  pass "handoff persists and restart preservation is proven"
}

test_one_wake_per_action_batch() {
  local lines out
  reset_home
  # Trip compact and queue once; second evaluate must not duplicate.
  FM_COMPACT_TRAFFIC_BYTES=10 "$LIFE" record-traffic 10 >/dev/null
  out=$(FM_COMPACT_TRAFFIC_BYTES=10 "$LIFE" evaluate --queue-wake) || fail "queue 1"
  assert_action "$out" compact
  lines=$(grep -c 'session-lifecycle' "$STATE/.wake-queue" || true)
  [ "$lines" = 1 ] || fail "expected 1 lifecycle wake, got $lines"

  out=$(FM_COMPACT_TRAFFIC_BYTES=10 "$LIFE" evaluate --queue-wake) || fail "queue 2"
  lines=$(grep -c 'session-lifecycle' "$STATE/.wake-queue" || true)
  [ "$lines" = 1 ] || fail "dedupe failed; got $lines wakes"

  # Escalating to rotate should enqueue one new distinct action wake.
  FM_ROTATE_FORCED_CONTINUATIONS=1 FM_COMPACT_TRAFFIC_BYTES=10 \
    "$LIFE" record-forced-continuation 1 >/dev/null
  out=$(FM_ROTATE_FORCED_CONTINUATIONS=1 FM_COMPACT_TRAFFIC_BYTES=10 \
    "$LIFE" evaluate --queue-wake) || fail "queue rotate"
  assert_action "$out" rotate
  lines=$(grep -c 'session-lifecycle' "$STATE/.wake-queue" || true)
  [ "$lines" = 2 ] || fail "expected second wake for rotate, got $lines"
  pass "one durable wake per distinct compact/rotate action"
}

test_defaults_under_threshold
test_compact_on_traffic_threshold
test_compact_on_turn_cap
test_rotate_on_traffic_forced_and_age
test_rotate_wins_over_compact
test_mark_compacted_resets_since_counters
test_config_file_thresholds
test_handoff_persistence_and_restart_preservation
test_one_wake_per_action_batch

echo "All fm-session-lifecycle tests passed."
