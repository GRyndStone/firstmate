#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for the dispatch gate (bin/fm-criteria-check.sh).
#
# The gate refuses work whose criteria trace to nothing the captain asked for.
# The property that matters is provenance, not presence: "the brief has
# criteria" is circular, because the same judgement that wrote a bad brief also
# invents the criteria meant to catch it. So the load-bearing case here is the
# one reproducing the live failure - every criterion sourced to the previous
# round's findings, none to the captain - which must be refused.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-criteria-check.sh"

fm_test_tmproot TMP fm-criteria-check
DATA="$TMP/data"

# seed <id> <criteria-body> [brief-body]
seed() {
  local id=$1 crit=$2 brief=${3:-}
  mkdir -p "$DATA/$id"
  printf '%s\n' "$crit" >"$DATA/$id/criteria.md"
  if [ -n "$brief" ]; then
    printf '%s\n' "$brief" >"$DATA/$id/brief.md"
  fi
}

run_check() {
  local id=$1 out rc=0
  out=$(FM_DATA_OVERRIDE="$DATA" bash "$CHECK" "$id" 2>&1) || rc=$?
  OUT=$out
  RC=$rc
}

GOOD_CRIT='# Ideal state
> somebody uses this on their trusted computer in a trusted folder

## AC-1
claim:  a second session cannot silently take the writer epoch
source: captain
origin: "on their trusted computer in a trusted folder"
probe:  acquire twice concurrently; the second must refuse
anti:   both callers reporting epoch 1 would be a vacuous pass'

GOOD_BRIEF='# Task
Make acquire safe.

## Acceptance
- AC-1: a second session cannot silently take the writer epoch'

# --- the pass path -----------------------------------------------------------

seed ok "$GOOD_CRIT" "$GOOD_BRIEF"
run_check ok
expect_code 0 "$RC" "criteria that trace to the captain and name a probe must pass"$'\n'"$OUT"
pass "fm-criteria-check: dispatchable criteria pass"

# --- the live failure: findings-sourced criteria, no mandate -----------------
# This is the shape of four consecutive repair briefs. Every criterion was true
# and every one came from the previous round's report; not one traced to
# anything the captain asked for, and nothing refused the dispatch.

seed inherited "${GOOD_CRIT/source: captain/source: execution}" "$GOOD_BRIEF"
run_check inherited
expect_code 1 "$RC" "criteria sourced only to prior findings must be refused"
assert_contains "$OUT" "no criterion traces to the captain" \
  "the refusal must name the missing mandate, not a formatting problem"
pass "fm-criteria-check: refuses work whose criteria trace to no captain instruction"

# --- provenance cannot be faked ---------------------------------------------

seed noorigin '# Ideal state
> a real captain literal

## AC-1
claim:  something is true
source: captain
probe:  run the thing
anti:   a pass that cannot fail' '# Task
- AC-1: something is true'
run_check noorigin
expect_code 1 "$RC" "source: captain without origin: must be refused"
assert_contains "$OUT" "no origin" "the refusal must name the missing quote"
pass "fm-criteria-check: a captain source without the captain's words is refused"

seed badsource "${GOOD_CRIT/source: captain/source: vibes}" "$GOOD_BRIEF"
run_check badsource
expect_code 1 "$RC" "an unrecognized source must be refused"
assert_contains "$OUT" "unrecognized source" "the refusal must name the bad token"
pass "fm-criteria-check: unrecognized provenance is refused"

# --- every criterion names how it is decided --------------------------------

seed noprobe "${GOOD_CRIT/probe:  acquire twice concurrently; the second must refuse/}" "$GOOD_BRIEF"
run_check noprobe
expect_code 1 "$RC" "a criterion with no probe must be refused"
assert_contains "$OUT" "names no probe" "the refusal must name the missing probe"
pass "fm-criteria-check: a criterion that names no probe is refused"

