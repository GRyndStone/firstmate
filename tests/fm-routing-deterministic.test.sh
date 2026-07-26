#!/usr/bin/env bash
# Frozen-fixture acceptance suite for deterministic self-routing policy.
# Formula: score = ((R - target) / T) * (1 + K*urgency^2) * (1.5^N for codex);
# targets per registry.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-usage-burndown-lib.sh
. "$ROOT/bin/fm-usage-burndown-lib.sh"

fm_test_tmproot TMP_ROOT fm-routing-deterministic-tests
mkdir -p "$TMP_ROOT"
export FM_USAGE_BURN_HISTORY="$TMP_ROOT/burn-history.json"
export FM_DISPATCH_NOW_EPOCH=2000000000

ASSERTIONS=0
FAILURES=0

check_jq() {
  local json=$1 expression=$2 label=$3
  ASSERTIONS=$((ASSERTIONS + 1))
  if jq -e "$expression" <<< "$json" >/dev/null 2>&1; then
    printf 'ok %d - %s\n' "$ASSERTIONS" "$label"
  else
    printf 'not ok %d - %s\n%s\n' "$ASSERTIONS" "$label" "$json" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

check_equal() {
  local actual=$1 expected=$2 label=$3
  ASSERTIONS=$((ASSERTIONS + 1))
  if [ "$actual" = "$expected" ]; then
    printf 'ok %d - %s\n' "$ASSERTIONS" "$label"
  else
    printf 'not ok %d - %s (expected %s, got %s)\n' \
      "$ASSERTIONS" "$label" "$expected" "$actual" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

iso_at_epoch() {
  if date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; then
    return
  fi
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

window_json() {
  local id=$1 kind=$2 remaining=$3 reset_offset=$4 window_seconds=$5
  jq -cn \
    --arg id "$id" \
    --arg kind "$kind" \
    --argjson remaining "$remaining" \
    --arg reset "$(iso_at_epoch $((FM_DISPATCH_NOW_EPOCH + reset_offset)))" \
    --argjson window_seconds "$window_seconds" \
    '{id:$id,kind:$kind,percentRemaining:$remaining,resetsAt:$reset,windowSeconds:$window_seconds}'
}

window_without_length_json() {
  local id=$1 kind=$2 remaining=$3 reset_offset=$4
  jq -cn \
    --arg id "$id" \
    --arg kind "$kind" \
    --argjson remaining "$remaining" \
    --arg reset "$(iso_at_epoch $((FM_DISPATCH_NOW_EPOCH + reset_offset)))" \
    '{id:$id,kind:$kind,percentRemaining:$remaining,resetsAt:$reset}'
}

provider_json() {
  local provider=$1
  shift
  jq -cn \
    --arg provider "$provider" \
    --arg refreshed "$(iso_at_epoch $((FM_DISPATCH_NOW_EPOCH - 60)))" \
    --argjson windows "$(printf '%s\n' "$@" | jq -sc '.')" \
    '{provider:$provider,state:{status:"fresh",refreshedAt:$refreshed},windows:$windows}'
}

quota_json() {
  jq -cn \
    --arg generated "$(iso_at_epoch "$FM_DISPATCH_NOW_EPOCH")" \
    --argjson providers "$(printf '%s\n' "$@" | jq -sc '.')" \
    '{generatedAt:$generated,providers:$providers}'
}

select_from_quota() {
  local profiles=$1 quota=$2 observations scored
  observations=$(fm_usage_source_observe_profiles \
    "$profiles" "$quota" "$FM_DISPATCH_NOW_EPOCH")
  scored=$(fm_usage_burndown_score_all "$observations")
  fm_usage_burndown_select "$profiles" "$scored" multi
}

reset_history() {
  printf '%s\n' '{"samples":[]}' > "$FM_USAGE_BURN_HISTORY"
}

fixture_nearly_exhausted_budget_soon() {
  local profiles claude codex quota selection
  reset_history
  profiles='[{"provider":"claude","harness":"claude"},{"provider":"codex","harness":"codex"}]'
  # Claude above its 10% target with tiny T; codex rich and far.
  # score claude = (15-10)/60 = 5/60 ≈ 0.0833; codex = (95-5)/604800 ≈ 0.000149
  claude=$(provider_json claude \
    "$(window_json five_hour session 100 3600 18000)" \
    "$(window_json seven_day weekly 15 60 604800)")
  codex=$(provider_json codex \
    "$(window_json five_hour session 100 3600 18000)" \
    "$(window_json weekly weekly 95 604800 604800)")
  quota=$(quota_json "$claude" "$codex")
  selection=$(select_from_quota "$profiles" "$quota")
  printf 'fixture=nearly-exhausted-budget-soon %s\n' \
    "$(jq -c '{selected:.profile.provider,candidates:[.candidates[]|{provider,R,T,target_percent,headroom,score_base,score}]}' <<< "$selection")"
  check_jq "$selection" '.profile.provider == "claude" and .frozen == false' \
    "a 15% claude budget resetting in 60s remains selectable and outranks rich far capacity"
  check_jq "$selection" '
    [.candidates[] | select(.provider == "claude")][0]
    | .R == 15 and .T == 60 and .target_percent == 10 and .headroom == 5
      and .score_base > 0.0833 and .score_base < 0.0834
      and .urgency != null
      and .base_pressure > 1
  ' "claude target 10 leaves exactly 5% headroom; near-expiry urgency amplifies"
}

fixture_equal_remaining_different_horizons() {
  local profiles claude codex quota selection
  reset_history
  profiles='[{"provider":"codex","harness":"codex"},{"provider":"claude","harness":"claude"}]'
  claude=$(provider_json claude \
    "$(window_json five_hour session 100 3600 18000)" \
    "$(window_json seven_day weekly 50 3600 604800)")
  codex=$(provider_json codex \
    "$(window_json five_hour session 100 3600 18000)" \
    "$(window_json weekly weekly 50 604800 604800)")
  quota=$(quota_json "$claude" "$codex")
  selection=$(select_from_quota "$profiles" "$quota")
  printf 'fixture=equal-remaining-different-horizons %s\n' \
    "$(jq -c '{selected:.profile.provider,candidates:[.candidates[]|{provider,R,T,target_percent,score_base,score}]}' <<< "$selection")"
  check_jq "$selection" '.profile.provider == "claude"' \
    "equal remaining capacity prefers the budget with less time before reset"
  check_jq "$selection" '
    ([.candidates[] | select(.provider == "claude")][0].score)
    >
    ([.candidates[] | select(.provider == "codex")][0].score)
  ' "score (R-target)/T explains the horizon preference"
}

fixture_routed_burst_is_not_baseline() {
  local profiles claude codex quota selection
  reset_history
  # History that old B*T would have used; captain formula ignores B entirely.
  printf '%s\n' '{"samples":[
    {"provider":"claude","window_id":"seven_day","remaining":100,"at":1999992800,"selected":true,"resets_at_epoch":2000086400},
    {"provider":"claude","window_id":"seven_day","remaining":50,"at":1999996400,"selected":true,"resets_at_epoch":2000086400}
  ]}' > "$FM_USAGE_BURN_HISTORY"
  profiles='[{"provider":"claude","harness":"claude"},{"provider":"codex","harness":"codex"}]'
  claude=$(provider_json claude \
    "$(window_json five_hour session 100 3600 18000)" \
    "$(window_json seven_day weekly 50 86400 604800)")
  codex=$(provider_json codex \
    "$(window_json five_hour session 100 3600 18000)" \
    "$(window_json weekly weekly 50 86400 604800)")
  quota=$(quota_json "$claude" "$codex")
  selection=$(select_from_quota "$profiles" "$quota")
  printf 'fixture=routed-burst-is-not-baseline %s\n' \
    "$(jq -c '{selected:.profile.provider,candidates:[.candidates[]|{provider,B,B_source,headroom,score}]}' <<< "$selection")"
  # Equal T; codex headroom 45 > claude 40 → codex wins on pure target-rate.
  check_jq "$selection" '.profile.provider == "codex"' \
    "with equal T, lower target floor yields higher headroom and wins"
  check_jq "$selection" '
    [.candidates[] | {provider,B,B_source}]
    | all(.B == null and .B_source == "not-used-in-score")
  ' "B is not an input to score under the captain formula"
}

fixture_rate_window_is_gate_only() {
  local profiles claude codex grok quota selection
  reset_history
  profiles='[
    {"provider":"claude","harness":"claude"},
    {"provider":"codex","harness":"codex"},
    {"provider":"grok","harness":"grok"}
  ]'
  claude=$(provider_json claude \
    "$(window_json five_hour session 0 300 18000)" \
    "$(window_json seven_day weekly 90 1000 604800)")
  codex=$(provider_json codex \
    "$(window_json five_hour session 80 10 18000)" \
    "$(window_json weekly weekly 50 1000 604800)")
  grok=$(provider_json grok \
    "$(window_json credits credits 40 1000 604800)")
  quota=$(quota_json "$claude" "$codex" "$grok")
  selection=$(select_from_quota "$profiles" "$quota")
  printf 'fixture=rate-window-is-gate-only %s\n' \
    "$(jq -c '{selected:.profile.provider,candidates:[.candidates[]|{provider,eligible,ineligible_reason,R,T,window_roles}]}' <<< "$selection")"
  check_jq "$selection" '.profile.provider == "codex"' \
    "an exhausted short gate removes one provider without changing budget ranking"
  check_jq "$selection" '
    [.candidates[] | select(.provider == "claude")][0]
    | .eligible == false and .ineligible_reason == "rate-window-exhausted"
  ' "the exhausted rate window is recorded as an eligibility failure"
  check_jq "$selection" '
    [.candidates[] | select(.provider == "codex")][0]
    | .R == 50 and .T == 1000
      and ([.window_roles[] | select(.id == "five_hour")][0].role == "gate")
      and ([.window_roles[] | select(.id == "weekly")][0].role == "budget")
  ' "the short window is classified as a gate and never supplies score inputs"
}

