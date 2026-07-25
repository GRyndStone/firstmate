#!/usr/bin/env bash
# Usage-burndown optimizer core for crew dispatch selection.
#
# Single owner of the objective and scoring policy:
#   S = max(0, R - B*T)
#   urgency = clamp(1 - T/W, 0, 1)
#   pressure = 1 + K * urgency^2 when S > 0 else 1
#   score = S * pressure
# Multi-candidate select maximizes score (then S, then R, then lower index).
# Feasible burn B is learned from observed samples, with a snapshot prior.
# Never a static ranking table. Full design: docs/usage-burndown-dispatch.md.
#
# Sourced only; not executed as a main program.
# Depends on: jq. Optional history file path via FM_USAGE_BURN_HISTORY or
# FM_HOME/data/usage-burn-history.json.

_FM_USAGE_BURNDOWN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_USAGE_BURNDOWN_LIB_DIR="."

# shellcheck source=bin/fm-usage-source-lib.sh
. "$_FM_USAGE_BURNDOWN_LIB_DIR/fm-usage-source-lib.sh"

FM_BURNDOWN_PRESSURE_K=${FM_BURNDOWN_PRESSURE_K:-4}
FM_BURNDOWN_HISTORY_MAX=${FM_BURNDOWN_HISTORY_MAX:-200}

# Resolve the burn-history path for this home.
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

# Load history samples array (possibly empty). Always prints valid JSON array.
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

# Append one sample after a scored decision. No-op when path unset.
# Args: provider window_id remaining at_epoch
fm_usage_burn_history_record() {
  local provider=$1 window_id=$2 remaining=$3 at_epoch=$4
  local path dir tmp samples
  path=$(fm_usage_burn_history_path)
  [ -n "$path" ] || return 0
  dir=$(dirname "$path")
  mkdir -p "$dir" 2>/dev/null || return 0
  samples=$(fm_usage_burn_history_load)
  tmp=$(jq -cn \
    --argjson samples "$samples" \
    --arg provider "$provider" \
    --arg window_id "$window_id" \
    --argjson remaining "$remaining" \
    --argjson at "$at_epoch" \
    --argjson max "${FM_BURNDOWN_HISTORY_MAX}" '
    ($samples + [{
      provider:$provider,
      window_id:$window_id,
      remaining:$remaining,
      at:$at
    }]) as $all
    | if ($all | length) > $max then $all[-$max:] else $all end
    | {samples: .}
  ') || return 0
  printf '%s\n' "$tmp" > "$path"
}

# Compute B (percent per second) for a provider/window from history + prior.
# residual args: R T W percent_used_or_empty
# Prints: {"B":number,"source":"history|prior|zero"}
fm_usage_burn_rate() {
  local provider=$1 window_id=$2 R=$3 T=$4 W=$5
  local samples
  samples=$(fm_usage_burn_history_load)
  jq -cn \
    --argjson samples "$samples" \
    --arg provider "$provider" \
    --arg window_id "$window_id" \
    --argjson R "$R" \
    --argjson T "$T" \
    --argjson W "$W" '
    def history_B:
      ([ $samples[]
         | select(.provider == $provider and .window_id == $window_id)
         | select((.remaining | type) == "number" and (.at | type) == "number")
       ] | sort_by(.at)) as $xs
      | if ($xs | length) < 2 then null
        else
          ([ range(1; $xs | length)
             | . as $i
             | $xs[$i - 1] as $a
             | $xs[$i] as $b
             | select($b.at > $a.at and $a.remaining > $b.remaining)
             | (($a.remaining - $b.remaining) / ($b.at - $a.at))
           ] | map(select(. > 0))) as $rates
          | if ($rates | length) == 0 then null
            else (($rates | add) / ($rates | length))
            end
        end;
    def prior_B:
      ($W - $T) as $elapsed
      | (100 - $R) as $used
      | if $elapsed > 0 and $used > 0 and $used <= 100 then ($used / $elapsed)
        else null
        end;
    (history_B) as $h
    | (prior_B) as $p
    | if $h != null then {B:$h, source:"history"}
      elif $p != null then {B:$p, source:"prior"}
      else {B:0, source:"zero"}
      end
  '
}

# Score one observation object. Adds S, B, pressure, score, posture fields.
# observation must include evidence and optional binding.
fm_usage_burndown_score_one() { # <observation_json>
  local obs=$1
  local provider window_id R T W burn_json
  if ! printf '%s\n' "$obs" | jq -e '.evidence == "fresh" or .evidence == "stale"' >/dev/null 2>&1; then
    printf '%s\n' "$obs" | jq -c '. + {
      B: null, B_source: "none", S: null, pressure: null, score: null,
      posture: "unknown", percent_used: null, scorable: false
    }'
    return 0
  fi
  provider=$(printf '%s\n' "$obs" | jq -r '.provider')
  window_id=$(printf '%s\n' "$obs" | jq -r '.binding.id')
  R=$(printf '%s\n' "$obs" | jq -r '.binding.remaining')
  T=$(printf '%s\n' "$obs" | jq -r '.binding.T')
  W=$(printf '%s\n' "$obs" | jq -r '.binding.window_seconds')
  burn_json=$(fm_usage_burn_rate "$provider" "$window_id" "$R" "$T" "$W")
  jq -cn \
    --argjson obs "$obs" \
    --argjson burn "$burn_json" \
    --argjson K "${FM_BURNDOWN_PRESSURE_K}" '
    $obs as $o
    | ($o.binding.remaining) as $R
    | ($o.binding.T) as $T
    | ($o.binding.window_seconds) as $W
    | ($burn.B) as $B
    | (if $T < 0 then 0 else $T end) as $Tpos
    | ([0, $R - ($B * $Tpos)] | max) as $S
    | (if $W > 0 then ([0, ([1, 1 - ($Tpos / $W)] | min)] | max) else 0 end) as $urgency
    | (if $S > 0 then 1 + ($K * ($urgency * $urgency)) else 1 end) as $pressure
    | ($S * $pressure) as $score
    | (100 - $R) as $used
    | (if $used >= 90 then "freeze"
       elif $used >= 80 then "protect"
       elif $used >= 60 then "conserve"
       else "normal" end) as $posture
    | $o + {
        B: $B,
        B_source: $burn.source,
        S: $S,
        pressure: $pressure,
        urgency: $urgency,
        score: $score,
        posture: $posture,
        percent_used: $used,
        scorable: true
      }
  '
}