seed noanti "${GOOD_CRIT/anti:   both callers reporting epoch 1 would be a vacuous pass/}" "$GOOD_BRIEF"
run_check noanti
expect_code 1 "$RC" "a criteria set with no anti: line must be refused"
assert_contains "$OUT" "anti:" "the refusal must name the missing anti-claim"
pass "fm-criteria-check: a set that cannot fail is refused"

# --- the brief quotes, it never restates ------------------------------------

seed paraphrased "$GOOD_CRIT" '# Task
## Acceptance
- AC-1: make sure two sessions cannot both hold the epoch'
run_check paraphrased
expect_code 1 "$RC" "a paraphrased criterion must be refused"
assert_contains "$OUT" "verbatim" "the refusal must say the claim was not quoted"
pass "fm-criteria-check: a brief that restates a criterion in new words is refused"

# --- unfilled scaffold slots -------------------------------------------------
# A worker was once launched on a brief whose task section still read {TASK}.
# Only a whole-line occurrence is a slot: the scaffold's own prose mentions the
# token while explaining what to replace, and counting occurrences matched that
# prose too, which is exactly how the empty brief got through.

seed unfilled "$GOOD_CRIT" '# Task
{TASK}

## Acceptance
- AC-1: a second session cannot silently take the writer epoch'
run_check unfilled
expect_code 1 "$RC" "a brief with an unfilled slot must be refused"
assert_contains "$OUT" "unfilled slot" "the refusal must name the slot"
pass "fm-criteria-check: an unfilled brief slot is refused"

seed mentions "$GOOD_CRIT" '# Task
Replace the {TASK} placeholder with real content before dispatch.

## Acceptance
- AC-1: a second session cannot silently take the writer epoch'
run_check mentions
assert_not_contains "$OUT" "unfilled slot" \
  "prose mentioning the token is not an unfilled slot"
pass "fm-criteria-check: prose mentioning a placeholder token is not a slot"

# --- the scaffold cannot satisfy its own check -------------------------------
# Without this the gate would pass on an untouched template, and a gate that
# always passes is theater.

seed scaffold '# Ideal state
> {CAPTAIN_LITERAL}

## AC-1
claim:  {CLAIM}
source: captain
origin: {ORIGIN}
probe:  {PROBE}
anti:   {ANTI}' '# Task
real task text'
run_check scaffold
expect_code 1 "$RC" "an untouched criteria scaffold must be refused"
assert_contains "$OUT" "no captain literal" "the placeholder literal must not count as content"
assert_contains "$OUT" "has no claim" "a placeholder claim must not count as content"
pass "fm-criteria-check: an untouched scaffold is refused on every axis"

# --- missing artifacts -------------------------------------------------------

mkdir -p "$DATA/nocrit"
printf '# Task\nreal\n' >"$DATA/nocrit/brief.md"
run_check nocrit
expect_code 1 "$RC" "a task with no criteria file must be refused"
assert_contains "$OUT" "no criteria at" "the refusal must name the missing artifact"
pass "fm-criteria-check: a task with no criteria artifact is refused"

mkdir -p "$DATA/nobrief"
printf '%s\n' "$GOOD_CRIT" >"$DATA/nobrief/criteria.md"
run_check nobrief
expect_code 1 "$RC" "a task with no brief must be refused"
assert_contains "$OUT" "no brief at" "the refusal must name the missing brief"
pass "fm-criteria-check: a task with no brief is refused"

seed noids '# Ideal state
> a real captain literal' '# Task
real'
run_check noids
expect_code 1 "$RC" "criteria with no AC-N entries must be refused"
assert_contains "$OUT" "no AC-N" "the refusal must say there are no criteria"
pass "fm-criteria-check: criteria with no entries are refused"

# --- every refusal is actionable ---------------------------------------------
# A gate that says no without saying what to do gets worked around.

run_check inherited
assert_contains "$OUT" "repair:" "every refusal must carry a repair line"
assert_contains "$OUT" "REFUSED" "every refusal must state the task is not dispatchable"
pass "fm-criteria-check: refusals carry repair direction"
