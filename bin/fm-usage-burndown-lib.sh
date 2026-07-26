#!/usr/bin/env bash
# Usage-burndown optimizer core for crew dispatch selection.
#
# Only a provider's durable budget window is scored. Short rate windows are
# eligibility gates and never contribute R, T, or score.
#
# Captain formula (2026-07-26, amended to keep near-expiry amplifier):
#   score_base = (remaining_usage_percent - target_percent) / remaining_time
#   urgency = clamp(1 - T/W, 0, 1) when W is known
#   base_pressure = 1 + K*urgency^2 when headroom > 0 and W known, else 1
#   for provider=codex only:
#     reset_factor = C^N where N = available rate-limit reset credits
#     (C defaults to 1.5; compounding). Other providers use factor 1.
#   score = score_base * base_pressure * reset_factor
#
# Per-provider target floors live in bin/fm-usage-source-lib.sh's registry
# (default 5 for known providers, 10 for claude). Freeze begins when R is at
# or below that provider's target; those candidates are excluded when any live
# candidate remains. Highest score wins.
#
# Removed from the score path (do not reintroduce):
#   - B*T burn-rate subtraction
#
# Retained exactly as today: the squared-urgency near-expiry amplifier
# (1 + K*urgency^2, K defaults to 4). W is resolved from the meter or reset
# history for that amplifier; when W is missing, pressure stays neutral at 1.
#
# Burn-history recording still exists so later analysis can inspect non-selected
# intervals, but B never multiplies or subtracts on the score path.
#
# Codex N is a real observation of rateLimitResetCredits; unreadable N is an
# error with neutral factor 1, never a silent zero. Full rationale:
# docs/usage-burndown-dispatch.md.
#
# Sourced only; not executed as a main program.

_FM_USAGE_BURNDOWN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_USAGE_BURNDOWN_LIB_DIR="."

# shellcheck source=bin/fm-usage-source-lib.sh
. "$_FM_USAGE_BURNDOWN_LIB_DIR/fm-usage-source-lib.sh"

FM_BURNDOWN_HISTORY_MAX=${FM_BURNDOWN_HISTORY_MAX:-200}
FM_BURNDOWN_RATE_FLOOR=${FM_BURNDOWN_RATE_FLOOR:-0}
# Squared-urgency near-expiry amplifier coefficient (retained from prior engine).
FM_BURNDOWN_PRESSURE_K=${FM_BURNDOWN_PRESSURE_K:-4}
# Compounding per-available-reset multiplier for provider=codex only.
FM_BURNDOWN_CODEX_RESET_PRESSURE_FACTOR=${FM_BURNDOWN_CODEX_RESET_PRESSURE_FACTOR:-1.5}
# Fallback only when an observation lacks target_percent (unit fixtures, etc.).
# Live observations always carry the registry value from fm-usage-source-lib.
FM_BURNDOWN_DEFAULT_TARGET=${FM_BURNDOWN_DEFAULT_TARGET:-5}

