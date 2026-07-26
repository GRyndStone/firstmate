#!/usr/bin/env bash
# Unit tests for the usage-burndown optimizer core (bin/fm-usage-burndown-lib.sh).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-usage-burndown-lib.sh
. "$ROOT/bin/fm-usage-burndown-lib.sh"

fm_test_tmproot TMP_ROOT fm-usage-burndown-lib-tests
mkdir -p "$TMP_ROOT"
export FM_USAGE_BURN_HISTORY="$TMP_ROOT/burn-history.json"
export FM_BURNDOWN_PRESSURE_K=4
export FM_BURNDOWN_SPEND_FLOOR=5

obs_scorable() {
  local provider=$1 R=$2 T=$3 W=$4
  jq -cn \
    --arg provider "$provider" \
    --argjson R "$R" \
    --argjson T "$T" \
    --argjson W "$W" \
    '{
      source_id:$provider,
      class:"test-class",
      provider:$provider,
      evidence:"fresh",
      unit:"percent",
      windows:[{id:"w",kind:"session",remaining:$R,resets_at_epoch:0,window_seconds:$W,T:$T}],
      gate_windows:[],
      binding:{id:"w",remaining:$R,T:$T,resets_at_epoch:2000000000,window_seconds:$W},
      binding_reason:"unit fixture budget",
      diagnostics:[]
    }'
}

test_surplus_and_pressure() {
  local near far near_p far_p near_score far_score
  # Clear history so the counterfactual baseline is B=0.
  printf '%s\n' '{"samples":[]}' > "$FM_USAGE_BURN_HISTORY"
  near=$(fm_usage_burndown_score_one "$(obs_scorable claude 100 600 18000)")
  far=$(fm_usage_burndown_score_one "$(obs_scorable claude 100 17000 18000)")
  jq -e '.S == 95 and .scorable == true and .pressure > 1 and .required_rate > 0' \
    <<< "$near" >/dev/null || fail "near-expiry surplus should raise pressure: $near"
  jq -e '.S == 95 and .pressure >= 1 and .required_rate > 0' \
    <<< "$far" >/dev/null || fail "far-from-expiry still scores surplus: $far"
  near_p=$(jq -r '.pressure' <<< "$near")
  far_p=$(jq -r '.pressure' <<< "$far")
  near_score=$(jq -r '.score' <<< "$near")
  far_score=$(jq -r '.score' <<< "$far")
  awk -v n="$near_p" -v f="$far_p" 'BEGIN { exit !(n > f) }' \
    || fail "near-expiry pressure ($near_p) should exceed far ($far_p)"
  awk -v n="$near_score" -v f="$far_score" 'BEGIN { exit !(n > f) }' \
    || fail "near-expiry score ($near_score) should exceed far ($far_score)"
  pass "spendable surplus, required rate, and expiry pressure behave as specified"
}

test_unknown_evidence_not_scorable() {
  local scored
  scored=$(fm_usage_burndown_score_one '{"provider":"gemini","evidence":"unknown","windows":[]}')
  jq -e '.scorable == false and .posture == "unknown" and .score == null' \
    <<< "$scored" >/dev/null || fail "unknown must not fabricate scores: $scored"
  pass "unknown evidence degrades honestly without fabricated numbers"
}

test_history_learns_burn_rate() {
  local obs scored B1 B2
  # Three observations while Claude was not selected: remaining dropped 20 over
  # the first 100s and held steady for the next 100s, so counterfactual B=0.1.
  fm_usage_burn_history_record claude w 80 1000 false 2000000000 18000
  fm_usage_burn_history_record claude w 60 1100 false 2000000000 18000
  fm_usage_burn_history_record claude w 60 1200 false 2000000000 18000
  obs=$(obs_scorable claude 60 5000 18000)
  scored=$(fm_usage_burndown_score_one "$obs")
  B1=$(jq -r '.B' <<< "$scored")
  # 0.1 * 5000 = 500 > spendable R=55 => S=0.
  jq -e '.B_source == "counterfactual-history" and .B > 0.09 and .B < 0.11 and .S == 0' \
    <<< "$scored" >/dev/null || fail "history burn should drive S to 0 when B*T covers R: $scored"
  B2=$(jq -r '.B' <<< "$scored")
  [ "$B1" = "$B2" ] || fail "B should be stable for same history"
  pass "counterfactual burn B is learned only from unselected intervals"
}

