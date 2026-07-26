#!/usr/bin/env bash
# Modular usage-source adapters for the usage-burndown dispatch engine.
#
# This library owns provider recognition and the role of each reported usage
# window. A gate window can only make a provider temporarily ineligible. A
# budget window alone supplies optimizer inputs. Unknown window periods stay
# null; the optimizer may derive them from reset history, but this adapter never
# invents a duration.
#
# Plug surface (one JSON object per source observation):
#   source_id, class, provider, evidence (fresh|stale|unknown), unit,
#   windows[{id,kind,role,remaining,resets_at_epoch,window_seconds,
#            window_seconds_source}],
#   gate_windows[], binding{...budget window...}, binding_reason, diagnostics[].
#
# The registry is the single owner of provider identities, adapter classes,
# meter kinds, and provider-specific window-role policy.
# Sourced only; not executed as a main program.

_FM_USAGE_SOURCE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_USAGE_SOURCE_LIB_DIR="."

# Registry columns:
#   provider, adapter class, meter kind, compact window-role policy JSON.
# A provider with no role policy uses the single-window fallback: exactly one
# usable non-model window is both gate and budget. Multiple unclassified windows
# degrade to unknown rather than guessing which pool is durable.
fm_usage_source_registry() {
  printf '%s\t%s\t%s\t%s\n' \
    claude anthropic-class quota-axi '{"budget":["seven_day"],"gate":["five_hour"],"ignore":[]}' \
    codex openai-class quota-axi '{"budget":["weekly"],"gate":["five_hour"],"ignore":[]}' \
    grok grok-class quota-axi '{"budget":["credits"],"gate":["grokbuild","product:grokbuild"],"ignore":["api","product:api","grokimagine","product:grokimagine","chat","product:chat","voice","product:voice"]}' \
    gemini gemini-class unmetered '{"budget":[],"gate":[],"ignore":[]}' \
    openrouter openrouter-class unmetered '{"budget":[],"gate":[],"ignore":[]}' \
    cursor cursor-class quota-axi '{"budget":[],"gate":[],"ignore":[]}' \
    copilot copilot-class quota-axi '{"budget":[],"gate":[],"ignore":[]}'
}