fm_usage_burndown_numeric_or_default() { # <value> <default> <min> <max>
  local value=$1 fallback=$2 minimum=$3 maximum=$4
  if awk -v value="$value" -v minimum="$minimum" -v maximum="$maximum" '
    BEGIN {
      ok = value ~ /^[0-9]+([.][0-9]+)?$/ && value + 0 >= minimum && value + 0 <= maximum
      exit !ok
    }
  '; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

FM_BURNDOWN_HISTORY_MAX=$(fm_usage_burndown_numeric_or_default "$FM_BURNDOWN_HISTORY_MAX" 200 1 10000)
FM_BURNDOWN_RATE_FLOOR=$(fm_usage_burndown_numeric_or_default "$FM_BURNDOWN_RATE_FLOOR" 0 0 100)
FM_BURNDOWN_PRESSURE_K=$(fm_usage_burndown_numeric_or_default "$FM_BURNDOWN_PRESSURE_K" 4 0 100)
FM_BURNDOWN_CODEX_RESET_PRESSURE_FACTOR=$(fm_usage_burndown_numeric_or_default \
  "$FM_BURNDOWN_CODEX_RESET_PRESSURE_FACTOR" 1.5 1 10)
FM_BURNDOWN_DEFAULT_TARGET=$(fm_usage_burndown_numeric_or_default \
  "$FM_BURNDOWN_DEFAULT_TARGET" 5 0 100)

fm_usage_burn_history_path() {
  if [ -n "${FM_USAGE_BURN_HISTORY:-}" ]; then
    printf '%s\n' "$FM_USAGE_BURN_HISTORY"
    return 0
  fi
  if [ -n "${FM_HOME:-}" ]; then
    printf '%s\n' "$FM_HOME/data/usage-burn-history.json"
    return 0
  fi
  printf '%s\n' ""
}

fm_usage_burn_history_load() {
  local path
  path=$(fm_usage_burn_history_path)
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    printf '%s\n' '[]'
    return 0
  fi
  jq -ec 'if type == "object" and (.samples | type) == "array" then .samples
          elif type == "array" then .
          else [] end' "$path" 2>/dev/null || printf '%s\n' '[]'
}

# Append one observed budget-window sample (observational history only; never
# used as a score input).
# Args: provider window_id remaining at selected reset_epoch window_seconds
# selected is true only when this decision routed a new task to the provider.
fm_usage_burn_history_record() {
  local provider=$1 window_id=$2 remaining=$3 at_epoch=$4
  local selected=${5:-false} reset_epoch=${6:-null} window_seconds=${7:-null}
  local path dir next samples
  case "$selected" in true|false) ;; *) selected=false ;; esac
  [ -n "$reset_epoch" ] || reset_epoch=null
  [ -n "$window_seconds" ] || window_seconds=null
  path=$(fm_usage_burn_history_path)
  [ -n "$path" ] || return 0
  dir=$(dirname "$path")
  mkdir -p "$dir" 2>/dev/null || return 0
  samples=$(fm_usage_burn_history_load)
  next=$(jq -cn \
    --argjson samples "$samples" \
    --arg provider "$provider" \
    --arg window_id "$window_id" \
    --argjson remaining "$remaining" \
    --argjson at "$at_epoch" \
    --argjson selected "$selected" \
    --argjson reset_epoch "$reset_epoch" \
    --argjson window_seconds "$window_seconds" \
    --argjson max "$FM_BURNDOWN_HISTORY_MAX" '
    ($samples + [{
      provider:$provider,
      window_id:$window_id,
      remaining:$remaining,
      at:$at,
      selected:$selected,
      resets_at_epoch:$reset_epoch,
      window_seconds:$window_seconds
    }]) as $all
    | if ($all | length) > $max then $all[-$max:] else $all end
    | {samples:.}
  ') || return 0
  printf '%s\n' "$next" > "$path"
}

# Resolve W from the meter first, then from distinct resets observed for the
# same provider and window. A missing period remains null. W feeds the retained
# squared-urgency amplifier (1 + K*urgency^2); when missing, pressure is neutral.
fm_usage_window_period() { # <provider> <window_id> <current_reset_epoch> <reported_W_or_null>
  local provider=$1 window_id=$2 current_reset=$3 reported_W=${4:-null}
  local samples
  samples=$(fm_usage_burn_history_load)
  jq -cn \
    --argjson samples "$samples" \
    --arg provider "$provider" \
    --arg window_id "$window_id" \
    --argjson current_reset "$current_reset" \
    --argjson reported_W "$reported_W" '
    if ($reported_W | type) == "number" and $reported_W > 0 then
      {W:$reported_W,source:"meter"}
    else
      (
        [ $samples[]
          | select(.provider == $provider and .window_id == $window_id)
          | .resets_at_epoch
          | select(type == "number")
        ] + [$current_reset]
        | map(select(type == "number"))
        | unique
        | sort
      ) as $resets
      | ([range(1; $resets | length)
          | . as $i
          | ($resets[$i] - $resets[$i - 1])
          | select(. > 0)
        ]) as $periods
      | if ($periods | length) > 0 then
          {W:$periods[-1],source:"history-reset-period"}
        else
          {W:null,source:"missing"}
        end
    end
  '
}