test_multi_select_prefers_expiring_surplus() {
  local profiles scored_obs selection
  # Claude has high counterfactual burn, while Codex needs preferential routing
  # to spend a near-expiry budget.
  printf '%s\n' '{"samples":[]}' > "$FM_USAGE_BURN_HISTORY"
  fm_usage_burn_history_record claude w 100 1000 false 2000000000 18000
  fm_usage_burn_history_record claude w 10 1100 false 2000000000 18000

  profiles='[{"provider":"claude","harness":"claude"},{"provider":"codex","harness":"codex"}]'
  scored_obs=$(jq -cn \
    --argjson a "$(fm_usage_burndown_score_one "$(obs_scorable claude 90 5000 18000)")" \
    --argjson b "$(fm_usage_burndown_score_one "$(obs_scorable codex 50 300 18000)")" \
    '[$a,$b]')
  selection=$(fm_usage_burndown_select "$profiles" "$scored_obs" multi)
  jq -e '.profile.provider == "codex" and .frozen == false' \
    <<< "$selection" >/dev/null \
    || fail "should prefer near-expiry surplus over high-R high-burn: $selection"
  assert_contains "$(jq -r '.explain' <<< "$selection")" "highest expiry burn requirement" \
    "explain must name the burndown reason"
  pass "multi-select maximizes the expiry burn requirement"
}

test_freeze_excluded_when_live_exists() {
  local profiles scored_obs selection
  profiles='[{"provider":"claude","harness":"claude"},{"provider":"codex","harness":"codex"}]'
  # Claude at 5% remaining => 95% used => freeze; codex healthy.
  scored_obs=$(jq -cn \
    --argjson a "$(fm_usage_burndown_score_one "$(obs_scorable claude 5 3600 18000)")" \
    --argjson b "$(fm_usage_burndown_score_one "$(obs_scorable codex 70 3600 18000)")" \
    '[$a,$b]')
  selection=$(fm_usage_burndown_select "$profiles" "$scored_obs" multi)
  jq -e '.profile.provider == "codex" and .frozen == false' \
    <<< "$selection" >/dev/null || fail "should skip freeze when live capacity exists: $selection"
  pass "freeze-level sources are skipped when a non-freeze known source exists"
}

test_admit_pin_freezes_in_place() {
  local profiles scored_obs selection
  profiles='[{"provider":"claude","harness":"opencode"},{"provider":"codex","harness":"codex"}]'
  scored_obs=$(jq -cn \
    --argjson a "$(fm_usage_burndown_score_one "$(obs_scorable claude 5 3600 18000)")" \
    --argjson b "$(fm_usage_burndown_score_one "$(obs_scorable codex 70 3600 18000)")" \
    '[$a,$b]')
  selection=$(fm_usage_burndown_select "$profiles" "$scored_obs" admit)
  jq -e '.frozen == true and .provider == "claude"' \
    <<< "$selection" >/dev/null || fail "admit pin must freeze in place: $selection"
  pass "explicit admit pin freezes without substituting an alternate"
}

test_posture_boundaries() {
  local scored
  scored=$(fm_usage_burndown_score_one "$(obs_scorable claude 40.1 3600 18000)")
  jq -e '.posture == "normal"' <<< "$scored" >/dev/null || fail "40.1 remaining => normal: $scored"
  scored=$(fm_usage_burndown_score_one "$(obs_scorable claude 40 3600 18000)")
  jq -e '.posture == "conserve"' <<< "$scored" >/dev/null || fail "40 remaining => conserve: $scored"
  scored=$(fm_usage_burndown_score_one "$(obs_scorable claude 20 3600 18000)")
  jq -e '.posture == "protect"' <<< "$scored" >/dev/null || fail "20 remaining => protect: $scored"
  scored=$(fm_usage_burndown_score_one "$(obs_scorable claude 10 3600 18000)")
  jq -e '.posture == "protect"' <<< "$scored" >/dev/null || fail "10 remaining => protect above floor: $scored"
  scored=$(fm_usage_burndown_score_one "$(obs_scorable claude 5 3600 18000)")
  jq -e '.posture == "freeze"' <<< "$scored" >/dev/null || fail "5 remaining => freeze: $scored"
  pass "observational postures preserve 60/80 bands and freeze at the 5% floor"
}

test_surplus_and_pressure
test_unknown_evidence_not_scorable
test_history_learns_burn_rate
test_multi_select_prefers_expiring_surplus
test_freeze_excluded_when_live_exists
test_admit_pin_freezes_in_place
test_posture_boundaries

echo "# all fm-usage-burndown-lib tests passed"
