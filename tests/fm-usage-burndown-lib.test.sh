#!/usr/bin/env bash
# Unit tests for the usage-burndown optimizer core (bin/fm-usage-burndown-lib.sh).
# Formula under test: score = (R - target) / T * (1.5^N for codex only).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-usage-burndown-lib.sh
. "$ROOT/bin/fm-usage-burndown-lib.sh"

fm_test_tmproot TMP_ROOT fm-usage-burndown-lib-tests
mkdir -p "$TMP_ROOT"
export FM_USAGE_BURN_HISTORY="$TMP_ROOT/burn-history.json"

obs_scorable() {
  local provider=$1 R=$2 T=$3 W=$4
  local resets=${5:-0}
  local target
  target=$(fm_usage_source_target_percent "$provider" 2>/dev/null) \
    || target=${FM_BURNDOWN_DEFAULT_TARGET:-5}
  jq -cn \
    --arg provider "$provider" \
    --argjson R "$R" \
    --argjson T "$T" \
    --argjson W "$W" \
    --argjson resets "$resets" \
    --argjson target "$target" \
    '{
      source_id:$provider,
      class:"test-class",
      provider:$provider,
      evidence:"fresh",
      unit:"percent",
      target_percent:$target,
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

test_target_rate_score_formula() {
  local near far near_score far_score near_base far_base
  printf '%s\n' '{"samples":[]}' > "$FM_USAGE_BURN_HISTORY"
  # Claude target=10: R=100 => headroom=90. Near T=600 vs far T=17000.
  near=$(fm_usage_burndown_score_one "$(obs_scorable claude 100 600 18000)")
  far=$(fm_usage_burndown_score_one "$(obs_scorable claude 100 17000 18000)")
  jq -e '
    .target_percent == 10
    and .headroom == 90
    and .scorable == true
    and .urgency == null
    and .B_source == "not-used-in-score"
    and (.score_base - 0.15 | fabs) < 0.0001
  ' <<< "$near" >/dev/null || fail "near-expiry target-rate score inputs wrong: $near"
  jq -e '
    .target_percent == 10
    and .headroom == 90
    and .urgency == null
    and (.score_base - (90/17000) | fabs) < 1e-9
  ' <<< "$far" >/dev/null || fail "far-from-expiry still scores headroom/T: $far"
  near_score=$(jq -r '.score' <<< "$near")
  far_score=$(jq -r '.score' <<< "$far")
  awk -v n="$near_score" -v f="$far_score" 'BEGIN { exit !(n > f) }' \
    || fail "near-expiry score ($near_score) should exceed far ($far_score)"
  # Hand-check: score equals score_base when not codex.
  near_base=$(jq -r '.score_base' <<< "$near")
  far_base=$(jq -r '.score_base' <<< "$far")
  awk -v s="$near_score" -v b="$near_base" 'BEGIN { exit !(s == b) }' \
    || fail "non-codex score must equal score_base: near score=$near_score base=$near_base"
  awk -v s="$far_score" -v b="$far_base" 'BEGIN { exit !(s == b) }' \
    || fail "non-codex score must equal score_base: far score=$far_score base=$far_base"
  pass "score is exactly (R-target)/T with urgency amplifier and B*T gone"
}

test_per_provider_targets_are_distinct() {
  local claude_scored codex_scored grok_scored
  printf '%s\n' '{"samples":[]}' > "$FM_USAGE_BURN_HISTORY"
  claude_scored=$(fm_usage_burndown_score_one "$(obs_scorable claude 50 3600 18000)")
  codex_scored=$(fm_usage_burndown_score_one "$(obs_scorable codex 50 3600 18000 0)")
  grok_scored=$(fm_usage_burndown_score_one "$(obs_scorable grok 50 3600 18000)")
  jq -e '.target_percent == 10 and .headroom == 40' <<< "$claude_scored" >/dev/null \
    || fail "claude must use registry target 10: $claude_scored"
  jq -e '.target_percent == 5 and .headroom == 45' <<< "$codex_scored" >/dev/null \
    || fail "codex must use registry target 5: $codex_scored"
  jq -e '.target_percent == 5 and .headroom == 45' <<< "$grok_scored" >/dev/null \
    || fail "grok must use registry target 5: $grok_scored"
  # Same R/T: codex headroom 45 > claude headroom 40, so codex score_base wins.
  awk -v c="$(jq -r '.score' <<< "$claude_scored")" \
      -v x="$(jq -r '.score' <<< "$codex_scored")" \
    'BEGIN { exit !(x > c) }' \
    || fail "with equal R/T, codex target 5 must outscore claude target 10"
  # Registry declares distinct targets; a shared constant would fail this.
  [ "$(fm_usage_source_target_percent claude)" = 10 ] \
    || fail "registry target for claude must be 10"
  [ "$(fm_usage_source_target_percent codex)" = 5 ] \
    || fail "registry target for codex must be 5"
  [ "$(fm_usage_source_target_percent grok)" = 5 ] \
    || fail "registry target for grok must be 5"
  pass "per-provider targets are registry data and feed scoring (claude 10, others 5)"
}

test_unknown_evidence_not_scorable() {
  local scored
  scored=$(fm_usage_burndown_score_one '{"provider":"gemini","evidence":"unknown","windows":[],"target_percent":5}')
  jq -e '.scorable == false and .posture == "unknown" and .score == null' \
    <<< "$scored" >/dev/null || fail "unknown must not fabricate scores: $scored"
  pass "unknown evidence degrades honestly without fabricated numbers"
}

test_history_does_not_reduce_score() {
  local obs scored expected
  # Three unselected samples that would have driven old B*T to cover headroom.
  fm_usage_burn_history_record claude w 80 1000 false 2000000000 18000
  fm_usage_burn_history_record claude w 60 1100 false 2000000000 18000
  fm_usage_burn_history_record claude w 60 1200 false 2000000000 18000
  obs=$(obs_scorable claude 60 5000 18000)
  scored=$(fm_usage_burndown_score_one "$obs")
  # New formula: headroom = 60-10 = 50; score = 50/5000 = 0.01. B must not zero it.
  expected=0.01
  jq -e --argjson expected "$expected" '
    .headroom == 50
    and .B_source == "not-used-in-score"
    and .B == null
    and (.score - $expected | fabs) < 1e-12
    and .urgency == null
  ' <<< "$scored" >/dev/null \
    || fail "burn history must not subtract from score under captain formula: $scored"
  pass "observational burn history never reduces the captain score"
}

test_multi_select_prefers_expiring_headroom() {
  local profiles scored_obs selection
  printf '%s\n' '{"samples":[]}' > "$FM_USAGE_BURN_HISTORY"
  # Claude: (90-10)/5000 = 0.016; Codex: (50-5)/300 ≈ 0.15 → codex wins.
  profiles='[{"provider":"claude","harness":"claude"},{"provider":"codex","harness":"codex"}]'
  scored_obs=$(jq -cn \
    --argjson a "$(fm_usage_burndown_score_one "$(obs_scorable claude 90 5000 18000)")" \
    --argjson b "$(fm_usage_burndown_score_one "$(obs_scorable codex 50 300 18000)")" \
    '[$a,$b]')
  selection=$(fm_usage_burndown_select "$profiles" "$scored_obs" multi)
  jq -e '.profile.provider == "codex" and .frozen == false' \
    <<< "$selection" >/dev/null \
    || fail "should prefer near-expiry headroom: $selection"
  assert_contains "$(jq -r '.explain' <<< "$selection")" "highest target-rate score" \
    "explain must name the target-rate reason"
  assert_contains "$(jq -r '.explain' <<< "$selection")" "(R-target)/T" \
    "explain must state the captain formula"
  pass "multi-select maximizes the captain target-rate score"
}

test_freeze_excluded_when_live_exists() {
  local profiles scored_obs selection
  profiles='[{"provider":"claude","harness":"claude"},{"provider":"codex","harness":"codex"}]'
  # Claude at 5% remaining is below claude target 10 => freeze; codex healthy.
  scored_obs=$(jq -cn \
    --argjson a "$(fm_usage_burndown_score_one "$(obs_scorable claude 5 3600 18000)")" \
    --argjson b "$(fm_usage_burndown_score_one "$(obs_scorable codex 70 3600 18000)")" \
    '[$a,$b]')
  selection=$(fm_usage_burndown_select "$profiles" "$scored_obs" multi)
  jq -e '.profile.provider == "codex" and .frozen == false' \
    <<< "$selection" >/dev/null || fail "should skip freeze when live capacity exists: $selection"
  pass "freeze-level sources are skipped when a non-freeze known source exists"
}

test_at_or_below_target_is_excluded() {
  local profiles scored_obs selection
  profiles='[{"provider":"claude","harness":"claude"},{"provider":"codex","harness":"codex"}]'
  # Claude exactly at target 10 is freeze, not merely ranked last with a low score.
  scored_obs=$(jq -cn \
    --argjson a "$(fm_usage_burndown_score_one "$(obs_scorable claude 10 3600 18000)")" \
    --argjson b "$(fm_usage_burndown_score_one "$(obs_scorable codex 20 3600 18000)")" \
    '[$a,$b]')
  selection=$(fm_usage_burndown_select "$profiles" "$scored_obs" multi)
  jq -e '
    .profile.provider == "codex"
    and ([.candidates[] | select(.provider == "claude")][0].posture == "freeze")
    and ([.candidates[] | select(.provider == "claude")][0].score == 0)
  ' <<< "$selection" >/dev/null \
    || fail "at-target provider must freeze and be excluded: $selection"
  pass "provider at or below its target is excluded rather than ranked last"
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
  assert_contains "$(jq -r '.explain' <<< "$selection")" "target floor 10" \
    "admit freeze must name claude's 10% target"
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
  # Claude target is 10: at 10.1 still above freeze; at 10 freezes.
  scored=$(fm_usage_burndown_score_one "$(obs_scorable claude 10.1 3600 18000)")
  jq -e '.posture == "protect" and .target_percent == 10' <<< "$scored" >/dev/null \
    || fail "10.1 remaining for claude => protect above target 10: $scored"
  scored=$(fm_usage_burndown_score_one "$(obs_scorable claude 10 3600 18000)")
  jq -e '.posture == "freeze"' <<< "$scored" >/dev/null \
    || fail "10 remaining for claude => freeze at target: $scored"
  # Codex freezes at its own 5% target, not claude's 10.
  scored=$(fm_usage_burndown_score_one "$(obs_scorable codex 7 3600 18000 0)")
  jq -e '.posture != "freeze" and .target_percent == 5 and .headroom == 2' \
    <<< "$scored" >/dev/null \
    || fail "codex at 7 must stay live under target 5: $scored"
  scored=$(fm_usage_burndown_score_one "$(obs_scorable codex 5 3600 18000 0)")
  jq -e '.posture == "freeze"' <<< "$scored" >/dev/null \
    || fail "codex at 5 => freeze at its target: $scored"
  pass "postures preserve 60/80 bands and freeze at each provider's target"
}

test_codex_reset_multiplier_compounds() {
  local n0 n1 n2 n3 p0 p1 p2 p3 f0 f1 f2 f3 claude_p s0 s1 s2 s3
  printf '%s\n' '{"samples":[]}' > "$FM_USAGE_BURN_HISTORY"
  # Identical R/T so score_base matches; only N varies.
  n0=$(fm_usage_burndown_score_one "$(obs_scorable codex 80 3600 18000 0)")
  n1=$(fm_usage_burndown_score_one "$(obs_scorable codex 80 3600 18000 1)")
  n2=$(fm_usage_burndown_score_one "$(obs_scorable codex 80 3600 18000 2)")
  n3=$(fm_usage_burndown_score_one "$(obs_scorable codex 80 3600 18000 3)")
  f0=$(jq -r '.reset_pressure_factor' <<< "$n0")
  f1=$(jq -r '.reset_pressure_factor' <<< "$n1")
  f2=$(jq -r '.reset_pressure_factor' <<< "$n2")
  f3=$(jq -r '.reset_pressure_factor' <<< "$n3")
  s0=$(jq -r '.score' <<< "$n0")
  s1=$(jq -r '.score' <<< "$n1")
  s2=$(jq -r '.score' <<< "$n2")
  s3=$(jq -r '.score' <<< "$n3")
  awk -v f="$f0" 'BEGIN { exit !(f == 1) }' || fail "N=0 factor must be 1: $n0"
  awk -v f="$f1" 'BEGIN { exit !(f == 1.5) }' || fail "N=1 factor must be 1.5: $n1"
  awk -v f="$f2" 'BEGIN { exit !(f == 2.25) }' || fail "N=2 factor must be 2.25: $n2"
  awk -v f="$f3" 'BEGIN { exit !(f == 3.375) }' || fail "N=3 factor must be 3.375: $n3"
  # score_base = (80-5)/3600; score = score_base * factor
  awk -v s="$s0" -v b="$(jq -r '.score_base' <<< "$n0")" 'BEGIN { exit !(s == b) }' \
    || fail "N=0 score must equal score_base"
  awk -v a="$s0" -v b="$s1" 'BEGIN { exit !(b > a) }' || fail "N=1 score must exceed N=0"
  awk -v a="$s1" -v b="$s2" 'BEGIN { exit !(b > a) }' || fail "N=2 score must exceed N=1"
  awk -v a="$s2" -v b="$s3" 'BEGIN { exit !(b > a) }' || fail "N=3 score must exceed N=2"
  awk -v s="$s1" -v b="$(jq -r '.score_base' <<< "$n1")" \
    'BEGIN { exit !((s - b*1.5)^2 < 1e-18) }' \
    || fail "N=1 score must be score_base * 1.5"
  jq -e '.pressure_source | test("codex-reset")' <<< "$n1" >/dev/null \
    || fail "pressure_source must surface the codex reset factor: $n1"
  # Claude with the same R/T must not gain a reset factor.
  claude_p=$(fm_usage_burndown_score_one "$(obs_scorable claude 80 3600 18000)")
  jq -e '.reset_pressure_factor == 1 and .reset_available_count == null' \
    <<< "$claude_p" >/dev/null \
    || fail "non-codex provider must not take the reset multiplier: $claude_p"
  # Hand-check claude score is (80-10)/3600 only — multiplier never applied.
  awk -v s="$(jq -r '.score' <<< "$claude_p")" \
    'BEGIN { exit !((s - (70/3600))^2 < 1e-18) }' \
    || fail "claude score must be pure (R-target)/T without reset multiplier"
  pass "codex reset multiplies score as 1.5^N and leaves other providers alone"
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
  # Score under unreadable equals score_base (neutral 1), not fabricated N=0 silence without flag.
  awk -v s="$(jq -r '.score' <<< "$scored")" \
      -v b="$(jq -r '.score_base' <<< "$scored")" \
    'BEGIN { exit !(s == b) }' \
    || fail "unreadable reset must use factor 1 (score == score_base), not invent N"
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
  local profiles scored_obs selection claude_score codex_score
  printf '%s\n' '{"samples":[]}' > "$FM_USAGE_BURN_HISTORY"
  # Claude: (90-10)/3600 = 80/3600; Codex: (60-5)/3600 * 2.25 = 123.75/3600 → codex.
  profiles='[{"provider":"claude","harness":"claude"},{"provider":"codex","harness":"codex"}]'
  scored_obs=$(jq -cn \
    --argjson a "$(fm_usage_burndown_score_one "$(obs_scorable claude 90 3600 18000)")" \
    --argjson b "$(fm_usage_burndown_score_one "$(obs_scorable codex 60 3600 18000 2)")" \
    '[$a,$b]')
  selection=$(fm_usage_burndown_select "$profiles" "$scored_obs" multi)
  jq -e '.profile.provider == "codex"' <<< "$selection" >/dev/null \
    || fail "codex with reset factor should outrank higher-headroom claude: $selection"
  assert_contains "$(jq -r '.explain' <<< "$selection")" "reset_factor=" \
    "selection explain must surface the reset factor"
  claude_score=$(jq -r '[.candidates[] | select(.provider=="claude")][0].score' <<< "$selection")
  codex_score=$(jq -r '[.candidates[] | select(.provider=="codex")][0].score' <<< "$selection")
  awk -v c="$claude_score" -v x="$codex_score" 'BEGIN { exit !(x > c) }' \
    || fail "codex score $codex_score must exceed claude $claude_score"
  pass "codex reset factor can change a headroom-based ranking"
}

test_highest_score_is_selected_deterministically() {
  local profiles scored_obs selection
  printf '%s\n' '{"samples":[]}' > "$FM_USAGE_BURN_HISTORY"
  profiles='[{"provider":"claude","harness":"claude"},{"provider":"codex","harness":"codex"},{"provider":"grok","harness":"grok"}]'
  # Scores: claude (50-10)/1000=0.04; codex (50-5)/1000=0.045; grok (80-5)/1000=0.075 → grok.
  scored_obs=$(jq -cn \
    --argjson a "$(fm_usage_burndown_score_one "$(obs_scorable claude 50 1000 18000)")" \
    --argjson b "$(fm_usage_burndown_score_one "$(obs_scorable codex 50 1000 18000 0)")" \
    --argjson c "$(fm_usage_burndown_score_one "$(obs_scorable grok 80 1000 18000)")" \
    '[$a,$b,$c]')
  selection=$(fm_usage_burndown_select "$profiles" "$scored_obs" multi)
  jq -e '.profile.provider == "grok" and .frozen == false' <<< "$selection" >/dev/null \
    || fail "engine must pick the max score with no human judgment: $selection"
  pass "highest score is the routing target chosen by the engine"
}

test_target_rate_score_formula
test_per_provider_targets_are_distinct
test_unknown_evidence_not_scorable
test_history_does_not_reduce_score
test_multi_select_prefers_expiring_headroom
test_freeze_excluded_when_live_exists
test_at_or_below_target_is_excluded
test_admit_pin_freezes_in_place
test_posture_boundaries
test_codex_reset_multiplier_compounds
test_codex_unreadable_reset_is_loud_error
test_codex_resets_can_outrank_more_headroom
test_highest_score_is_selected_deterministically

echo "# all fm-usage-burndown-lib tests passed"
