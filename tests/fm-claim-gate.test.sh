#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for the Stop-event claim gate (bin/fm-claim-gate.sh).
#
# The gate exists because AGENTS.md section 1 rule 5 - delegated conclusions are
# evidence, never authority - had no mechanical enforcement and decayed. These
# tests pin the two properties that make it worth having rather than merely
# present: it blocks an inherited claim, and an honest downgrade always passes.
# Every fail-open path is asserted too, because a guard that can break a session
# gets switched off and then protects nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-claim-gate.sh"

command -v jq >/dev/null 2>&1 || { pass "fm-claim-gate: skipped, jq unavailable"; exit 0; }

fm_test_tmproot HOME_DIR fm-claim-gate
fm_git_identity

# A stand-in PRIMARY checkout: a plain (non-worktree) git repo carrying the
# markers the gate scopes on.
mkdir -p "$HOME_DIR/bin" "$HOME_DIR/state"
printf 'stub\n' >"$HOME_DIR/AGENTS.md"
git -C "$HOME_DIR" init -q
git -C "$HOME_DIR" add -A
git -C "$HOME_DIR" commit -qm init

# --- transcript fixtures -----------------------------------------------------
# A turn is: one genuine captain prompt, then assistant entries. Tool results
# arrive as "user" entries and must NOT be mistaken for a new prompt, which is
# why the read-only fixture interleaves one.

write_transcript() {
  # write_transcript <path> <tool-name>
  local path=$1 tool=$2
  {
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"how did that land?"}}'
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"%s","input":{}}]}}\n' "$tool"
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}'
  } >"$path"
}

write_bash_transcript() {
  # write_bash_transcript <path> <command> <result>
  local path=$1 command=$2 result=$3
  {
    jq -nc '{"type":"user","message":{"role":"user","content":"is the KURU change verified?"}}'
    jq -nc --arg command "$command" '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":$command}}]}}'
    jq -nc --arg result "$result" '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":$result}]}}'
    jq -nc '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}'
  } >"$path"
}

READ_ONLY_TURN="$HOME_DIR/read-only.jsonl"
PROBED_TURN="$HOME_DIR/probed.jsonl"
write_transcript "$READ_ONLY_TURN" Read
write_transcript "$PROBED_TURN" Bash

payload() {
  # payload <message> <transcript> [stop_hook_active]
  jq -nc --arg m "$1" --arg t "$2" --argjson s "${3:-false}" \
    '{stop_hook_active:$s, last_assistant_message:$m, transcript_path:$t}'
}

run_gate() {
  # run_gate <payload> [env assignments...] -> prints stderr, sets RC
  local pl=$1; shift
  local out rc=0
  out=$(printf '%s' "$pl" | env FM_ROOT_OVERRIDE="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$@" \
    bash "$GATE" 2>&1) || rc=$?
  GATE_OUT=$out
  GATE_RC=$rc
}

CLAIM='The work is complete and the checks are green.'
ATTRIBUTED='The verifier reports that the checks are green; I have not confirmed it myself.'
NEUTRAL='I looked at the queue and there is nothing waiting on you.'

# --- the block ---------------------------------------------------------------

run_gate "$(payload "$CLAIM" "$READ_ONLY_TURN")"
expect_code 2 "$GATE_RC" "an inherited claim with no probe this turn must block"
assert_contains "$GATE_OUT" "UNVERIFIED CLAIM" "the block must name what it caught"
assert_contains "$GATE_OUT" "downgrade it" "the block must offer the honest-downgrade path"
pass "fm-claim-gate: blocks a verified-outcome claim the turn never established"

# --- the two ways past ------------------------------------------------------

run_gate "$(payload "$CLAIM" "$PROBED_TURN")"
expect_code 0 "$GATE_RC" "a turn that ran its own command must pass"
pass "fm-claim-gate: probing passes"

run_gate "$(payload "$ATTRIBUTED" "$READ_ONLY_TURN")"
expect_code 0 "$GATE_RC" "an attributed, explicitly-unconfirmed claim must pass"
pass "fm-claim-gate: honest downgrade passes without a probe"

# --- no claim, no block ------------------------------------------------------

run_gate "$(payload "$NEUTRAL" "$READ_ONLY_TURN")"
expect_code 0 "$GATE_RC" "ordinary reporting must not trip the gate"
pass "fm-claim-gate: silent on messages that assert no verified outcome"