_fm_usage_source_registry_field() { # <provider> <field-number>
  local provider=${1:-} field=${2:-} value
  value=$(fm_usage_source_registry | awk -F '\t' -v provider="$provider" -v field="$field" '
    $1 == provider { print $field; exit }
  ')
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

fm_usage_source_provider_ids() {
  fm_usage_source_registry | awk -F '\t' 'NF >= 4 { print $1 }'
}

fm_usage_source_provider_ids_csv() {
  fm_usage_source_provider_ids | awk '
    BEGIN { separator = "" }
    { printf "%s%s", separator, $0; separator = ", " }
    END { print "" }
  '
}

fm_usage_source_provider_known() { # <provider>
  _fm_usage_source_registry_field "${1:-}" 1 >/dev/null
}

fm_usage_source_class() { # <provider>
  local provider=${1:-}
  if ! _fm_usage_source_registry_field "$provider" 2; then
    printf "fm-usage-source: unrecognized provider token '%s'\n" "$provider" >&2
    return 64
  fi
}

fm_usage_source_meter_kind() { # <provider>
  local provider=${1:-}
  if ! _fm_usage_source_registry_field "$provider" 3; then
    printf "fm-usage-source: unrecognized provider token '%s'\n" "$provider" >&2
    return 64
  fi
}

fm_usage_source_window_policy() { # <provider>
  local provider=${1:-}
  if ! _fm_usage_source_registry_field "$provider" 4; then
    printf "fm-usage-source: unrecognized provider token '%s'\n" "$provider" >&2
    return 64
  fi
}

# Fetch live multi-provider quota JSON from the configured meter command.
# Always passes --allow-keychain-prompt so macOS uses Keychain credentials for
# Claude (and other providers that store tokens there) instead of falling back
# to the file credential store under ~/.claude/.credentials.json, which can
# hold a non-refreshable sentinel shape and yield 401 "Claude sign-in required".
# On non-macOS hosts the flag is accepted by quota-axi and is a no-op when no
# Keychain is present. Callers must never print credential values.
# Args: optional override command (default FM_DISPATCH_QUOTA_AXI or quota-axi).
# Prints JSON on stdout. Returns the meter command's exit status, or 127 if missing.
fm_usage_source_fetch_quota_json() {
  local cmd=${1:-${FM_DISPATCH_QUOTA_AXI:-quota-axi}}
  if ! command -v "$cmd" >/dev/null 2>&1; then
    return 127
  fi
  "$cmd" --allow-keychain-prompt --json
}

# True when the provider is expected to yield scorable meter evidence.
# Unmetered recognized providers (no adapter wired yet) may honestly report
# evidence=unknown without it being a read failure.
fm_usage_source_provider_is_metered() { # <provider>
  local kind
  kind=$(fm_usage_source_meter_kind "${1:-}" 2>/dev/null) || return 1
  [ "$kind" = quota-axi ]
}

# Build one observation object for provider from a full quota-axi JSON blob.
# now_epoch is required for T and stale-window currentness.
fm_usage_source_observe() { # <provider> <quota_json> <now_epoch>
  local provider=$1 quota_json=$2 now_epoch=$3
  local class meter_kind role_policy
  if ! fm_usage_source_provider_known "$provider"; then
    printf "fm-usage-source: unrecognized provider token '%s'\n" "$provider" >&2
    return 64
  fi
  class=$(fm_usage_source_class "$provider") || return $?
  meter_kind=$(fm_usage_source_meter_kind "$provider") || return $?
  role_policy=$(fm_usage_source_window_policy "$provider") || return $?

  case "$meter_kind" in
    unmetered)
      jq -cn \
        --arg source_id "$provider" \
        --arg class "$class" \
        --arg provider "$provider" \
        '{
          source_id:$source_id,
          class:$class,
          provider:$provider,
          evidence:"unknown",
          unit:"percent",
          windows:[],
          gate_windows:[],
          diagnostics:["no usage meter wired for this recognized provider yet; see docs/usage-burndown-dispatch.md"]
        }'
      return 0
      ;;
    quota-axi) ;;
    *)
      printf "fm-usage-source: provider '%s' has unsupported meter kind '%s'\n" "$provider" "$meter_kind" >&2
      return 70
      ;;
  esac

  printf '%s\n' "$quota_json" | jq -ec \
    --arg provider "$provider" \
    --arg class "$class" \
    --argjson policy "$role_policy" \
    --argjson now "$now_epoch" '
    # quota-axi emits fractional seconds and +00:00 offsets.
    # fromdateiso8601 only accepts whole-second ...Z forms; normalize both.
    def iso_epoch:
      if type != "string" then null
      else
        try (
          sub("\\.[0-9]+"; "") as $s
          | if ($s | test("Z$")) then
              $s | fromdateiso8601
            elif ($s | test("[+-][0-9]{2}:?[0-9]{2}$")) then
              ($s | capture("(?<base>.*)(?<sign>[+-])(?<hh>[0-9]{2}):?(?<mm>[0-9]{2})$")) as $m
              | (($m.base + "Z") | fromdateiso8601) as $naive
              | ((($m.hh | tonumber) * 3600) + (($m.mm | tonumber) * 60)) as $off
              | if $m.sign == "+" then $naive - $off else $naive + $off end
            else null
            end
        ) catch null
      end;
    def general_window_ok:
      ((.kind? // "") != "model")
      and ((.percentRemaining? | type) == "number")
      and (.percentRemaining >= 0)
      and (.percentRemaining <= 100);
    def stale_window_is_current($refreshed):
      (.resetsAt | iso_epoch) as $reset
      | (.windowSeconds? // null) as $duration
      | ($refreshed != null)
        and ($refreshed <= $now)
        and ($reset != null)
        and ($reset > $now)
        and ($reset > $refreshed)
        and (($duration | type) == "number")
        and ($duration > 0)
        and (($reset - $refreshed) <= $duration);
    def configured_roles:
      (($policy.budget // []) + ($policy.gate // []) + ($policy.ignore // []));
    def role_for($id; $count):
      if (($policy.budget // []) | index($id)) != null then "budget"
      elif (($policy.gate // []) | index($id)) != null then "gate"
      elif (($policy.ignore // []) | index($id)) != null then "ignored"
      elif (configured_roles | length) > 0 then "unclassified"
      elif $count == 1 then "both"
      else "unclassified"
      end;
    def role_source_for($id; $count):
      if (configured_roles | length) > 0 then "provider-policy"
      elif $count == 1 then "single-window-fallback"
      else "unclassified"
      end;
    ([.providers[]? | select(.provider == $provider)][0]) as $p
    | if $p == null then
        {
          source_id:$provider,
          class:$class,
          provider:$provider,
          evidence:"unknown",
          unit:"percent",
          windows:[],
          gate_windows:[],
          diagnostics:["provider absent from quota evidence"]
        }
      else
        (($p.state.status? // "unknown") as $status
        | ($p.state.refreshedAt? | iso_epoch) as $refreshed
        | ([($p.windows // [])[]
            | select(general_window_ok)
            | select(
                $status == "fresh"
                or ($status == "stale" and stale_window_is_current($refreshed))
              )
            | . as $w
            | ($w.resetsAt | iso_epoch) as $reset
            | select($reset != null and $reset > $now)
            | {
                id: $w.id,
                label: ($w.label // null),
                kind: ($w.kind // "session"),
                remaining: $w.percentRemaining,
                resets_at_epoch: $reset,
                window_seconds: (
                  if ($w.windowSeconds? | type) == "number" and $w.windowSeconds > 0
                  then $w.windowSeconds
                  else null
                  end
                ),
                window_seconds_source: (
                  if ($w.windowSeconds? | type) == "number" and $w.windowSeconds > 0
                  then "meter"
                  else "missing"
                  end
                ),
                T: ($reset - $now)
              }
          ]) as $raw
        | ($raw | length) as $raw_count
        | ($raw | map(
            . + {
              role: role_for(.id; $raw_count),
              role_source: role_source_for(.id; $raw_count)
            }
          )) as $classified
        | ([$classified[] | select(.role == "budget" or .role == "both")]) as $budgets
        | ([$classified[] | select(.role == "gate" or .role == "both")]) as $gates
        | if ($budgets | length) != 1 then
            {
              source_id:$provider,
              class:$class,
              provider:$provider,
              evidence:"unknown",
              unit:"percent",
              windows:$classified,
              gate_windows:$gates,
              diagnostics:(
                if ($raw | length) == 0 then
                  ["no usable non-model windows"]
                elif ($budgets | length) == 0 then
                  ["no budget window can be classified without guessing"]
                else
                  ["multiple budget windows classified; refusing to guess which one binds"]
                end
                + (if $status != "fresh" then ["quota status is \($status)"] else [] end)
              )
            }
          else
            ($budgets[0]) as $budget
            | {
                source_id:$provider,
                class:$class,
                provider:$provider,
                evidence:(if $status == "fresh" then "fresh" else "stale" end),
                unit:"percent",
                windows:$classified,
                gate_windows:$gates,
                binding: {
                  id:$budget.id,
                  role:"budget",
                  role_source:$budget.role_source,
                  remaining:$budget.remaining,
                  resets_at_epoch:$budget.resets_at_epoch,
                  T:$budget.T,
                  window_seconds:$budget.window_seconds,
                  window_seconds_source:$budget.window_seconds_source
                },
                binding_reason:(
                  if $budget.role_source == "single-window-fallback"
                  then "only usable window acts as both eligibility gate and scored budget"
                  else "provider policy marks this as the durable budget; gate windows never affect score"
                  end
                ),
                diagnostics:(
                  [$classified[]
                    | select(.role == "unclassified")
                    | "unclassified window \(.id) was not used"]
                )
              }
          end
        )
      end
    '
}

# Observe every distinct provider listed in a profiles JSON array.
fm_usage_source_observe_profiles() { # <profiles_json> <quota_json> <now_epoch>
  local profiles_json=$1 quota_json=$2 now_epoch=$3
  local providers p obs out class
  providers=$(printf '%s\n' "$profiles_json" | jq -r '
    [.[] | (.provider // .harness // empty) | select(type == "string" and length > 0)]
    | unique | .[]
  ')
  out='[]'
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if ! fm_usage_source_provider_known "$p"; then
      printf "fm-usage-source: unrecognized provider token '%s'\n" "$p" >&2
      return 64
    fi
    if ! obs=$(fm_usage_source_observe "$p" "$quota_json" "$now_epoch"); then
      class=$(fm_usage_source_class "$p") || return $?
      obs=$(jq -cn \
        --arg provider "$p" \
        --arg class "$class" \
        '{source_id:$provider,class:$class,provider:$provider,evidence:"unknown",unit:"percent",windows:[],gate_windows:[],diagnostics:["adapter failed"]}')
    fi
    out=$(jq -cn --argjson acc "$out" --argjson o "$obs" '$acc + [$o]')
  done <<< "$providers"
  printf '%s\n' "$out"
}