# Score an array of observations. Prints JSON array of scored objects.
fm_usage_burndown_score_all() { # <observations_json_array>
  local observations=$1
  local n i obs scored out
  n=$(printf '%s\n' "$observations" | jq 'length')
  out='[]'
  i=0
  while [ "$i" -lt "$n" ]; do
    obs=$(printf '%s\n' "$observations" | jq -c --argjson i "$i" '.[$i]')
    scored=$(fm_usage_burndown_score_one "$obs")
    out=$(jq -cn --argjson acc "$out" --argjson s "$scored" '$acc + [$s]')
    i=$((i + 1))
  done
  printf '%s\n' "$out"
}

# Select among profile candidates using scored source observations.
#
# profiles_json: ordered array of clean profile objects (provider/harness/...)
# observations_json: array of scored observations keyed by provider
#
# Prints one JSON object:
#   {
#     unavailable: bool,
#     frozen: bool,
#     profile: {...},
#     explain: string,
#     candidates: [... scored join rows ...],
#     strategy: "usage-burndown"
#   }
#
# mode:
#   multi  - maximize burndown score among non-freeze when possible
#   admit  - score only the first profile (index 0); freeze in place
fm_usage_burndown_select() { # <profiles_json> <scored_observations_json> <mode>
  local profiles_json=$1 scored_obs=$2 mode=${3:-multi}
  # -n: pure --argjson program; do not read stdin as JSON input.
  jq -n -ec \
    --argjson profiles "$profiles_json" \
    --argjson obs "$scored_obs" \
    --arg mode "$mode" '
    def clean($p):
      {provider: ($p.provider // $p.harness), harness: $p.harness}
      + (if ($p.model? | type) == "string" then {model: $p.model} else {} end)
      + (if ($p.effort? | type) == "string" then {effort: $p.effort} else {} end);
    def obs_for($provider):
      [.[] | select(.provider == $provider)][0];
    def row($i; $p; $o):
      {
        index: $i,
        provider: ($p.provider // $p.harness),
        harness: $p.harness,
        profile: clean($p),
        evidence: ($o.evidence // "unknown"),
        scorable: ($o.scorable // false),
        R: (($o.binding // {}) | .remaining // null),
        T: (($o.binding // {}) | .T // null),
        W: (($o.binding // {}) | .window_seconds // null),
        B: ($o.B // null),
        B_source: ($o.B_source // "none"),
        S: ($o.S // null),
        pressure: ($o.pressure // null),
        score: ($o.score // null),
        posture: ($o.posture // "unknown"),
        percent_used: ($o.percent_used // null),
        window_id: (($o.binding // {}) | .id // null)
      };
    def better($a; $b):
      if $a == null then $b
      elif $b == null then $a
      elif ($a.scorable != true) and ($b.scorable == true) then $b
      elif ($b.scorable != true) and ($a.scorable == true) then $a
      elif ($a.scorable != true) and ($b.scorable != true) then
        (if $b.index < $a.index then $b else $a end)
      elif ($b.score > $a.score) then $b
      elif ($b.score == $a.score and $b.S > $a.S) then $b
      elif ($b.score == $a.score and $b.S == $a.S and $b.R > $a.R) then $b
      elif ($b.score == $a.score and $b.S == $a.S and $b.R == $a.R and $b.index < $a.index) then $b
      else $a
      end;
    ($obs) as $all_obs
    | ([ $profiles | to_entries[]
         | .key as $i | .value as $p
         | ($all_obs | obs_for($p.provider // $p.harness // "")) as $o
         | row($i; $p; ($o // {evidence:"unknown", scorable:false, posture:"unknown"}))
       ]) as $rows
    | if $mode == "admit" then
        ($rows[0]) as $chosen
        | if $chosen == null then
            {unavailable:true, frozen:false, profile:null, explain:"no profiles", candidates:[], strategy:"usage-burndown"}
          elif $chosen.posture == "freeze" then
            {
              unavailable:false,
              frozen:true,
              provider:$chosen.provider,
              used:$chosen.percent_used,
              min:$chosen.R,
              profile: ($chosen.profile + {
                quota_posture:"freeze",
                quota_percent_used:$chosen.percent_used,
                dispatch_strategy:"usage-burndown",
                dispatch_explain:("admit pin freeze at \($chosen.percent_used)% used")
              }),
              explain:("admit pin provider \($chosen.provider) freeze at \($chosen.percent_used)% used"),
              candidates:$rows,
              strategy:"usage-burndown"
            }
          elif $chosen.scorable != true then
            {
              unavailable:true,
              frozen:false,
              profile: ($chosen.profile + {
                quota_posture:"unknown",
                dispatch_strategy:"usage-burndown",
                dispatch_explain:"admit pin; no usable usage evidence"
              }),
              explain:("admit pin provider \($chosen.provider) retained with unknown posture; no usable evidence"),
              candidates:$rows,
              strategy:"usage-burndown"
            }
          else
            {
              unavailable:false,
              frozen:false,
              provider:$chosen.provider,
              used:$chosen.percent_used,
              min:$chosen.R,
              profile: ($chosen.profile + {
                quota_posture:$chosen.posture,
                quota_percent_used:$chosen.percent_used,
                dispatch_strategy:"usage-burndown",
                dispatch_explain:("admit pin; posture=\($chosen.posture); R=\($chosen.R); S=\($chosen.S); B=\($chosen.B) (\($chosen.B_source))")
              }),
              explain:("admit pin provider \($chosen.provider) posture=\($chosen.posture) score=\($chosen.score)"),
              candidates:$rows,
              strategy:"usage-burndown"
            }
          end
      else
        ([$rows[] | select(.scorable == true and .posture != "freeze")]) as $live
        | ([$rows[] | select(.scorable != true)]) as $unknown
        | ([$rows[] | select(.scorable == true and .posture == "freeze")]) as $frozen_rows
        | if ($live | length) > 0 then
            (reduce $live[] as $x (null; better(.; $x))) as $chosen
            | {
                unavailable:false,
                frozen:false,
                provider:$chosen.provider,
                used:$chosen.percent_used,
                min:$chosen.R,
                profile: ($chosen.profile + {
                  quota_posture:$chosen.posture,
                  quota_percent_used:$chosen.percent_used,
                  dispatch_strategy:"usage-burndown",
                  dispatch_explain:("highest expiry-weighted surplus; R=\($chosen.R) T=\($chosen.T)s B=\($chosen.B)/\($chosen.B_source) S=\($chosen.S) pressure=\($chosen.pressure) score=\($chosen.score)")
                }),
                explain:("chose index \($chosen.index) provider \($chosen.provider): highest expiry-weighted surplus (score=\($chosen.score), S=\($chosen.S), R=\($chosen.R), T=\($chosen.T)s)"),
                candidates:$rows,
                strategy:"usage-burndown"
              }
          elif ($unknown | length) > 0 and ($frozen_rows | length) == 0 then
            (reduce $unknown[] as $x (null; better(.; $x))) as $chosen
            | {
                unavailable:true,
                frozen:false,
                profile: ($chosen.profile + {
                  quota_posture:"unknown",
                  dispatch_strategy:"usage-burndown",
                  dispatch_explain:"no scorable usage evidence among candidates; first unknown retained"
                }),
                explain:("no scorable evidence; retained index \($chosen.index) provider \($chosen.provider) with unknown posture"),
                candidates:$rows,
                strategy:"usage-burndown"
              }
          elif ($unknown | length) > 0 then
            (reduce $unknown[] as $x (null; better(.; $x))) as $chosen
            | {
                unavailable:true,
                frozen:false,
                profile: ($chosen.profile + {
                  quota_posture:"unknown",
                  dispatch_strategy:"usage-burndown",
                  dispatch_explain:"scorable candidates are freeze; retained unknown-evidence profile"
                }),
                explain:("live candidates frozen or absent; retained unknown index \($chosen.index) provider \($chosen.provider)"),
                candidates:$rows,
                strategy:"usage-burndown"
              }
          elif ($frozen_rows | length) > 0 then
            (reduce $frozen_rows[] as $x (null; better(.; $x))) as $chosen
            | {
                unavailable:false,
                frozen:true,
                provider:$chosen.provider,
                used:$chosen.percent_used,
                min:$chosen.R,
                profile: ($chosen.profile + {
                  quota_posture:"freeze",
                  quota_percent_used:$chosen.percent_used,
                  dispatch_strategy:"usage-burndown",
                  dispatch_explain:("all scorable candidates freeze; refusing at \($chosen.percent_used)% used")
                }),
                explain:("all scorable candidates freeze; refusing provider \($chosen.provider) at \($chosen.percent_used)% used"),
                candidates:$rows,
                strategy:"usage-burndown"
              }
          else
            {
              unavailable:true,
              frozen:false,
              profile: (clean($profiles[0]) + {
                quota_posture:"unknown",
                dispatch_strategy:"usage-burndown",
                dispatch_explain:"empty candidate set after scoring"
              }),
              explain:"empty candidate set",
              candidates:$rows,
              strategy:"usage-burndown"
            }
          end
      end
  '
}

# Format candidate rows for stderr logging (one line per candidate).
fm_usage_burndown_format_explain() { # <selection_json>
  local selection=$1
  printf '%s\n' "$selection" | jq -r '
    "strategy=\(.strategy // "usage-burndown") explain=\(.explain // "")",
    ((.candidates // [])[]
      | "  candidate[\(.index)] provider=\(.provider) harness=\(.harness) evidence=\(.evidence) posture=\(.posture) R=\(.R) T=\(.T) B=\(.B)/\(.B_source) S=\(.S) pressure=\(.pressure) score=\(.score)")
  '
}

# Record burn samples for the chosen scored profile when binding is known.
fm_usage_burndown_record_choice() { # <selection_json> <now_epoch>
  local selection=$1 now_epoch=$2
  local provider window_id remaining
  provider=$(printf '%s\n' "$selection" | jq -r '.profile.provider // empty')
  [ -n "$provider" ] || return 0
  window_id=$(printf '%s\n' "$selection" | jq -r --arg prov "$provider" '
    [.candidates[]? | select(.provider == $prov) | .window_id // empty][0]
  ')
  remaining=$(printf '%s\n' "$selection" | jq -r --arg prov "$provider" '
    [.candidates[]? | select(.provider == $prov) | .R // empty][0]
  ')
  if [ -n "$window_id" ] && [ -n "$remaining" ] && [ "$remaining" != "null" ]; then
    fm_usage_burn_history_record "$provider" "$window_id" "$remaining" "$now_epoch"
  fi
}
