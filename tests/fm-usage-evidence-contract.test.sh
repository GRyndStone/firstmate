#!/usr/bin/env bash
# Behavior tests for absorb/kuru/usage_evidence_contract.py.
#
# The contract exists because a decoder that stops decoding is indistinguishable
# from a provider with no quota pressure. Both regressions it guards against are
# REAL and already happened in quota-axi 0.1.13:
#
#   1. identifier drift - product:grokbuild -> product:grok_build and
#      product:grokimagine -> product:imagine, a PARTIAL rename (4 of 6 ids
#      survived), so a check asking only "did any pinned id survive" passes it.
#   2. discarded window length - every emitted window carried windowSeconds:null
#      because the adapter decoded the billing period, validated with it, then
#      dropped it.
#
# tests/fixtures/usage-evidence/upstream-0.1.13-regressed.json is not hand-written:
# it is the scrubbed output of a real build of upstream main (a9ca3e1), so these
# tests fail against the genuine published decoder, not against a strawman.
#
# Every assertion below is paired: each failing case has a conforming counterpart
# that must pass, so no assertion is true merely because it evaluates.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTRACT="$ROOT/absorb/kuru/usage_evidence_contract.py"
PINS="$ROOT/absorb/kuru/usage-evidence-contract.json"
FIX="$ROOT/tests/fixtures/usage-evidence"
REGRESSED="$FIX/upstream-0.1.13-regressed.json"
CONFORMING="$FIX/conforming.json"

fm_test_tmproot TMP_ROOT fm-usage-evidence-contract

# python3 is required, never optional: skipping on a missing interpreter would
# make the whole suite silently vacuous on exactly the machines that need it.
command -v python3 >/dev/null 2>&1 || fail "python3 is required to run the usage-evidence contract"

run_check() { # <evidence> [extra args...]
  local ev=$1; shift
  python3 "$CONTRACT" check --evidence "$ev" --contract "$PINS" "$@" 2>"$TMP_ROOT/err.txt"
}

test_artifacts_exist() {
  assert_present "$CONTRACT" "the contract mechanism is missing"
  assert_present "$PINS" "the pinned contract is missing"
  assert_present "$REGRESSED" "the real regressed-upstream fixture is missing"
  assert_present "$CONFORMING" "the conforming fixture is missing"
  pass "contract, pins, and both real fixtures are present"
}

test_conforming_evidence_passes() {
  run_check "$CONFORMING" >/dev/null || fail "conforming evidence must pass; got exit $?"
  pass "conforming evidence passes (so the failing cases below are not vacuous)"
}

test_real_upstream_regression_fails_loudly() {
  local out status
  out=$(run_check "$REGRESSED" --provider grok) && status=0 || status=$?
  [ "$status" -eq 12 ] || fail "real upstream 0.1.13 output must exit 12 (contract violation); got $status"
  assert_contains "$out" '"ok": false' "the report must state ok:false"
  # Loud means stderr, not just a JSON field a caller may ignore.
  assert_grep 'CONTRACT VIOLATION' "$TMP_ROOT/err.txt" "violations must be reported loudly on stderr"
  pass "genuine upstream 0.1.13 evidence fails loudly with exit 12"
}

test_partial_rename_is_caught() {
  local err
  run_check "$REGRESSED" --provider grok >/dev/null || true
  err=$(cat "$TMP_ROOT/err.txt")
  assert_contains "$err" "identifier-drift" "a renamed pinned id must raise identifier-drift"
  assert_contains "$err" "product:grokbuild" "the specific renamed id must be named"
  # The regression is partial: these ids DID survive upstream. If the check only
  # fired when every pinned id vanished, it would have missed the real failure.
  assert_contains "$err" "product:grok_build" "the drift message must show what the organ emits now"
  pass "partial rename is caught (4 of 6 ids survived and it still fires)"
}

test_discarded_window_length_is_caught() {
  local err
  run_check "$REGRESSED" --provider grok >/dev/null || true
  err=$(cat "$TMP_ROOT/err.txt")
  assert_contains "$err" "windowSeconds" "a dropped window length must be reported"
  pass "windows emitted without a usable length are caught"
}