# --- KURU product truth ------------------------------------------------------

make_kuru_surface() {
  # make_kuru_surface <dir> <pass|fail>
  local dir=$1 result=$2
  mkdir -p "$dir"
  cat >"$dir/verify-product" <<'SH'
#!/usr/bin/env bash
set -eu
if [ -f FAIL_PRODUCT ]; then
  printf 'fixture product failure\n'
  exit 1
fi
printf 'fixture product pass\n'
SH
  chmod +x "$dir/verify-product"
  if [ "$result" = fail ]; then
    printf 'fail\n' >"$dir/FAIL_PRODUCT"
  fi
}

KURU_REPO="$HOME_DIR/kuru-repo"
KURU_HOME_PASS="$HOME_DIR/kuru-home-pass"
KURU_HOME_FAIL="$HOME_DIR/kuru-home-fail"
make_kuru_surface "$KURU_REPO" pass
make_kuru_surface "$KURU_HOME_PASS" pass
make_kuru_surface "$KURU_HOME_FAIL" fail

KURU_CLAIM='The KURU change is verified and all tests pass.'
KURU_REPO_ONLY='KURU repository-only checks passed; the lived home was not verified.'
KURU_REPO_ONLY_TURN="$HOME_DIR/kuru-repo-only.jsonl"
write_bash_transcript "$KURU_REPO_ONLY_TURN" "cd $KURU_REPO && ./verify-product" "fixture product pass"
KURU_CONTEXT_CLAIM='The change is verified and all tests pass.'

run_gate "$(payload "$KURU_CLAIM" "$KURU_REPO_ONLY_TURN")"
expect_code 2 "$GATE_RC" "a KURU verified claim backed only by repository checks must block"
assert_contains "$GATE_OUT" "KURU PRODUCT VERIFICATION REQUIRED" "the KURU block must name the product gate"
assert_contains "$GATE_OUT" "repository=repository-only" "the block must report repository-only coverage"
assert_contains "$GATE_OUT" "lived-home-copy=not-covered" "the block must report missing lived-home coverage"
pass "fm-claim-gate: KURU verified claim cannot pass on repository-only evidence"

run_gate "$(payload "$KURU_CONTEXT_CLAIM" "$KURU_REPO_ONLY_TURN")"
expect_code 2 "$GATE_RC" "KURU context from the ordinary turn must trigger the product gate even when the final claim omits KURU"
pass "fm-claim-gate: KURU context is read from the turn, not only the final wording"

run_gate "$(payload "$KURU_REPO_ONLY" "$KURU_REPO_ONLY_TURN")"
expect_code 0 "$GATE_RC" "an honest repository-only KURU report must pass"
pass "fm-claim-gate: KURU repository-only downgrade passes"

KURU_DIVERGENT_TURN="$HOME_DIR/kuru-divergent.jsonl"
kuru_divergent_cmd="$ROOT/bin/fm-kuru-product-check.sh --repo $KURU_REPO --home $KURU_HOME_FAIL --check ./verify-product"
kuru_divergent_out=$("$ROOT/bin/fm-kuru-product-check.sh" --repo "$KURU_REPO" --home "$KURU_HOME_FAIL" --check ./verify-product 2>&1) || true
write_bash_transcript "$KURU_DIVERGENT_TURN" "$kuru_divergent_cmd" "$kuru_divergent_out"

run_gate "$(payload "$KURU_CLAIM" "$KURU_DIVERGENT_TURN")"
expect_code 2 "$GATE_RC" "a KURU claim must block when the lived-home copy failed"
assert_contains "$GATE_OUT" "repository=PASS" "the KURU block must report repository pass"
assert_contains "$GATE_OUT" "lived-home-copy=FAIL" "the KURU block must report lived-home failure"
pass "fm-claim-gate: divergent KURU product verification blocks a green claim"

KURU_FAKE_MARKER_TURN="$HOME_DIR/kuru-fake-marker.jsonl"
write_bash_transcript "$KURU_FAKE_MARKER_TURN" "printf '%s\\n' FM_KURU_PRODUCT_CHECK_RESULT=verified" "FM_KURU_PRODUCT_CHECK_RESULT=verified"
run_gate "$(payload "$KURU_CLAIM" "$KURU_FAKE_MARKER_TURN")"
expect_code 2 "$GATE_RC" "a marker without the product-check command must not satisfy the KURU gate"
pass "fm-claim-gate: KURU marker text alone is not accepted as product verification"