# Counterfactual B is retained only as an observational diagnostic helper for
# history analysis. It is never subtracted from headroom or multiplied into
# score under the captain formula.
fm_usage_burn_rate() { # <provider> <window_id> [legacy ignored args...]
  local provider=$1 window_id=$2 samples
  samples=$(fm_usage_burn_history_load)
  jq -cn \
    --argjson samples "$samples" \
    --arg provider "$provider" \
    --arg window_id "$window_id" '
    ([ $samples[]
       | select(.provider == $provider and .window_id == $window_id)
       | select(
           (.remaining | type) == "number"
           and (.at | type) == "number"
           and (.resets_at_epoch | type) == "number"
           and (.selected | type) == "boolean"
         )
     ] | sort_by(.at)) as $xs
    | ([range(1; $xs | length)
        | . as $i
        | $xs[$i - 1] as $a
        | $xs[$i] as $b
        | select(
            $a.selected == false
            and $b.at > $a.at
            and $a.resets_at_epoch == $b.resets_at_epoch
          )
        | {
            depletion:([0, $a.remaining - $b.remaining] | max),
            elapsed:($b.at - $a.at)
          }
      ]) as $intervals
    | if ($intervals | length) > 0 then
        {
          B:(
            ([$intervals[].depletion] | add)
            / ([$intervals[].elapsed] | add)
          ),
          source:"counterfactual-history"
        }
      else
        {B:0,source:"counterfactual-zero"}
      end
  '
}

