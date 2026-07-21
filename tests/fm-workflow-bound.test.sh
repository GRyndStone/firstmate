#!/usr/bin/env bash
# Focused tests for finite workflow bounds: budget inheritance, two-attempt
# obstacle caps, deterministic auth preflight, and analyst idle/checkpoint.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-workflow-bound-tests
STATE="$TMP_ROOT/state"
DATA="$TMP_ROOT/data"
mkdir -p "$STATE" "$DATA"
export FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA"
BOUND="$ROOT/bin/fm-workflow-bound.sh"

write_parent_meta() {
  local path=$1
  cat > "$path" <<'EOF'
provider=codex
harness=codex
model=gpt-5.5
effort=high
budget_depth=2
budget_concurrency=3
budget_max_turns=40
budget_turns_used=5
lane_kind=gsd
kind=scout
EOF
}

test_inherit_budget_from_parent() {
  local out parent
  parent="$STATE/gsd-parent.meta"
  write_parent_meta "$parent"
  out=$("$BOUND" inherit-budget --parent-meta "$parent" --parent-id gsd-parent) || fail "inherit-budget failed"
  printf '%s\n' "$out" | grep -qx 'provider=codex' || fail "child missing inherited provider: $out"
  printf '%s\n' "$out" | grep -qx 'harness=codex' || fail "child missing inherited harness: $out"
  printf '%s\n' "$out" | grep -qx 'model=gpt-5.5' || fail "child missing inherited model: $out"
  printf '%s\n' "$out" | grep -qx 'effort=high' || fail "child missing inherited effort: $out"
  printf '%s\n' "$out" | grep -qx 'budget_depth=1' || fail "child depth should be parent-1: $out"
  printf '%s\n' "$out" | grep -qx 'budget_concurrency=3' || fail "child concurrency should inherit: $out"
  printf '%s\n' "$out" | grep -qx 'budget_max_turns=35' || fail "child turns should be remaining 40-5=35: $out"
  printf '%s\n' "$out" | grep -qx 'budget_turns_used=0' || fail "child turns_used should reset: $out"
  printf '%s\n' "$out" | grep -qx 'parent_id=gsd-parent' || fail "child missing parent_id: $out"
  printf '%s\n' "$out" | grep -qx 'lane_kind=gsd' || fail "child missing lane_kind: $out"
  pass "inherit-budget copies pin and remaining caps"
}

