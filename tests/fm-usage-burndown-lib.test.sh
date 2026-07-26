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
  local resets=${5:-0}
  jq -cn \
    --arg provider "$provider" \
    --argjson R "$R" \
    --argjson T "$T" \
    --argjson W "$W" \
    --argjson resets "$resets" \
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
    }
    + (
        if $provider == "codex" then
          {
            rate_limit_reset_credits:{
              evidence:"fresh",
              available_count:$resets,
              source:"fixture",
              error:null,
              all_expired:false,
              items:[]
            }
          }
        else {}
        end
      )'
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

test_codex_reset_pressure_compounds() {
  local n0 n1 n2 n3 p0 p1 p2 p3 f0 f1 f2 f3 claude_p
  printf '%s\n' '{"samples":[]}' > "$FM_USAGE_BURN_HISTORY"
  # Identical R/T/W so base pressure matches; only N varies.
  n0=$(fm_usage_burndown_score_one "$(obs_scorable codex 80 3600 18000 0)")
  n1=$(fm_usage_burndown_score_one "$(obs_scorable codex 80 3600 18000 1)")
  n2=$(fm_usage_burndown_score_one "$(obs_scorable codex 80 3600 18000 2)")
  n3=$(fm_usage_burndown_score_one "$(obs_scorable codex 80 3600 18000 3)")
  f0=$(jq -r '.reset_pressure_factor' <<< "$n0")
  f1=$(jq -r '.reset_pressure_factor' <<< "$n1")
  f2=$(jq -r '.reset_pressure_factor' <<< "$n2")
  f3=$(jq -r '.reset_pressure_factor' <<< "$n3")
  p0=$(jq -r '.pressure' <<< "$n0")
  p1=$(jq -r '.pressure' <<< "$n1")
  p2=$(jq -r '.pressure' <<< "$n2")
  p3=$(jq -r '.pressure' <<< "$n3")
  awk -v f="$f0" 'BEGIN { exit !(f == 1) }' || fail "N=0 factor must be 1: $n0"
  awk -v f="$f1" 'BEGIN { exit !(f == 1.5) }' || fail "N=1 factor must be 1.5: $n1"
  awk -v f="$f2" 'BEGIN { exit !(f == 2.25) }' || fail "N=2 factor must be 2.25: $n2"
  awk -v f="$f3" 'BEGIN { exit !(f == 3.375) }' || fail "N=3 factor must be 3.375: $n3"
  awk -v a="$p0" -v b="$p1" 'BEGIN { exit !(b > a) }' || fail "N=1 pressure must exceed N=0"
  awk -v a="$p1" -v b="$p2" 'BEGIN { exit !(b > a) }' || fail "N=2 pressure must exceed N=1"
  awk -v a="$p2" -v b="$p3" 'BEGIN { exit !(b > a) }' || fail "N=3 pressure must exceed N=2"
  jq -e '.pressure_source | test("codex-reset")' <<< "$n1" >/dev/null \
    || fail "pressure_source must surface the codex reset factor: $n1"
  # Claude with the same R/T/W must not gain a reset factor.
  claude_p=$(fm_usage_burndown_score_one "$(obs_scorable claude 80 3600 18000)")
  jq -e '.reset_pressure_factor == 1 and .reset_available_count == null' \
    <<< "$claude_p" >/dev/null \
    || fail "non-codex provider must not take the reset multiplier: $claude_p"
  # Equal base pressure for claude vs codex N=0.
  awk -v c="$(jq -r '.pressure' <<< "$claude_p")" -v x="$p0" \
    'BEGIN { exit !(c == x) }' \
    || fail "claude pressure must match codex N=0 pressure"
  pass "codex reset pressure compounds as 1.5^N and leaves other providers alone"
}

test_codex_unreadable_reset_is_loud_error() {
  local bad zero scored
  bad=$(jq -cn \
    --argjson base "$(obs_scorable codex 80 3600 18000 0)" \
    '$base + {
      rate_limit_reset_credits:{
        evidence:"unreadable",
        available_count:null,
        source:"available-count-unreadable",
        error:"availableCount is not a non-negative integer (got string)",
        items:[]
      }
    }')
  scored=$(fm_usage_burndown_score_one "$bad")
  # Windows remain scorable with neutral factor 1; unreadable is never a silent zero.
  jq -e '
    .scorable == true
    and .reset_count_unreadable == true
    and .reset_available_count == null
    and .reset_pressure_factor == 1
    and (.pressure_source | test("codex-reset-unreadable"))
    and (.score | type) == "number"
  ' <<< "$scored" >/dev/null \
    || fail "unreadable reset must keep windows scorable with neutral factor: $scored"
  jq -e '
    (.diagnostics // [])
    | map(tostring)
    | any(test("unreadable"; "i"))
  ' <<< "$scored" >/dev/null \
    || fail "unreadable path must name the cause in diagnostics: $scored"
  # Genuine zero is not an error and is distinct from unreadable.
  zero=$(fm_usage_burndown_score_one "$(obs_scorable codex 80 3600 18000 0)")
  jq -e '
    .scorable == true
    and .reset_available_count == 0
    and .reset_pressure_factor == 1
    and (.reset_count_unreadable != true)
    and (.pressure_source | test("codex-reset-1"))
  ' <<< "$zero" >/dev/null \
    || fail "genuine zero resets must remain scorable with factor 1 and not look unreadable: $zero"
  pass "unreadable codex reset is a loud named error with neutral factor; genuine zero is not"
}

test_codex_resets_can_outrank_more_headroom() {
  local profiles scored_obs selection
  printf '%s\n' '{"samples":[]}' > "$FM_USAGE_BURN_HISTORY"
  # Claude has more remaining budget and the same clock; codex has N=2 resets.
  profiles='[{"provider":"claude","harness":"claude"},{"provider":"codex","harness":"codex"}]'
  scored_obs=$(jq -cn \
    --argjson a "$(fm_usage_burndown_score_one "$(obs_scorable claude 90 3600 18000)")" \
    --argjson b "$(fm_usage_burndown_score_one "$(obs_scorable codex 60 3600 18000 2)")" \
    '[$a,$b]')
  selection=$(fm_usage_burndown_select "$profiles" "$scored_obs" multi)
  jq -e '.profile.provider == "codex"' <<< "$selection" >/dev/null \
    || fail "codex with reset pressure should outrank higher-R claude: $selection"
  assert_contains "$(jq -r '.explain' <<< "$selection")" "reset_factor=" \
    "selection explain must surface the reset factor"
  pass "codex reset factor can change a headroom-based ranking"
}

test_surplus_and_pressure
test_unknown_evidence_not_scorable
test_history_learns_burn_rate
test_multi_select_prefers_expiring_surplus
test_freeze_excluded_when_live_exists
test_admit_pin_freezes_in_place
test_posture_boundaries
test_codex_reset_pressure_compounds
test_codex_unreadable_reset_is_loud_error
test_codex_resets_can_outrank_more_headroom

echo "# all fm-usage-burndown-lib tests passed"
