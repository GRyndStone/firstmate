#!/usr/bin/env bash
# Modular usage-source adapters for the usage-burndown dispatch engine.
#
# This library owns the plug surface every provider class must emit and the
# shipped adapters that fill it from quota-axi (or honest stubs).
# Scoring and selection live in bin/fm-usage-burndown-lib.sh.
# Policy rationale: docs/usage-burndown-dispatch.md.
#
# Plug surface (one JSON object per source observation):
#   source_id, class, provider, evidence (fresh|stale|unknown), unit,
#   windows[{id,kind,remaining,resets_at_epoch,window_seconds}],
#   binding{id,remaining,T,window_seconds} when evidence is usable,
#   diagnostics[] optional human strings.
#
# The registry below is the single owner of recognized provider identities,
# their adapter classes, and whether a meter is wired.
# Recipe for new sources: docs/usage-burndown-dispatch.md.
#
# Sourced only; not executed as a main program.

_FM_USAGE_SOURCE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_USAGE_SOURCE_LIB_DIR="."

# Registry rows are provider identity, adapter class, and meter kind.
# Adding a recognized provider without a meter needs only one unmetered row.
fm_usage_source_registry() {
  printf '%s\t%s\t%s\n' \
    claude anthropic-class quota-axi \
    codex openai-class quota-axi \
    grok grok-class quota-axi \
    gemini gemini-class unmetered \
    openrouter openrouter-class unmetered \
    cursor cursor-class quota-axi \
    copilot copilot-class quota-axi
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
  fm_usage_source_registry | awk -F '\t' 'NF >= 3 { print $1 }'
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

# Map a recognized quota provider id to its adapter class name.
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

# General (non-model) window id list for a provider class / id.
# Empty list means "all non-model windows with percentRemaining".
fm_usage_source_general_ids_json() { # <provider>
  case "${1:-}" in
    claude) printf '%s\n' '["five_hour","seven_day"]' ;;
    codex) printf '%s\n' '["five_hour","weekly"]' ;;
    grok) printf '%s\n' '[]' ;; # all non-model
    gemini|openrouter) printf '%s\n' '[]' ;;
    cursor|copilot) printf '%s\n' '[]' ;;
    *) printf '%s\n' '[]' ;;
  esac
}

# Nominal seconds for a known window id when the meter omits windowSeconds.
fm_usage_source_default_window_seconds() { # <provider> <window_id>
  local id=$2
  case "$id" in
    five_hour) printf '%s\n' 18000 ;;
    seven_day|weekly) printf '%s\n' 604800 ;;
    credits) printf '%s\n' 86400 ;;
    *) printf '%s\n' 0 ;;
  esac
}

# Build one observation object for provider from a full quota-axi JSON blob.
# now_epoch is required for T and stale-window currentness.
# Emits a single-line JSON object on stdout.
fm_usage_source_observe() { # <provider> <quota_json> <now_epoch>
  local provider=$1 quota_json=$2 now_epoch=$3
  local class general_ids meter_kind
  if ! fm_usage_source_provider_known "$provider"; then
    printf "fm-usage-source: unrecognized provider token '%s'\n" "$provider" >&2
    return 64
  fi
  class=$(fm_usage_source_class "$provider") || return $?
  meter_kind=$(fm_usage_source_meter_kind "$provider") || return $?
  general_ids=$(fm_usage_source_general_ids_json "$provider")

  # Recognized providers with no meter path always degrade honestly to unknown.
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
    --argjson general_ids "$general_ids" \
    --argjson now "$now_epoch" '
    def iso_epoch:
      if type != "string" then null
      else try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null
      end;
    def default_secs($id):
      if $id == "five_hour" then 18000
      elif ($id == "seven_day" or $id == "weekly") then 604800
      elif $id == "credits" then 86400
      else 0
      end;
    def general_window_ok($p; $window):
      (($window.kind? // "") != "model")
      and (($window.percentRemaining? | type) == "number")
      and ($window.percentRemaining >= 0)
      and ($window.percentRemaining <= 100)
      and (
        ($general_ids | length) == 0
        or (($general_ids | index($window.id)) != null)
      );
    def stale_window_is_current($refreshed; $window):
      ($window.resetsAt | iso_epoch) as $reset
      | (
          if ($window.windowSeconds? | type) == "number" and $window.windowSeconds > 0
          then $window.windowSeconds
          else default_secs($window.id)
          end
        ) as $duration
      | ($refreshed != null)
        and ($refreshed <= $now)
        and ($reset != null)
        and ($reset > $now)
        and ($reset > $refreshed)
        and ($duration != null)
        and ($duration > 0)
        and (($reset - $refreshed) <= $duration);
    . as $root
    | ([.providers[]? | select(.provider == $provider)][0]) as $p
    | if $p == null then
        {
          source_id:$provider,
          class:$class,
          provider:$provider,
          evidence:"unknown",
          unit:"percent",
          windows:[],
          diagnostics:["provider absent from quota evidence"]
        }
      else
        (($p.state.status? // "unknown") as $status
        | ($p.state.refreshedAt? | iso_epoch) as $refreshed
        | ([($p.windows // [])[]
            | select(general_window_ok($p; .))
            | select(
                $status == "fresh"
                or ($status == "stale" and stale_window_is_current($refreshed; .))
              )
            | . as $w
            | (
                if ($w.windowSeconds? | type) == "number" and $w.windowSeconds > 0
                then $w.windowSeconds
                else default_secs($w.id)
                end
              ) as $ws
            | ($w.resetsAt | iso_epoch) as $reset_raw
            # Fresh meters may omit resetsAt (fixtures and partial APIs). Keep the
            # remaining percent honest; assume a full window ahead for T so we do
            # not invent a near-expiry pressure spike.
            | (if $reset_raw != null and $reset_raw > $now then $reset_raw
               elif $status == "fresh" and $ws > 0 then ($now + $ws)
               else null
               end) as $reset
            | select($reset != null and $ws > 0)
            | {
                id: $w.id,
                kind: ($w.kind // "session"),
                remaining: $w.percentRemaining,
                resets_at_epoch: $reset,
                window_seconds: $ws,
                T: ($reset - $now)
              }
          ]) as $usable
        | if ($usable | length) == 0 then
            {
              source_id:$provider,
              class:$class,
              provider:$provider,
              evidence:"unknown",
              unit:"percent",
              windows:[],
              diagnostics:(
                ["no usable general windows"]
                + (if $status != "fresh" then ["quota status is \($status)"] else [] end)
              )
            }
          else
            # Binding = minimum remaining; soonest reset on ties.
            (
              $usable
              | sort_by(.remaining, .T)
              | .[0]
            ) as $bind
            | {
                source_id:$provider,
                class:$class,
                provider:$provider,
                evidence:(if $status == "fresh" then "fresh" else "stale" end),
                unit:"percent",
                windows: $usable,
                binding: {
                  id: $bind.id,
                  remaining: $bind.remaining,
                  T: $bind.T,
                  window_seconds: $bind.window_seconds
                },
                diagnostics: []
              }
          end
        )
      end
    '
}

# Observe every distinct provider listed in a profiles JSON array.
# profiles_json: [{provider?,harness,...}, ...]
# Prints a JSON array of observation objects (one per distinct provider id).
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
        '{source_id:$provider,class:$class,provider:$provider,evidence:"unknown",unit:"percent",windows:[],diagnostics:["adapter failed"]}')
    fi
    out=$(jq -cn --argjson acc "$out" --argjson o "$obs" '$acc + [$o]')
  done <<< "$providers"
  printf '%s\n' "$out"
}