# A fresh decoder that emits nothing is the silent-nothing failure in its purest
# form: downstream it is identical to "this provider has no limits".
test_fresh_but_empty_is_caught() {
  local ev=$TMP_ROOT/empty.json err
  cat > "$ev" <<'JSON'
{"providers":[{"provider":"claude","state":{"status":"fresh"},"windows":[]}]}
JSON
  run_check "$ev" --provider claude >/dev/null && fail "a fresh provider with no windows must not pass"
  err=$(cat "$TMP_ROOT/err.txt")
  assert_contains "$err" "fresh-but-empty" "an empty fresh decoder must raise fresh-but-empty"
  pass "a fresh provider emitting no windows fails"
}

# The paired negative: auth_required with no windows is NOT a decoder fault, so
# the check must stay quiet. Without this, fresh-but-empty could be a blanket
# "any empty window list fails" rule that fires on healthy states.
test_auth_required_empty_is_not_a_violation() {
  local ev=$TMP_ROOT/authreq.json
  cat > "$ev" <<'JSON'
{"providers":[{"provider":"cursor","state":{"status":"auth_required"},"windows":[]}]}
JSON
  run_check "$ev" --provider cursor >/dev/null || fail "auth_required with no windows must not be a violation"
  pass "auth_required with no windows is correctly not a violation"
}

test_disappearing_required_provider_is_caught() {
  local ev=$TMP_ROOT/gone.json err
  cat > "$ev" <<'JSON'
{"providers":[{"provider":"claude","state":{"status":"fresh"},
 "windows":[{"id":"five_hour","kind":"session","percentRemaining":50,
 "resetsAt":"2026-07-26T00:00:00Z","windowSeconds":18000}]}]}
JSON
  run_check "$ev" >/dev/null && fail "a required provider vanishing must not pass"
  err=$(cat "$TMP_ROOT/err.txt")
  assert_contains "$err" "provider-absent" "a required provider's disappearance must be reported"
  pass "a required provider silently disappearing fails"
}

# KURU decision 0028: the selector makes NO subprocess call and takes no non-KURU
# router as a runtime dependency. This mechanism sits on that boundary, so the
# prohibition is asserted against the source rather than trusted.
test_makes_no_subprocess_call() {
  # Assert the MECHANISMS of shelling out, not the word "quota-axi": the
  # docstring names it deliberately to explain what the contract guards, and a
  # naive string ban would forbid the explanation while permitting os.popen.
  local bad
  # Code-shaped usage only: an import, or a call. Prose in the docstring that
  # says the mechanism makes no subprocess call must not trip its own check.
  bad=$(grep -nE '^[[:space:]]*(import|from)[[:space:]]+(subprocess|shutil)\b|(subprocess|os|shutil)\.[a-z_]+\(' \
    "$CONTRACT" || true)
  [ -z "$bad" ] || fail "0028 forbids shelling out; found: $bad"
  pass "the mechanism makes no subprocess call (KURU decision 0028)"
}

# KURU's measured minimum is Python 3.10 + PyYAML. This mechanism must not widen
# it: any third-party import here would make absorption cost a new dependency.
test_stdlib_only() {
  local bad
  bad=$(grep -E '^(import|from) ' "$CONTRACT" |
    grep -vE '^(import|from) (__future__|json|sys|typing)\b' || true)
  [ -z "$bad" ] || fail "only stdlib imports are allowed; found: $bad"
  pass "stdlib-only, so absorbing it adds no KURU dependency"
}

test_artifacts_exist
test_conforming_evidence_passes
test_real_upstream_regression_fails_loudly
test_partial_rename_is_caught
test_discarded_window_length_is_caught
test_fresh_but_empty_is_caught
test_auth_required_empty_is_not_a_violation
test_disappearing_required_provider_is_caught
test_makes_no_subprocess_call
test_stdlib_only