KURU_VERIFIED_TURN="$HOME_DIR/kuru-verified.jsonl"
kuru_verified_cmd="$ROOT/bin/fm-kuru-product-check.sh --repo $KURU_REPO --home $KURU_HOME_PASS --check ./verify-product"
kuru_verified_out=$("$ROOT/bin/fm-kuru-product-check.sh" --repo "$KURU_REPO" --home "$KURU_HOME_PASS" --check ./verify-product 2>&1)
write_bash_transcript "$KURU_VERIFIED_TURN" "$kuru_verified_cmd" "$kuru_verified_out"

run_gate "$(payload "$KURU_CLAIM" "$KURU_VERIFIED_TURN")"
expect_code 0 "$GATE_RC" "the ordinary Stop path must allow KURU verified claims only after both surfaces pass"
pass "fm-claim-gate: ordinary Stop path enforces KURU product verification"

# --- loop safety and kill switch --------------------------------------------

run_gate "$(payload "$CLAIM" "$READ_ONLY_TURN" true)"
expect_code 0 "$GATE_RC" "stop_hook_active must cap the gate at one block per turn"
pass "fm-claim-gate: never blocks a forced continuation"

run_gate "$(payload "$CLAIM" "$READ_ONLY_TURN")" FM_CLAIM_GATE_OFF=1
expect_code 0 "$GATE_RC" "FM_CLAIM_GATE_OFF must disable the gate"
pass "fm-claim-gate: kill switch honored"

# --- fail-open paths ---------------------------------------------------------

run_gate "$(payload "$CLAIM" "$HOME_DIR/does-not-exist.jsonl")"
expect_code 0 "$GATE_RC" "an unreadable transcript must fail open"
pass "fm-claim-gate: fails open on an unreadable transcript"

CORRUPT="$HOME_DIR/corrupt.jsonl"
printf 'not json at all\n{"type":\n' >"$CORRUPT"
run_gate "$(payload "$CLAIM" "$CORRUPT")"
expect_code 0 "$GATE_RC" "a malformed transcript must fail open"
pass "fm-claim-gate: fails open on a malformed transcript"

run_gate '{"stop_hook_active":false,"transcript_path":"'"$READ_ONLY_TURN"'"}'
expect_code 0 "$GATE_RC" "a payload with no assistant message must fail open"
pass "fm-claim-gate: fails open when the payload carries no message"

run_gate ''
expect_code 0 "$GATE_RC" "an empty payload must fail open"
pass "fm-claim-gate: fails open on an empty payload"

# --- scoping: only the primary checkout --------------------------------------

fm_test_tmproot WT_DIR fm-claim-gate-wt
git -C "$HOME_DIR" worktree add -q --detach "$WT_DIR/task" >/dev/null 2>&1
if [ -d "$WT_DIR/task" ]; then
  mkdir -p "$WT_DIR/task/state"
  printf 'stub\n' >"$WT_DIR/task/AGENTS.md"
  out=$(printf '%s' "$(payload "$CLAIM" "$READ_ONLY_TURN")" \
    | env FM_ROOT_OVERRIDE="$WT_DIR/task" FM_STATE_OVERRIDE="$WT_DIR/task/state" bash "$GATE" 2>&1) || rc=$?
  expect_code 0 "${rc:-0}" "a linked task worktree must be a silent no-op"
  pass "fm-claim-gate: silent in a crewmate task worktree"
  git -C "$HOME_DIR" worktree remove --force "$WT_DIR/task" >/dev/null 2>&1 || true
fi

SECOND="$HOME_DIR/secondmate"
mkdir -p "$SECOND/state"
printf 'stub\n' >"$SECOND/AGENTS.md"
printf '' >"$SECOND/.fm-secondmate-home"
rc=0
printf '%s' "$(payload "$CLAIM" "$READ_ONLY_TURN")" \
  | env FM_ROOT_OVERRIDE="$SECOND" FM_STATE_OVERRIDE="$SECOND/state" bash "$GATE" >/dev/null 2>&1 || rc=$?
expect_code 0 "$rc" "a secondmate home must be a silent no-op"
pass "fm-claim-gate: silent in a secondmate home"
