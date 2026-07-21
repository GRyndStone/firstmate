#!/usr/bin/env bash
# Contract tests for firstmate PR delivery-gate CI (direct-PR default,
# explicit no-mistakes still fail-closed without the pipeline signature).
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

workflow="$ROOT/.github/workflows/no-mistakes-required.yml"
contributing="$ROOT/CONTRIBUTING.md"
gate="$ROOT/bin/fm-pr-delivery-check.sh"
marker=$("$gate" --print-marker)

# --- workflow wiring --------------------------------------------------------

grep -F 'types: [opened, edited, synchronize, reopened, labeled, unlabeled]' "$workflow" >/dev/null \
  || fail "delivery gate does not rerun after body, branch, or label updates"
grep -F 'bin/fm-pr-delivery-check.sh' "$workflow" >/dev/null \
  || fail "workflow does not invoke the shared delivery-check owner"
grep -F "name: PR delivery gate" "$workflow" >/dev/null \
  || fail "workflow title no longer describes the delivery gate"
grep -F 'Verify PR delivery path' "$workflow" >/dev/null \
  || fail "workflow job name missing"

# --- contributing + canonical marker ----------------------------------------

grep -F 'https://github.com/GRyndStone/no-mistakes' "$contributing" >/dev/null \
  || fail "contribution guidance does not reference the canonical private repository"
grep -F 'direct-PR' "$contributing" >/dev/null \
  || fail "CONTRIBUTING.md does not document the direct-PR path"
grep -F "$marker" "$contributing" >/dev/null \
  || fail "CONTRIBUTING.md lost the no-mistakes signature marker text"

legacy_owner='kunchenguid'
legacy_repo='no-mistakes'
private_suffix='-private'
for forbidden in \
  "github.com/$legacy_owner/$legacy_repo" \
  "raw.githubusercontent.com/$legacy_owner/$legacy_repo" \
  "$legacy_repo$private_suffix" \
  "GRyndStone/$legacy_repo$private_suffix"
do
  if git -C "$ROOT" grep -n -F "$forbidden"; then
    fail "active tracked Firstmate files contain forbidden no-mistakes reference: $forbidden"
  fi
done

# --- gate behavior ----------------------------------------------------------

run_gate() {
  local body=$1 labels=${2:-} status out
  out=$(PR_BODY="$body" PR_LABELS="$labels" "$gate" 2>&1) && status=0 || status=$?
  printf '%s\n' "$out"
  return "$status"
}

test_direct_pr_empty_body_accepted() {
  local out status=0
  out=$(run_gate '' '') || status=$?
  expect_code 0 "$status" "empty body (ordinary direct-PR) must be accepted"
  assert_contains "$out" "direct-PR" "empty body acceptance message missing"
  pass "direct-PR: empty body accepted without signature"
}

test_direct_pr_summary_body_accepted() {
  local out status=0
  out=$(run_gate $'## Summary\n\nOrdinary change via gh-axi.\n' '') || status=$?
  expect_code 0 "$status" "plain direct-PR body must be accepted"
  pass "direct-PR: ordinary summary body accepted"
}

test_no_mistakes_signature_accepted() {
  local out status=0 body
  body=$(printf '## Pipeline\n\n%s\n' "$marker")
  out=$(run_gate "$body" '') || status=$?
  expect_code 0 "$status" "no-mistakes signature must pass"
  assert_contains "$out" "no-mistakes signature present" "signature acceptance message missing"
  pass "no-mistakes: signature alone accepted"
}

test_explicit_label_requires_signature() {
  local out status=0
  out=$(run_gate $'## Summary\nno signature\n' 'no-mistakes') || status=$?
  expect_code 1 "$status" "label no-mistakes without signature must fail"
  assert_contains "$out" "requires the no-mistakes delivery path" "strict fail message missing"
  pass "explicit no-mistakes label fails closed without signature"
}

test_explicit_delivery_line_requires_signature() {
  local out status=0
  out=$(run_gate $'## Summary\ndelivery: no-mistakes\n' '') || status=$?
  expect_code 1 "$status" "delivery: no-mistakes without signature must fail"
  pass "explicit delivery: no-mistakes line fails closed without signature"
}

test_explicit_label_with_signature_accepted() {
  local out status=0 body
  body=$(printf 'delivery: no-mistakes\n\n%s\n' "$marker")
  out=$(run_gate "$body" 'no-mistakes,ready') || status=$?
  expect_code 0 "$status" "explicit no-mistakes with signature must pass"
  pass "explicit no-mistakes with signature accepted"
}

test_other_labels_do_not_require_signature() {
  local out status=0
  out=$(run_gate 'plain body' 'bug,enhancement') || status=$?
  expect_code 0 "$status" "unrelated labels must not force no-mistakes"
  pass "unrelated labels keep direct-PR acceptance"
}

test_direct_pr_empty_body_accepted
test_direct_pr_summary_body_accepted
test_no_mistakes_signature_accepted
test_explicit_label_requires_signature
test_explicit_delivery_line_requires_signature
test_explicit_label_with_signature_accepted
test_other_labels_do_not_require_signature

pass "private no-mistakes workflow and operator references are canonical"