fixture_grok_period_is_observed_not_fabricated() {
  local profiles grok quota selection
  reset_history
  printf '%s\n' '{"samples":[
    {
      "provider":"grok",
      "window_id":"credits",
      "remaining":70,
      "at":1999300000,
      "selected":false,
      "resets_at_epoch":1999474878
    }
  ]}' > "$FM_USAGE_BURN_HISTORY"
  profiles='[{"provider":"grok","harness":"grok"}]'
  grok=$(provider_json grok \
    "$(window_without_length_json credits credits 11 79678)")
  quota=$(quota_json "$grok")
  selection=$(select_from_quota "$profiles" "$quota")
  printf 'fixture=grok-period-is-observed-not-fabricated %s\n' \
    "$(jq -c '{selected:.profile.provider,candidates:[.candidates[]|{provider,R,T,W,W_source,target_percent,headroom,score_base,urgency,score}]}' <<< "$selection")"
  check_jq "$selection" '
    [.candidates[] | select(.provider == "grok")][0]
    | .W == 604800
      and .W_source == "history-reset-period"
      and .urgency > 0.86
      and .urgency < 0.88
      and .target_percent == 5
      and .headroom == 6
  ' "a Grok reset period is learned as weekly and produces high near-reset urgency"
  check_jq "$selection" '
    [.candidates[] | select(.provider == "grok")][0]
    | .W != 86400
      and .B_source == "not-used-in-score"
      and (.score_base - (6/79678) | fabs) < 1e-12
      and (.score - (.score_base * .base_pressure * .reset_pressure_factor) | fabs) < 1e-12
  ' "missing Grok window length never fabricates a 24-hour denominator; score uses retained urgency amp"
}

