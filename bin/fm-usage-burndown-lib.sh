#!/usr/bin/env bash
# Usage-burndown optimizer core for crew dispatch selection.
#
# Only a provider's durable budget window is scored. Short rate windows are
# eligibility gates and never contribute R, T, B, urgency, pressure, or score.
#
#   spendable = max(0, R - floor)
#   S = max(0, spendable - B*T)
#   required_rate = S/T
#   urgency = clamp(1 - T/W, 0, 1) when W is observed or learned
#   base_pressure = 1 + K*urgency^2 when S > 0 and W is known, otherwise 1
#   for provider=codex only:
#     reset_factor = F^N where N = available rate-limit reset credits
#     (F defaults to 1.5; compounding). Other providers use reset_factor = 1.
#   pressure = base_pressure * reset_factor
#   score = required_rate * pressure
#
# B estimates consumption while this provider was not selected at a routing
# decision. It never extrapolates the routed provider's own burst or snapshot
# usage. W comes from the meter or a change in observed resetsAt; it is never a
# provider constant. Codex N is a real observation of rateLimitResetCredits;
# unreadable N is an error, never a silent zero. Full rationale:
# docs/usage-burndown-dispatch.md.
#
# Sourced only; not executed as a main program.

_FM_USAGE_BURNDOWN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_USAGE_BURNDOWN_LIB_DIR="."

# shellcheck source=bin/fm-usage-source-lib.sh
. "$_FM_USAGE_BURNDOWN_LIB_DIR/fm-usage-source-lib.sh"

FM_BURNDOWN_PRESSURE_K=${FM_BURNDOWN_PRESSURE_K:-4}
FM_BURNDOWN_HISTORY_MAX=${FM_BURNDOWN_HISTORY_MAX:-200}
FM_BURNDOWN_SPEND_FLOOR=${FM_BURNDOWN_SPEND_FLOOR:-5}
FM_BURNDOWN_RATE_FLOOR=${FM_BURNDOWN_RATE_FLOOR:-0}
# Compounding per-available-reset multiplier for provider=codex only.
FM_BURNDOWN_CODEX_RESET_PRESSURE_FACTOR=${FM_BURNDOWN_CODEX_RESET_PRESSURE_FACTOR:-1.5}

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

FM_BURNDOWN_PRESSURE_K=$(fm_usage_burndown_numeric_or_default "$FM_BURNDOWN_PRESSURE_K" 4 0 100)
FM_BURNDOWN_HISTORY_MAX=$(fm_usage_burndown_numeric_or_default "$FM_BURNDOWN_HISTORY_MAX" 200 1 10000)
FM_BURNDOWN_SPEND_FLOOR=$(fm_usage_burndown_numeric_or_default "$FM_BURNDOWN_SPEND_FLOOR" 5 0 100)
FM_BURNDOWN_RATE_FLOOR=$(fm_usage_burndown_numeric_or_default "$FM_BURNDOWN_RATE_FLOOR" 0 0 100)
FM_BURNDOWN_CODEX_RESET_PRESSURE_FACTOR=$(fm_usage_burndown_numeric_or_default \
  "$FM_BURNDOWN_CODEX_RESET_PRESSURE_FACTOR" 1.5 1 10)

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

# Append one observed budget-window sample.
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
# same provider and window. A missing period remains null.
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

# Counterfactual B: total positive depletion divided by total elapsed time over
# intervals whose first decision did not select this provider. Zero-depletion
# intervals count as evidence of zero background demand. Legacy samples without
# an explicit selected flag and routed intervals are deliberately ignored.
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

