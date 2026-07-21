#!/usr/bin/env bash
# Goal↔task linkage and evidence-only KURU organ boundary (T-e.2).
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ORGAN="$ROOT/bin/fm-kuru-organ.sh"
# shellcheck source=bin/fm-kuru-organ-lib.sh disable=SC1091
. "$ROOT/bin/fm-kuru-organ-lib.sh"

fm_test_tmproot TMP_ROOT fm-kuru-organ
STATE="$TMP_ROOT/state"
DATA="$TMP_ROOT/data"
mkdir -p "$STATE" "$DATA"

export FM_HOME="$TMP_ROOT"
export FM_STATE_OVERRIDE="$STATE"
export FM_DATA_OVERRIDE="$DATA"

write_dispatch() {
  local path=$1 id=$2 goal=$3 status=${4:-queued} organ_ref=${5:-}
  python3 - "$path" "$id" "$goal" "$status" "$organ_ref" <<'PY'
import json, sys
path, did, goal, status, organ_ref = sys.argv[1:6]
d = {
    "type": "dispatch",
    "id": did,
    "goal_slug": goal,
    "criterion_ids": ["C1"],
    "organ": "orchestration",
    "adapter": "firstmate",
    "brief": "bounded organ test work",
    "profile": None,
    "validator": None,
    "status": status,
    "created_ts": 0.0,
    "updated_ts": 0.0,
    "organ_ref": organ_ref or None,
    "blocked_reason": None,
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PY
}

# --- AGENTS organ clause ----------------------------------------------------

test_agents_organ_clause() {
  local agents="$ROOT/AGENTS.md"
  assert_grep 'bounded orchestration organ' "$agents" \
    "AGENTS.md missing KURU organ demotion clause"
  assert_grep 'evidence only' "$agents" \
    "AGENTS.md organ clause must require evidence-only returns"
  assert_grep 'kuru_goal=' "$agents" \
    "AGENTS.md must document kuru_goal= linkage field"
  # Must not claim sole SoR without the organ qualification when KURU is active.
  assert_grep 'Under the KURU' "$agents" \
    "AGENTS.md must qualify identity under KURU architecture"
  pass "AGENTS.md carries KURU organ demotion and linkage field"
}

# --- linkage ----------------------------------------------------------------

test_link_unlink_and_inverse() {
  local out
  fm_write_meta "$STATE/ship-a1.meta" \
    "window=fm-ship-a1" \
    "kind=ship" \
    "generation=gen-link-1"

  out=$("$ORGAN" link ship-a1 --goal fm-kuru-organ-adapter-d9 --dispatch d-test-1)
  assert_contains "$out" "goal=fm-kuru-organ-adapter-d9" "link stdout missing goal"
  assert_contains "$out" "dispatch=d-test-1" "link stdout missing dispatch"

  out=$("$ORGAN" show-link ship-a1)
  assert_contains "$out" "goal=fm-kuru-organ-adapter-d9" "show-link lost goal"
  assert_contains "$out" "dispatch=d-test-1" "show-link lost dispatch"

  grep -q '^kuru_goal=fm-kuru-organ-adapter-d9$' "$STATE/ship-a1.meta" \
    || fail "meta missing kuru_goal= after link"
  grep -q '^kuru_dispatch=d-test-1$' "$STATE/ship-a1.meta" \
    || fail "meta missing kuru_dispatch= after link"

  [ -f "$DATA/kuru-goal-index/fm-kuru-organ-adapter-d9" ] \
    || fail "durable goal index not written"
  grep -Fxq 'ship-a1' "$DATA/kuru-goal-index/fm-kuru-organ-adapter-d9" \
    || fail "durable index missing task id"

  out=$("$ORGAN" find-goal fm-kuru-organ-adapter-d9)
  assert_contains "$out" "ship-a1" "find-goal inverse missing task"

  out=$("$ORGAN" unlink ship-a1)
  assert_contains "$out" "unlinked task=ship-a1" "unlink stdout wrong"
  if grep -q '^kuru_goal=' "$STATE/ship-a1.meta"; then
    fail "kuru_goal= still present after unlink"
  fi
  if [ -f "$DATA/kuru-goal-index/fm-kuru-organ-adapter-d9" ] \
    && grep -Fxq 'ship-a1' "$DATA/kuru-goal-index/fm-kuru-organ-adapter-d9"; then
    fail "durable index still lists task after unlink"
  fi
  pass "link / show / inverse / unlink round-trip"
}

test_false_done_labels_are_not_attainment() {
  # A done: status line alone must never inject outcome into evidence.
  fm_write_meta "$STATE/done-lab.meta" \
    "window=fm-done-lab" \
    "kind=ship" \
    "generation=gen-done-1"
  printf 'done: PR https://example.test/pr/1\n' > "$STATE/done-lab.status"
  write_dispatch "$TMP_ROOT/d-done.json" "d-done-lab" "goal-done-lab" "running" "done-lab"
  "$ORGAN" link done-lab --goal goal-done-lab --dispatch d-done-lab >/dev/null

  local ev
  ev=$("$ORGAN" call collect_evidence --dispatch-file "$TMP_ROOT/d-done.json" --task-id done-lab --result ok)
  assert_contains "$ev" '"result": "ok"' "collect_evidence should allow ok as evidence result"
  assert_contains "$ev" 'evidence_only' "evidence must mark evidence_only"
  assert_contains "$ev" 'not_criterion_attainment' "evidence must refuse false criterion attainment"
  assert_not_contains "$ev" '"outcome"' "evidence must not carry outcome"
  assert_not_contains "$ev" '"attained"' "evidence must not carry attained"
  printf '%s\n' "$ev" > "$TMP_ROOT/ev-done.json"
  out=$("$ORGAN" validate-evidence "$TMP_ROOT/ev-done.json")
  assert_contains "$out" "ok" "validate-evidence should accept clean evidence"
  pass "done: labels produce evidence only, never outcome attainment"
}

# --- organ boundary ---------------------------------------------------------

test_routing_verbs_refused() {
  local verb rc
  for verb in route choose_model pick_harness select_profile usage_route; do
    rc=0
    out=$("$ORGAN" call "$verb" --dispatch-file /dev/null 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "routing verb $verb was accepted"
    assert_contains "$out" "routing" "refusal for $verb should mention routing"
  done
  pass "routing verbs are refused (no second router)"
}

test_bind_only_spawn_no_initiative() {
  write_dispatch "$TMP_ROOT/d-spawn.json" "d-spawn-1" "goal-spawn-1" "queued"
  local ev
  ev=$("$ORGAN" call spawn --dispatch-file "$TMP_ROOT/d-spawn.json" --task-id spawn-t1)
  assert_contains "$ev" '"type": "evidence"' "spawn must return evidence"
  assert_contains "$ev" 'bind-only' "spawn summary must declare bind-only"
  assert_contains "$ev" 'no initiative' "spawn must not arm initiative"
  assert_not_contains "$ev" '"outcome"' "spawn evidence must not carry outcome"
  grep -q '^kuru_goal=goal-spawn-1$' "$STATE/spawn-t1.meta" \
    || fail "spawn bind did not set kuru_goal="
  grep -q '^organ_bound=1$' "$STATE/spawn-t1.meta" \
    || fail "spawn bind did not set organ_bound=1"
  # Must not create a live window that looks like a real backend launch claim beyond organ-bound.
  grep -q '^window=organ-bound:spawn-t1$' "$STATE/spawn-t1.meta" \
    || fail "bind-only meta window marker missing"
  pass "organ spawn is bind-only and does not arm initiative"
}

test_make_evidence_rejects_forbidden_refs() {
  local rc=0 err
  err=$(fm_kuru_make_evidence \
    --id ev-bad-1 \
    --dispatch-id d-bad-1 \
    --goal goal-bad \
    --surface task \
    --result ok \
    --summary "should fail" \
    --refs-json '{"attained": true}' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "make_evidence accepted attained in refs"
  assert_contains "$err" "attained" "error should name forbidden key"
  pass "make_evidence refuses outcome smuggling via refs"
}

test_validate_dispatch_refuses_outcome() {
  python3 - "$TMP_ROOT/d-out.json" <<'PY'
import json, sys
d = {
    "type": "dispatch",
    "id": "d-out-1",
    "goal_slug": "goal-out",
    "criterion_ids": [],
    "organ": "orchestration",
    "adapter": "firstmate",
    "brief": "x",
    "profile": None,
    "validator": None,
    "status": "queued",
    "created_ts": 0,
    "updated_ts": 0,
    "organ_ref": None,
    "blocked_reason": None,
    "outcome": "attained",
}
json.dump(d, open(sys.argv[1], "w"))
PY
  rc=0
  out=$("$ORGAN" validate-dispatch "$TMP_ROOT/d-out.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "dispatch with outcome was accepted"
  assert_contains "$out" "outcome" "refusal should mention outcome"
  pass "validate-dispatch refuses outcome authority on dispatch"
}

test_status_and_teardown_evidence() {
  write_dispatch "$TMP_ROOT/d-st.json" "d-st-1" "goal-st" "running" "st-t1"
  fm_write_meta "$STATE/st-t1.meta" \
    "window=fm-st-t1" \
    "kind=ship" \
    "generation=gen-st-1" \
    "kuru_goal=goal-st"
  printf 'working: implementing\n' > "$STATE/st-t1.status"
  mkdir -p "$DATA/kuru-goal-index"
  printf 'st-t1\n' > "$DATA/kuru-goal-index/goal-st"

  local ev
  ev=$("$ORGAN" call status --dispatch-file "$TMP_ROOT/d-st.json" --task-id st-t1)
  assert_contains "$ev" '"surface": "log"' "status evidence surface should be log"
  assert_contains "$ev" '"result": "pending"' "working status should be pending evidence"
  assert_not_contains "$ev" '"outcome"' "status evidence must not carry outcome"

  ev=$("$ORGAN" call teardown --dispatch-file "$TMP_ROOT/d-st.json" --task-id st-t1)
  assert_contains "$ev" '"result": "failed"' "teardown evidence result is failed (cancelled path)"
  if grep -q '^kuru_goal=' "$STATE/st-t1.meta" 2>/dev/null; then
    fail "teardown should clear kuru_goal link"
  fi
  pass "status and teardown return evidence only and clear link on teardown"
}

# --- run --------------------------------------------------------------------

test_agents_organ_clause
test_link_unlink_and_inverse
test_false_done_labels_are_not_attainment
test_routing_verbs_refused
test_bind_only_spawn_no_initiative
test_make_evidence_rejects_forbidden_refs
test_validate_dispatch_refuses_outcome
test_status_and_teardown_evidence