fixture_above_target_is_selectable() {
  local profiles claude codex quota selection
  reset_history
  profiles='[{"provider":"claude","harness":"claude"},{"provider":"codex","harness":"codex"}]'
  # Claude at 12 > target 10; codex at 6 > target 5. Claude wins on headroom/T.
  claude=$(provider_json claude \
    "$(window_json five_hour session 100 3600 18000)" \
    "$(window_json seven_day weekly 12 3600 604800)")
  codex=$(provider_json codex \
    "$(window_json five_hour session 100 3600 18000)" \
    "$(window_json weekly weekly 6 7200 604800)")
  quota=$(quota_json "$claude" "$codex")
  selection=$(select_from_quota "$profiles" "$quota")
  printf 'fixture=above-target-is-selectable %s\n' \
    "$(jq -c '{selected:.profile.provider,frozen,candidates:[.candidates[]|{provider,posture,R,target_percent,headroom,score}]}' <<< "$selection")"
  check_jq "$selection" '.profile.provider == "claude" and .frozen == false' \
    "claude above its 10% target remains eligible for routing"
  check_jq "$selection" '
    [.candidates[] | select(.provider == "claude")][0]
    | .target_percent == 10 and .headroom == 2 and .posture != "freeze"
  ' "claude target 10 yields headroom 2 at R=12"
  check_jq "$selection" '
    [.candidates[] | select(.provider == "codex")][0]
    | .target_percent == 5 and .headroom == 1 and .posture != "freeze"
  ' "codex target 5 yields headroom 1 at R=6"
}