fm_usage_burndown_score_one() { # <observation_json>
  local obs=$1 provider window_id R T reset_epoch reported_W period_json burn_json
  if ! printf '%s\n' "$obs" | jq -e '
    (.evidence == "fresh" or .evidence == "stale")
    and ((.binding.remaining? | type) == "number")
    and ((.binding.T? | type) == "number")
    and ((.binding.resets_at_epoch? | type) == "number")
  ' >/dev/null 2>&1; then
    printf '%s\n' "$obs" | jq -c '. + {
      B:null,
      B_source:"none",
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
      W_source:"missing"
    }'
    return 0
  fi
  # Codex requires a readable rate-limit reset count. Unreadable is an error
  # path (evidence already demoted by the source adapter); refuse to invent 0.
  if printf '%s\n' "$obs" | jq -e '
    .provider == "codex"
    and (
      (.rate_limit_reset_credits? == null)
      or (.rate_limit_reset_credits.evidence == "unreadable")
      or ((.rate_limit_reset_credits.available_count? | type) != "number")
    )
  ' >/dev/null 2>&1; then
    printf '%s\n' "$obs" | jq -c '
      . as $o
      | ($o.rate_limit_reset_credits // {}) as $r
      | $o + {
          B:null,
          B_source:"none",
          S:null,
          spendable_surplus:null,
          required_rate:null,
          pressure:null,
          pressure_source:null,
          base_pressure:null,
          reset_available_count:($r.available_count // null),
          reset_pressure_factor:null,
          reset_pressure_source:($r.source // "missing"),
          urgency:null,
          score:null,
          posture:"unknown",
          percent_used:null,
          eligible:true,
          ineligible_reason:null,
          scorable:false,
          W:null,
          W_source:"missing",
          diagnostics:(
            ($o.diagnostics // [])
            + (
                if ($r.evidence // "") == "unreadable" then
                  ["codex reset count unreadable: " + ($r.error // "unknown")]
                elif $o.rate_limit_reset_credits == null then
                  ["codex reset count missing from observation"]
                else
                  ["codex reset count is not a number"]
                end
              )
          )
        }
    '
    return 0
  fi
  provider=$(printf '%s\n' "$obs" | jq -r '.provider')
  window_id=$(printf '%s\n' "$obs" | jq -r '.binding.id')
  R=$(printf '%s\n' "$obs" | jq -r '.binding.remaining')
  T=$(printf '%s\n' "$obs" | jq -r '.binding.T')
  reset_epoch=$(printf '%s\n' "$obs" | jq -r '.binding.resets_at_epoch')
  reported_W=$(printf '%s\n' "$obs" | jq -c '.binding.window_seconds // null')
  period_json=$(fm_usage_window_period "$provider" "$window_id" "$reset_epoch" "$reported_W")
  burn_json=$(fm_usage_burn_rate "$provider" "$window_id" "$R" "$T" "$reported_W")
  jq -cn \
    --argjson obs "$obs" \
    --argjson burn "$burn_json" \
    --argjson period "$period_json" \
    --argjson K "$FM_BURNDOWN_PRESSURE_K" \
    --argjson floor "$FM_BURNDOWN_SPEND_FLOOR" \
    --argjson gate_floor "$FM_BURNDOWN_RATE_FLOOR" \
    --argjson reset_factor_base "$FM_BURNDOWN_CODEX_RESET_PRESSURE_FACTOR" '
    $obs as $o
    | $o.binding.remaining as $R
    | $o.binding.T as $T
    | (if $T < 0 then 0 else $T end) as $Tpos
    | $burn.B as $B
    | ([0, $R - $floor] | max) as $spendable
    | ([0, $spendable - ($B * $Tpos)] | max) as $S
    | (if $Tpos > 0 then ($S / $Tpos) else 0 end) as $required_rate
    | (
        if ($period.W | type) == "number" and $period.W > 0 then
          [0, ([1, 1 - ($Tpos / $period.W)] | min)] | max
        else null
        end
      ) as $urgency
    | (
        if $S > 0 and ($urgency | type) == "number" then
          1 + ($K * ($urgency * $urgency))
        else 1
        end
      ) as $base_pressure
    | (
        if $o.provider == "codex" then
          (($o.rate_limit_reset_credits // {}).available_count // 0) as $n
          | if ($n | type) == "number" and $n >= 0 then
              # Compounding F^N via iterative multiply (jq has no pow).
              reduce range(0; ($n | floor)) as $_ (1; . * $reset_factor_base)
            else 1
            end
        else 1
        end
      ) as $reset_factor
    | ($base_pressure * $reset_factor) as $pressure
    | ($required_rate * $pressure) as $score
    | (100 - $R) as $used
    | (($o.gate_windows // []) | all(.remaining > $gate_floor)) as $eligible
    | (
        if $R <= $floor then "freeze"
        elif $used >= 80 then "protect"
        elif $used >= 60 then "conserve"
        else "normal"
        end
      ) as $posture
    | (
        if $o.provider == "codex" then
          (($o.rate_limit_reset_credits // {}).available_count // 0)
        else null
        end
      ) as $reset_n
    | (
        if ($urgency | type) == "number" then "window-urgency" else "neutral-missing-window-period" end
      ) as $base_source
    | $o + {
        B:$B,
        B_source:$burn.source,
        S:$S,
        spendable_surplus:$S,
        required_rate:$required_rate,
        base_pressure:$base_pressure,
        pressure:$pressure,
        pressure_source:(
          if $o.provider == "codex" and ($reset_factor != 1) then
            $base_source + "+codex-reset-" + ($reset_factor_base | tostring) + "^" + (($reset_n | floor) | tostring)
          elif $o.provider == "codex" then
            $base_source + "+codex-reset-1"
          else
            $base_source
          end
        ),
        reset_available_count:$reset_n,
        reset_pressure_factor:$reset_factor,
        reset_pressure_source:(
          if $o.provider == "codex" then
            ($o.rate_limit_reset_credits // {}).source // "absent-as-zero"
          else null
          end
        ),
        urgency:$urgency,
        score:$score,
        posture:$posture,
        percent_used:$used,
        eligible:$eligible,
        ineligible_reason:(if $eligible then null else "rate-window-exhausted" end),
        scorable:true,
        W:$period.W,
        W_source:$period.source,
        spend_floor:$floor,
        rate_floor:$gate_floor
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
        B:($observation.B // null),
        B_source:($observation.B_source // "none"),
        S:($observation.S // null),
        spendable_surplus:($observation.spendable_surplus // null),
        required_rate:($observation.required_rate // null),
        pressure:($observation.pressure // null),
        pressure_source:($observation.pressure_source // null),
        base_pressure:($observation.base_pressure // null),
        reset_available_count:($observation.reset_available_count // null),
        reset_pressure_factor:($observation.reset_pressure_factor // null),
        reset_pressure_source:($observation.reset_pressure_source // null),
        urgency:($observation.urgency // null),
        score:($observation.score // null),
        posture:($observation.posture // "unknown"),
        percent_used:($observation.percent_used // null),
        spend_floor:($observation.spend_floor // null),
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
              "admit pin at budget spend floor \($chosen.spend_floor)% remaining"
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
                explain:("admit pin provider \($chosen.provider) reached budget spend floor at \($chosen.R)% remaining"),
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
              + "B=\($chosen.B)/\($chosen.B_source) S=\($chosen.S) "
              + "required_rate=\($chosen.required_rate) urgency=\($chosen.urgency) "
              + "pressure=\($chosen.pressure) score=\($chosen.score)"
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
                "highest expiry burn requirement; budget=\($chosen.window_id) "
                + "R=\($chosen.R) T=\($chosen.T)s W=\($chosen.W)/\($chosen.W_source) "
                + "B=\($chosen.B)/\($chosen.B_source) S=\($chosen.S) "
                + "required_rate=\($chosen.required_rate) urgency=\($chosen.urgency) "
                + "pressure=\($chosen.pressure)"
                + (
                    if $chosen.provider == "codex" then
                      " (base=\($chosen.base_pressure) reset_factor=\($chosen.reset_pressure_factor)"
                      + " resets=\($chosen.reset_available_count)/\($chosen.reset_pressure_source))"
                    else ""
                    end
                  )
                + " score=\($chosen.score); "
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
                "all eligible candidates reached the budget spend floor"
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
        + "R=\(.R) T=\(.T) W=\(.W)/\(.W_source) "
        + "B=\(.B)/\(.B_source) S=\(.S) required_rate=\(.required_rate) "
        + "urgency=\(.urgency) pressure=\(.pressure)/\(.pressure_source) "
        + (
            if .provider == "codex" then
              "base_pressure=\(.base_pressure) reset_factor=\(.reset_pressure_factor) "
              + "resets=\(.reset_available_count)/\(.reset_pressure_source) "
            else ""
            end
          )
        + "score=\(.score) "
        + "window_roles=\(.window_roles | tojson)")
  '
}

# Record every scored candidate so later B can use intervals in which a provider
# was not selected and W can use observed reset changes.
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