# Resolve the target floor for an observation: prefer the registry value carried
# on the observation, else look up the provider, else the known-provider default 5.
fm_usage_burndown_resolve_target() { # <observation_json>
  local obs=$1 provider target
  target=$(printf '%s\n' "$obs" | jq -r '
    if (.target_percent | type) == "number" then .target_percent
    else empty end
  ' 2>/dev/null) || target=
  if [ -n "$target" ]; then
    printf '%s\n' "$target"
    return 0
  fi
  provider=$(printf '%s\n' "$obs" | jq -r '.provider // empty' 2>/dev/null) || provider=
  if [ -n "$provider" ] && fm_usage_source_provider_known "$provider" 2>/dev/null; then
    fm_usage_source_target_percent "$provider"
    return $?
  fi
  printf '%s\n' "$FM_BURNDOWN_DEFAULT_TARGET"
}

fm_usage_burndown_score_one() { # <observation_json>
  local obs=$1 provider window_id R T reset_epoch reported_W period_json target
  if ! printf '%s\n' "$obs" | jq -e '
    (.evidence == "fresh" or .evidence == "stale")
    and ((.binding.remaining? | type) == "number")
    and ((.binding.T? | type) == "number")
    and ((.binding.resets_at_epoch? | type) == "number")
  ' >/dev/null 2>&1; then
    target=$(fm_usage_burndown_resolve_target "$obs")
    printf '%s\n' "$obs" | jq -c --argjson target "$target" '. + {
      target_percent:$target,
      headroom:null,
      score_base:null,
      B:null,
      B_source:"not-used-in-score",
      S:null,
      spendable_surplus:null,
      required_rate:null,
      pressure:null,
      pressure_source:null,
      base_pressure:null,
      reset_available_count:(.rate_limit_reset_credits.available_count // null),
      reset_pressure_factor:null,
      reset_pressure_source:(.rate_limit_reset_credits.source // null),
      urgency:null,
      score:null,
      posture:"unknown",
      percent_used:null,
      eligible:true,
      ineligible_reason:null,
      scorable:false,
      W:null,
      W_source:"missing",
      spend_floor:$target
    }'
    return 0
  fi
  # Codex reset-count handling is part of scoring below. An unreadable count is
  # a loud, named diagnostic with neutral factor 1 - never a silent zero and
  # never a poison of otherwise-valid window evidence (AC-3).
  provider=$(printf '%s\n' "$obs" | jq -r '.provider')
  window_id=$(printf '%s\n' "$obs" | jq -r '.binding.id')
  R=$(printf '%s\n' "$obs" | jq -r '.binding.remaining')
  T=$(printf '%s\n' "$obs" | jq -r '.binding.T')
  reset_epoch=$(printf '%s\n' "$obs" | jq -r '.binding.resets_at_epoch')
  reported_W=$(printf '%s\n' "$obs" | jq -c '.binding.window_seconds // null')
  period_json=$(fm_usage_window_period "$provider" "$window_id" "$reset_epoch" "$reported_W")
  target=$(fm_usage_burndown_resolve_target "$obs")
  jq -cn \
    --argjson obs "$obs" \
    --argjson period "$period_json" \
    --argjson target "$target" \
    --argjson K "$FM_BURNDOWN_PRESSURE_K" \
    --argjson gate_floor "$FM_BURNDOWN_RATE_FLOOR" \
    --argjson reset_factor_base "$FM_BURNDOWN_CODEX_RESET_PRESSURE_FACTOR" '
    $obs as $o
    | $o.binding.remaining as $R
    | $o.binding.T as $T
    | (if $T < 0 then 0 else $T end) as $Tpos
    | $target as $target
    # Captain formula numerator: headroom = R - target (no B*T subtraction).
    # max(0, ...) keeps at-or-below-target providers at score 0 (also freeze).
    | ([0, $R - $target] | max) as $headroom
    | (if $Tpos > 0 then ($headroom / $Tpos) else 0 end) as $score_base
    # Retained near-expiry amplifier: urgency = clamp(1 - T/W, 0, 1).
    | (
        if ($period.W | type) == "number" and $period.W > 0 then
          [0, ([1, 1 - ($Tpos / $period.W)] | min)] | max
        else null
        end
      ) as $urgency
    | (
        if $headroom > 0 and ($urgency | type) == "number" then
          1 + ($K * ($urgency * $urgency))
        else 1
        end
      ) as $base_pressure
    | (($o.rate_limit_reset_credits // {}) ) as $reset
    | ($reset.evidence // "fresh") as $reset_evidence
    | (
        # Unreadable reset count: neutral factor 1 with an explicit unreadable
        # source so it cannot be mistaken for a genuine zero (AC-3). Windows
        # remain scorable so an otherwise-valid dispatch is not poisoned.
        if $o.provider != "codex" then
          {n:null, factor:1, source:null, unreadable:false}
        elif $reset_evidence == "unreadable" then
          {n:null, factor:1, source:($reset.source // "unreadable"), unreadable:true}
        elif (($reset.available_count? | type) == "number") and ($reset.available_count >= 0) then
          ($reset.available_count | floor) as $n
          | {
              n:$n,
              # Compounding C^N via iterative multiply (jq has no pow).
              factor:(reduce range(0; $n) as $_ (1; . * $reset_factor_base)),
              source:($reset.source // "available-count"),
              unreadable:false
            }
        else
          # Missing observation fragment: genuine zero, not an error.
          {n:0, factor:1, source:($reset.source // "absent-as-zero"), unreadable:false}
        end
      ) as $reset_state
    | $reset_state.factor as $reset_factor
    | $reset_state.n as $reset_n
    | ($base_pressure * $reset_factor) as $pressure
    | ($score_base * $pressure) as $score
    | (100 - $R) as $used
    | (($o.gate_windows // []) | all(.remaining > $gate_floor)) as $eligible
    | (
        # Freeze at the per-provider target floor (AC-1 / AC-4).
        if $R <= $target then "freeze"
        elif $used >= 80 then "protect"
        elif $used >= 60 then "conserve"
        else "normal"
        end
      ) as $posture
    | (
        if ($urgency | type) == "number" then "window-urgency" else "neutral-missing-window-period" end
      ) as $base_source
    | (
        if $o.provider != "codex" then
          $base_source
        elif $reset_state.unreadable then
          $base_source + "+codex-reset-unreadable"
        elif ($reset_factor != 1) then
          $base_source + "+codex-reset-" + ($reset_factor_base | tostring) + "^" + (($reset_n | floor) | tostring)
        else
          $base_source + "+codex-reset-1"
        end
      ) as $pressure_source
    | $o + {
        target_percent:$target,
        headroom:$headroom,
        score_base:$score_base,
        # B is observational only; never an input to score (B*T removed).
        B:null,
        B_source:"not-used-in-score",
        # Alias fields: S/required_rate map to headroom/score_base for continuity.
        S:$headroom,
        spendable_surplus:$headroom,
        required_rate:$score_base,
        base_pressure:$base_pressure,
        pressure:$pressure,
        pressure_source:$pressure_source,
        reset_available_count:$reset_n,
        reset_pressure_factor:$reset_factor,
        reset_pressure_source:$reset_state.source,
        reset_count_unreadable:$reset_state.unreadable,
        urgency:$urgency,
        score:$score,
        posture:$posture,
        percent_used:$used,
        eligible:$eligible,
        ineligible_reason:(if $eligible then null else "rate-window-exhausted" end),
        scorable:true,
        W:$period.W,
        W_source:$period.source,
        spend_floor:$target,
        rate_floor:$gate_floor,
        diagnostics:(
          ($o.diagnostics // [])
          + (
              if $reset_state.unreadable then
                ["codex rate-limit reset credits unreadable: "
                  + ($reset.error // "unknown cause")
                  + "; scored windows with neutral reset factor 1 (not a silent zero)"]
              else []
              end
            )
        )
      }
  '
}

fm_usage_burndown_score_all() { # <observations_json_array>
  local observations=$1 n i obs scored out
  n=$(printf '%s\n' "$observations" | jq 'length')
  out='[]'
  i=0
  while [ "$i" -lt "$n" ]; do
    obs=$(printf '%s\n' "$observations" | jq -c --argjson i "$i" '.[$i]')
    scored=$(fm_usage_burndown_score_one "$obs")
    out=$(jq -cn --argjson acc "$out" --argjson scored "$scored" '$acc + [$scored]')
    i=$((i + 1))
  done
  printf '%s\n' "$out"
}

fm_usage_burndown_select() { # <profiles_json> <scored_observations_json> <multi|admit>
  local profiles_json=$1 scored_obs=$2 mode=${3:-multi}
  jq -n -ec \
    --argjson profiles "$profiles_json" \
    --argjson obs "$scored_obs" \
    --arg mode "$mode" '
    def clean($profile):
      {provider:($profile.provider // $profile.harness),harness:$profile.harness}
      + (if ($profile.model? | type) == "string" then {model:$profile.model} else {} end)
      + (if ($profile.effort? | type) == "string" then {effort:$profile.effort} else {} end);
    def obs_for($provider):
      [.[] | select(.provider == $provider)][0];
    def row($index; $profile; $observation):
      {
        index:$index,
        provider:($profile.provider // $profile.harness),
        harness:$profile.harness,
        profile:clean($profile),
        evidence:($observation.evidence // "unknown"),
        scorable:($observation.scorable // false),
        eligible:(
          if ($observation.eligible | type) == "boolean"
          then $observation.eligible
          else true
          end
        ),
        ineligible_reason:($observation.ineligible_reason // null),
        R:(($observation.binding // {}) | .remaining // null),
        T:(($observation.binding // {}) | .T // null),
        W:($observation.W // null),
        W_source:($observation.W_source // "missing"),
        resets_at_epoch:(($observation.binding // {}) | .resets_at_epoch // null),
        target_percent:($observation.target_percent // null),
        headroom:($observation.headroom // null),
        score_base:($observation.score_base // null),
        B:($observation.B // null),
        B_source:($observation.B_source // "not-used-in-score"),
        S:($observation.S // null),
        spendable_surplus:($observation.spendable_surplus // null),
        required_rate:($observation.required_rate // null),
        pressure:($observation.pressure // null),
        pressure_source:($observation.pressure_source // null),
        base_pressure:($observation.base_pressure // null),
        reset_available_count:($observation.reset_available_count // null),
        reset_pressure_factor:($observation.reset_pressure_factor // null),
        reset_pressure_source:($observation.reset_pressure_source // null),
        reset_count_unreadable:($observation.reset_count_unreadable // false),
        urgency:($observation.urgency // null),
        score:($observation.score // null),
        posture:($observation.posture // "unknown"),
        percent_used:($observation.percent_used // null),
        spend_floor:($observation.spend_floor // $observation.target_percent // null),
        rate_floor:($observation.rate_floor // null),
        window_id:(($observation.binding // {}) | .id // null),
        binding_reason:($observation.binding_reason // null),
        window_roles:[
          ($observation.windows // [])[]
          | {
              id,
              role,
              role_source,
              remaining,
              T,
              window_seconds,
              window_seconds_source
            }
        ]
      };
    # Deterministic order: score desc, headroom (S) desc, R desc, T asc, index asc.
    def better($left; $right):
      if $left == null then $right
      elif $right == null then $left
      elif ($left.scorable != true) and ($right.scorable == true) then $right
      elif ($right.scorable != true) and ($left.scorable == true) then $left
      elif ($left.scorable != true) and ($right.scorable != true) then
        if $right.index < $left.index then $right else $left end
      elif $right.score > $left.score then $right
      elif $right.score == $left.score and $right.S > $left.S then $right
      elif $right.score == $left.score and $right.S == $left.S and $right.R > $left.R then $right
      elif $right.score == $left.score and $right.S == $left.S and $right.R == $left.R and $right.T < $left.T then $right
      elif $right.score == $left.score and $right.S == $left.S and $right.R == $left.R and $right.T == $left.T and $right.index < $left.index then $right
      else $left
      end;
    def decision_fields($chosen; $rows; $explain):
      {
        dispatch_strategy:"usage-burndown",
        dispatch_explain:$explain,
        dispatch_candidates:$rows,
        dispatch_selected_index:$chosen.index,
        dispatch_tie_break:"profile-order",
        dispatch_order:"score-desc,S-desc,R-desc,T-asc,index-asc"
      };
    ($obs) as $all_obs
    | ([ $profiles | to_entries[]
         | .key as $index
         | .value as $profile
         | ($all_obs | obs_for($profile.provider // $profile.harness // "")) as $observation
         | row(
             $index;
             $profile;
             ($observation // {
               evidence:"unknown",
               scorable:false,
               eligible:true,
               posture:"unknown"
             })
           )
       ]) as $rows
    | if $mode == "admit" then
        $rows[0] as $chosen
        | if $chosen == null then
            {unavailable:true,frozen:false,profile:null,explain:"no profiles",candidates:[],strategy:"usage-burndown"}
          elif $chosen.eligible != true then
            (
              "admit pin blocked by exhausted rate window; budget R=\($chosen.R) T=\($chosen.T)s"
            ) as $why
            | {
                unavailable:false,
                frozen:true,
                block_reason:"rate-window-exhausted",
                provider:$chosen.provider,
                used:$chosen.percent_used,
                min:$chosen.R,
                profile:(
                  $chosen.profile
                  + {quota_posture:"unknown"}
                  + decision_fields($chosen;$rows;$why)
                ),
                explain:("admit pin provider \($chosen.provider) temporarily ineligible: exhausted rate window"),
                candidates:$rows,
                strategy:"usage-burndown"
              }
          elif $chosen.posture == "freeze" then
            (
              "admit pin at provider target floor \($chosen.target_percent)% remaining"
            ) as $why
            | {
                unavailable:false,
                frozen:true,
                block_reason:"budget-spend-floor",
                provider:$chosen.provider,
                used:$chosen.percent_used,
                min:$chosen.R,
                profile:(
                  $chosen.profile
                  + {
                      quota_posture:"freeze",
                      quota_percent_used:$chosen.percent_used
                    }
                  + decision_fields($chosen;$rows;$why)
                ),
                explain:("admit pin provider \($chosen.provider) reached target floor \($chosen.target_percent)% at \($chosen.R)% remaining"),
                candidates:$rows,
                strategy:"usage-burndown"
              }
          elif $chosen.scorable != true then
            (
              "admit pin; no usable usage evidence"
            ) as $why
            | {
                unavailable:true,
                frozen:false,
                profile:(
                  $chosen.profile
                  + {quota_posture:"unknown"}
                  + decision_fields($chosen;$rows;$why)
                ),
                explain:("admit pin provider \($chosen.provider) retained with unknown posture; no usable evidence"),
                candidates:$rows,
                strategy:"usage-burndown"
              }
          else
            (
              "admit pin; budget=\($chosen.window_id) R=\($chosen.R) T=\($chosen.T)s "
              + "target=\($chosen.target_percent) headroom=\($chosen.headroom) "
              + "score_base=\($chosen.score_base) urgency=\($chosen.urgency) "
              + "base_pressure=\($chosen.base_pressure) "
              + "reset_factor=\($chosen.reset_pressure_factor) score=\($chosen.score)"
            ) as $why
            | {
                unavailable:false,
                frozen:false,
                provider:$chosen.provider,
                used:$chosen.percent_used,
                min:$chosen.R,
                profile:(
                  $chosen.profile
                  + {
                      quota_posture:$chosen.posture,
                      quota_percent_used:$chosen.percent_used
                    }
                  + decision_fields($chosen;$rows;$why)
                ),
                explain:("admit pin provider \($chosen.provider) posture=\($chosen.posture) score=\($chosen.score)"),
                candidates:$rows,
                strategy:"usage-burndown"
              }
          end
      else
        ([$rows[] | select(.scorable == true and .eligible == true and .posture != "freeze")]) as $live
        | ([$rows[] | select(.scorable != true)]) as $unknown
        | ([$rows[] | select(.scorable == true and .eligible == true and .posture == "freeze")]) as $frozen_rows
        | ([$rows[] | select(.scorable == true and .eligible != true)]) as $rate_limited
        | if ($live | length) > 0 then
            (reduce $live[] as $candidate (null; better(.;$candidate))) as $chosen
            | (
                "highest target-rate score; budget=\($chosen.window_id) "
                + "R=\($chosen.R) T=\($chosen.T)s W=\($chosen.W)/\($chosen.W_source) "
                + "target=\($chosen.target_percent) headroom=\($chosen.headroom) "
                + "score_base=\($chosen.score_base) urgency=\($chosen.urgency) "
                + "base_pressure=\($chosen.base_pressure) "
                + "score=((R-target)/T)*(1+K*urgency^2)"
                + (
                    if $chosen.provider == "codex" then
                      " * reset_factor=\($chosen.reset_pressure_factor)"
                      + " (resets=\($chosen.reset_available_count)/\($chosen.reset_pressure_source))"
                    else ""
                    end
                  )
                + " =\($chosen.score); "
                + "binding_reason=\($chosen.binding_reason)"
              ) as $why
            | {
                unavailable:false,
                frozen:false,
                provider:$chosen.provider,
                used:$chosen.percent_used,
                min:$chosen.R,
                profile:(
                  $chosen.profile
                  + {
                      quota_posture:$chosen.posture,
                      quota_percent_used:$chosen.percent_used
                    }
                  + decision_fields($chosen;$rows;$why)
                ),
                explain:("chose index \($chosen.index) provider \($chosen.provider): \($why)"),
                candidates:$rows,
                strategy:"usage-burndown"
              }
          elif ($unknown | length) > 0 then
            (reduce $unknown[] as $candidate (null;better(.;$candidate))) as $chosen
            | (
                if ($frozen_rows | length) > 0 or ($rate_limited | length) > 0
                then "known candidates are unavailable; retained first unknown-evidence profile"
                else "no scorable usage evidence; retained first profile"
                end
              ) as $why
            | {
                unavailable:true,
                frozen:false,
                profile:(
                  $chosen.profile
                  + {quota_posture:"unknown"}
                  + decision_fields($chosen;$rows;$why)
                ),
                explain:("retained index \($chosen.index) provider \($chosen.provider): \($why)"),
                candidates:$rows,
                strategy:"usage-burndown"
              }
          elif ($frozen_rows | length) > 0 then
            (reduce $frozen_rows[] as $candidate (null;better(.;$candidate))) as $chosen
            | (
                "all eligible candidates reached their provider target floor"
              ) as $why
            | {
                unavailable:false,
                frozen:true,
                block_reason:"budget-spend-floor",
                provider:$chosen.provider,
                used:$chosen.percent_used,
                min:$chosen.R,
                profile:(
                  $chosen.profile
                  + {
                      quota_posture:"freeze",
                      quota_percent_used:$chosen.percent_used
                    }
                  + decision_fields($chosen;$rows;$why)
                ),
                explain:("refusing provider \($chosen.provider): \($why)"),
                candidates:$rows,
                strategy:"usage-burndown"
              }
          elif ($rate_limited | length) > 0 then
            (reduce $rate_limited[] as $candidate (null;better(.;$candidate))) as $chosen
            | (
                "all scorable candidates have exhausted rate windows"
              ) as $why
            | {
                unavailable:false,
                frozen:true,
                block_reason:"rate-window-exhausted",
                provider:$chosen.provider,
                used:$chosen.percent_used,
                min:$chosen.R,
                profile:(
                  $chosen.profile
                  + {quota_posture:"unknown"}
                  + decision_fields($chosen;$rows;$why)
                ),
                explain:("refusing provider \($chosen.provider): \($why)"),
                candidates:$rows,
                strategy:"usage-burndown"
              }
          else
            {
              unavailable:true,
              frozen:false,
              profile:(
                clean($profiles[0])
                + {quota_posture:"unknown"}
                + decision_fields(
                    {index:0};
                    $rows;
                    "empty candidate set after scoring"
                  )
              ),
              explain:"empty candidate set",
              candidates:$rows,
              strategy:"usage-burndown"
            }
          end
      end
  '
}

fm_usage_burndown_format_explain() { # <selection_json>
  local selection=$1
  printf '%s\n' "$selection" | jq -r '
    "strategy=\(.strategy // "usage-burndown") explain=\(.explain // "")",
    ((.candidates // [])[]
      | "  candidate[\(.index)] provider=\(.provider) harness=\(.harness) "
        + "evidence=\(.evidence) eligible=\(.eligible) ineligible_reason=\(.ineligible_reason) "
        + "posture=\(.posture) budget=\(.window_id) binding_reason=\(.binding_reason) "
        + "R=\(.R) T=\(.T) W=\(.W)/\(.W_source) target=\(.target_percent) headroom=\(.headroom) "
        + "score_base=\(.score_base) urgency=\(.urgency) "
        + "base_pressure=\(.base_pressure) pressure=\(.pressure)/\(.pressure_source) "
        + (
            if .provider == "codex" then
              "reset_factor=\(.reset_pressure_factor) "
              + "resets=\(.reset_available_count)/\(.reset_pressure_source) "
            else ""
            end
          )
        + "score=\(.score) "
        + "formula=((R-target)/T)*(1+K*urgency^2)"
        + (if .provider == "codex" then "*C^N" else "" end)
        + " "
        + "window_roles=\(.window_roles | tojson)")
  '
}

# Record every scored candidate so later analysis can inspect non-selected
# intervals and so W can still be learned from observed reset changes.
fm_usage_burndown_record_choice() { # <selection_json> <now_epoch>
  local selection=$1 now_epoch=$2 selected_index
  local index provider window_id remaining reset_epoch W selected
  selected_index=$(printf '%s\n' "$selection" | jq -r '.profile.dispatch_selected_index // -1')
  while IFS=$'\t' read -r index provider window_id remaining reset_epoch W; do
    [ -n "$provider" ] || continue
    [ "$remaining" != null ] || continue
    selected=false
    [ "$index" != "$selected_index" ] || selected=true
    fm_usage_burn_history_record \
      "$provider" "$window_id" "$remaining" "$now_epoch" "$selected" "$reset_epoch" "$W"
  done < <(printf '%s\n' "$selection" | jq -r '
    (.candidates // [])[]
    | select(.scorable == true)
    | [
        (.index | tostring),
        .provider,
        (.window_id // ""),
        (.R | tostring),
        (.resets_at_epoch | tostring),
        (.W | tostring)
      ]
    | @tsv
  ')
}
