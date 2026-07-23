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