fixture_unavailable_evidence_refuses_loudly() {
  local quota profiles output status err
  reset_history
  quota="$TMP_ROOT/unavailable.json"
  printf '%s\n' '{"providers":"unusable"}' > "$quota"
  profiles='[
    {"provider":"claude","harness":"claude"},
    {"provider":"codex","harness":"codex"}
  ]'
  status=0
  output=$("$ROOT/bin/fm-dispatch-select.sh" \
    --select usage-burndown --quota-json "$quota" "$profiles" 2>"$TMP_ROOT/unavailable.err") || status=$?
  err=$(cat "$TMP_ROOT/unavailable.err")
  printf 'fixture=unavailable-evidence-refuses-loudly status=%s %s\n' \
    "$status" \
    "$(jq -c '{selected:.provider,dispatch_error,unreadable_providers}' <<< "$output" 2>/dev/null || true)"
  check_equal "$status" 70 \
    "unusable meter evidence refuses with exit 70 rather than silently dispatching"
  check_jq "$output" '
    .dispatch_error == "usage-evidence-unreadable"
  ' "unusable evidence is machine-marked as usage-evidence-unreadable"
  ASSERTIONS=$((ASSERTIONS + 1))
  if printf '%s\n' "$err" | grep -q "error:"; then
    printf 'ok %d - %s\n' "$ASSERTIONS" "unusable evidence prints an error line on stderr"
  else
    printf 'not ok %d - %s\n%s\n' "$ASSERTIONS" \
      "unusable evidence prints an error line on stderr" "$err" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

fixture_total_tie_is_stable() {
  local profiles codex_a quota selection providers run
  reset_history
  # Same provider twice with identical R/T so score, headroom, R, and T all match;
  # only profile index differs. Two different providers cannot fully tie under
  # per-provider targets (equal headroom forces unequal R, and R-desc decides first).
  profiles='[{"provider":"codex","harness":"codex","model":"a"},{"provider":"codex","harness":"codex","model":"b"}]'
  codex_a=$(provider_json codex \
    "$(window_json five_hour session 100 3600 18000)" \
    "$(window_json weekly weekly 50 86400 604800)")
  # observe_profiles dedupes by provider, so both profiles share one observation.
  quota=$(quota_json "$codex_a")
  providers=
  selection=
  run=0
  while [ "$run" -lt 25 ]; do
    selection=$(select_from_quota "$profiles" "$quota")
    providers="${providers}$(jq -r '.profile.model // .profile.provider' <<< "$selection")"$'\n'
    run=$((run + 1))
  done
  printf 'fixture=total-tie-is-stable %s\n' \
    "$(jq -c '{selected:.profile,tie_break:.profile.dispatch_tie_break,candidates:[.candidates[]|{provider,index,model:.profile.model,target_percent,headroom,score}]}' <<< "$selection")"
  check_equal "$(printf '%s' "$providers" | sort -u)" a \
    "an exact score/headroom/R/T tie resolves to the same first-index profile across 25 runs"
  check_jq "$selection" '.profile.dispatch_tie_break == "profile-order" and .profile.model == "a"' \
    "the total tie-break is machine-recorded as profile-order"
}

fixture_nearly_exhausted_budget_soon
fixture_equal_remaining_different_horizons
fixture_routed_burst_is_not_baseline
fixture_rate_window_is_gate_only
fixture_grok_period_is_observed_not_fabricated
fixture_above_target_is_selectable
fixture_unavailable_evidence_refuses_loudly
fixture_total_tie_is_stable

printf '# assertions=%d failures=%d\n' "$ASSERTIONS" "$FAILURES"
[ "$FAILURES" -eq 0 ]