test_inherit_refuses_depth_zero() {
  local parent err status
  parent="$STATE/leaf.meta"
  cat > "$parent" <<'EOF'
provider=claude
harness=claude
model=sonnet
effort=high
budget_depth=0
budget_concurrency=1
budget_max_turns=5
budget_turns_used=0
EOF
  status=0
  err=$("$BOUND" inherit-budget --parent-meta "$parent" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "expected depth-0 parent to refuse child"
  printf '%s\n' "$err" | grep -q 'budget_depth is 0' || fail "expected depth-0 refusal message, got: $err"
  pass "inherit-budget refuses unbounded child when parent depth is 0"
}

test_default_budget_root() {
  local out
  out=$("$BOUND" default-budget --provider grok --harness grok --model grok-4.5 --effort high --lane-kind impl) \
    || fail "default-budget failed"
  printf '%s\n' "$out" | grep -qx 'provider=grok' || fail "root missing provider: $out"
  printf '%s\n' "$out" | grep -qx 'budget_depth=2' || fail "root default depth: $out"
  printf '%s\n' "$out" | grep -qx 'budget_concurrency=2' || fail "root default concurrency: $out"
  printf '%s\n' "$out" | grep -qx 'budget_max_turns=40' || fail "root default max turns: $out"
  printf '%s\n' "$out" | grep -qx 'lane_kind=impl' || fail "root missing lane_kind: $out"
  printf '%s\n' "$out" | grep -q 'parent_id=' && fail "root must not set parent_id: $out"
  pass "default-budget stamps root caps"
}

test_two_attempt_obstacle_cap() {
  local out status id=task-obs key="auth failed"
  out=$("$BOUND" note-obstacle "$id" "$key") || fail "attempt 1 should allow"
  printf '%s\n' "$out" | grep -q 'allow: attempt 1 of 2' || fail "attempt 1 message: $out"
  [ "$("$BOUND" obstacle-count "$id" "$key")" = 1 ] || fail "count after 1"
  out=$("$BOUND" note-obstacle "$id" "$key") || fail "attempt 2 should allow"
  printf '%s\n' "$out" | grep -q 'allow: attempt 2 of 2' || fail "attempt 2 message: $out"
  printf '%s\n' "$out" | grep -q 'requires captain decision' || fail "attempt 2 should warn captain path: $out"
  status=0
  out=$("$BOUND" note-obstacle "$id" "$key" 2>&1) || status=$?
  [ "$status" -eq 3 ] || fail "attempt 3 should exit 3, got $status: $out"
  printf '%s\n' "$out" | grep -q 'needs-decision:' || fail "attempt 3 must surface needs-decision: $out"
  printf '%s\n' "$out" | grep -q 'exceeded 2 free attempts' || fail "attempt 3 reason: $out"
  [ "$("$BOUND" obstacle-count "$id" "$key")" = 3 ] || fail "count after 3"
  # Distinct obstacle key is independent.
  out=$("$BOUND" note-obstacle "$id" "other-obstacle") || fail "distinct key should allow"
  printf '%s\n' "$out" | grep -q 'allow: attempt 1 of 2' || fail "distinct key attempt 1: $out"
  pass "two-attempt obstacle cap escalates on third"
}

test_auth_preflight_deterministic() {
  local out status
  out=$(FM_AUTH_GH_STATUS_CMD=true FM_AUTH_CODEX_CMD=true \
    "$BOUND" auth-preflight --provider codex --require-gh) || fail "auth should pass with stubs"
  printf '%s\n' "$out" | grep -q 'ok: auth-preflight passed for codex' || fail "pass message: $out"

  status=0
  out=$(FM_AUTH_GH_STATUS_CMD=false "$BOUND" auth-preflight --require-gh 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "failed gh auth should fail preflight"
  printf '%s\n' "$out" | grep -q 'auth-preflight failed' || fail "failure reason missing: $out"
  printf '%s\n' "$out" | grep -qi 'model' && fail "auth preflight must not mention model churn: $out"

  status=0
  out=$(FM_AUTH_CLAUDE_CMD=false env -u CLAUDE_CODE_OAUTH_TOKEN \
    "$BOUND" auth-preflight --provider claude 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "missing claude auth should fail"
  out=$(FM_AUTH_CLAUDE_CMD=false CLAUDE_CODE_OAUTH_TOKEN=token-value \
    "$BOUND" auth-preflight --provider claude) || fail "token should satisfy claude preflight without CLI"
  pass "auth-preflight is deterministic and model-free"
}

test_analyst_checkpoint_and_idle() {
  local path status_line id=analyst-fx
  path=$("$BOUND" analyst-checkpoint "$id" --summary "next experiment ranked") || fail "checkpoint failed"
  [ -f "$path" ] || fail "checkpoint file missing: $path"
  grep -q 'lane_kind: analyst' "$path" || fail "checkpoint missing lane_kind"
  grep -q 'blocks_implementation: false' "$path" || fail "checkpoint must not block implementation"
  grep -q 'additive: true' "$path" || fail "checkpoint must be additive"
  grep -q 'next experiment ranked' "$path" || fail "checkpoint missing summary"

  path=$("$BOUND" analyst-checkpoint "$id" --summary "second cycle") || fail "second checkpoint"
  case "$path" in */002.md) ;; *) fail "second checkpoint should be 002: $path" ;; esac

  "$BOUND" analyst-idle "$id" --reason "waiting for next evidence batch" >/dev/null || fail "idle failed"
  [ -f "$STATE/$id.status" ] || fail "idle must write status"
  status_line=$(tail -1 "$STATE/$id.status")
  printf '%s\n' "$status_line" | grep -q '^paused:' || fail "idle must append paused: $status_line"
  grep -q 'lane_kind=analyst' "$STATE/$id.meta" || fail "idle must mark lane_kind=analyst"
  [ -x "$DATA/$id/idle-predicate.sh" ] || fail "idle predicate missing"
  # Predicate stays pending (model-free idle, not complete).
  if "$DATA/$id/idle-predicate.sh"; then
    fail "idle predicate must stay pending (exit non-zero)"
  fi
  pass "analyst checkpoint + model-free idle"
}

test_analyst_never_dependency() {
  local status out
  cat > "$STATE/analyst-a.meta" <<'EOF'
kind=scout
lane_kind=analyst
harness=codex
EOF
  cat > "$STATE/impl-b.meta" <<'EOF'
kind=ship
lane_kind=impl
harness=codex
EOF
  status=0
  out=$("$BOUND" assert-no-analyst-dependency impl-b --blocked-by analyst-a 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "impl blocked-by analyst must refuse"
  printf '%s\n' "$out" | grep -q "must not depend on analyst" || fail "refusal message: $out"

  out=$("$BOUND" assert-no-analyst-dependency impl-b --blocked-by other-impl) || fail "non-analyst dep should pass"
  printf '%s\n' "$out" | grep -q 'ok: no analyst dependencies' || fail "ok message: $out"
  pass "analysts cannot be implementation dependencies"
}

test_inherit_budget_from_parent
test_inherit_refuses_depth_zero
test_default_budget_root
test_two_attempt_obstacle_cap
test_auth_preflight_deterministic
test_analyst_checkpoint_and_idle
test_analyst_never_dependency

echo "All fm-workflow-bound tests passed."
