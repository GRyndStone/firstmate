#!/usr/bin/env bash
# Resolve one already-matched crew-dispatch rule to a concrete profile and,
# when requested, apply provider usage admission to that selected profile.
# Usage:
#   fm-dispatch-select.sh [--select <strategy>] [--admit] [--quota-json <file>] [<rule-or-use-json>]
#   fm-dispatch-select.sh --resume-meta <state/task.meta> [--quota-json <file>]
#
# Input may be a full rule object with `use` and optional `select`, a single
# profile object, or an ordered array of profile objects.
# Output is one compact JSON profile object on stdout.
#
# This header is the single owner of the CLI and admission wire contract.
# The routine multi-candidate decision policy is the usage-burndown optimizer
# (bin/fm-usage-burndown-lib.sh + bin/fm-usage-source-lib.sh); full design in
# docs/usage-burndown-dispatch.md.
#
# Contract summary:
#   - `provider` is the usage/quota identity and `harness` is the launch adapter.
#     A profile may state both; provider defaults to harness for compatibility.
#   - Multi-candidate selection strategy: `usage-burndown` (canonical).
#     Legacy alias: `quota-balanced` (same engine; existing configs keep working).
#   - Per source, adapters expose remaining usage R, time-to-reset T, and
#     feasible burn B (learned from history, never a static table). Projected
#     expiry surplus S = max(0, R - B*T); score = S * pressure, with pressure
#     rising as T shrinks while S > 0. Highest score wins; freeze-level sources
#     are skipped when any non-freeze known source exists.
#   - Observational postures from percent used: below 60% normal, at 60%
#     conserve, at 80% protect, at 90% freeze (inclusive). Posture does not rank
#     multi-candidate winners; freeze still refuses an explicit pin in place
#     (exit 75) and never substitutes another provider for that pin.
#   - Stale-but-current general-window numbers remain usable under adapter rules
#     (refreshedAt/resetsAt prove the window is still current).
#   - Recognized providers with missing, failed, or unusable usage evidence stay
#     observable on stderr but cannot prove freeze. Admission retains the selected
#     profile with provider_recognition=recognized and quota_posture=unknown.
#   - Unrecognized provider tokens emit a machine-distinct error profile with
#     provider_recognition=unrecognized and dispatch_error=unrecognized-provider,
#     name the bad token and recognized set on stderr, and exit 64.
#   - Every scored decision logs candidates and why on stderr; the profile JSON
#     also carries dispatch_strategy and dispatch_explain when available.
#   - --resume-meta reconstructs only the recorded provider/harness/model/effort
#     pin. It never evaluates candidates or replaces a task, branch, or run.
#     Freeze pauses that pinned provider; once it clears, the same pin is output.
#   - Captain per-task instructions outrank the engine: when firstmate passes a
#     single explicit pin (admit without multi-select), the pin is admitted in
#     place and dispatch_explain records that path.
#
# usage-burndown and --admit use quota-axi --json unless --quota-json supplies
# a fixture. FM_DISPATCH_QUOTA_AXI overrides the quota command.
# FM_BURNDOWN_PRESSURE_K overrides the expiry-pressure coefficient (default 4).
# FM_USAGE_BURN_HISTORY overrides the burn-sample history path.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/fm-usage-burndown-lib.sh
. "$SCRIPT_DIR/fm-usage-burndown-lib.sh"

NOW_EPOCH=$(date +%s)
SELECT_OVERRIDE=
QUOTA_JSON_FILE=
ADMIT=0
RESUME_META=
ARGS=()

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

log() {
  printf 'fm-dispatch-select: %s\n' "$*" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --select)
      [ "$#" -gt 1 ] || { echo "error: --select requires a value" >&2; exit 2; }
      SELECT_OVERRIDE=$2
      shift 2
      ;;
    --select=*)
      SELECT_OVERRIDE=${1#--select=}
      shift
      ;;
    --admit)
      ADMIT=1
      shift
      ;;
    --resume-meta)
      [ "$#" -gt 1 ] || { echo "error: --resume-meta requires a file" >&2; exit 2; }
      RESUME_META=$2
      ADMIT=1
      shift 2
      ;;
    --resume-meta=*)
      RESUME_META=${1#--resume-meta=}
      ADMIT=1
      shift
      ;;
    --quota-json)
      [ "$#" -gt 1 ] || { echo "error: --quota-json requires a file" >&2; exit 2; }
      QUOTA_JSON_FILE=$2
      shift 2
      ;;
    --quota-json=*)
      QUOTA_JSON_FILE=${1#--quota-json=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        ARGS+=("$1")
        shift
      done
      ;;
    -*)
      echo "error: unknown option $1" >&2
      exit 2
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

[ "${#ARGS[@]}" -le 1 ] || { echo "error: expected at most one JSON argument" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

meta_value() {
  local file=$1 key=$2
  sed -n "s/^${key}=//p" "$file" 2>/dev/null | tail -1
}

if [ -n "$RESUME_META" ]; then
  [ "${#ARGS[@]}" -eq 0 ] || { echo "error: --resume-meta does not accept dispatch JSON" >&2; exit 2; }
  [ -f "$RESUME_META" ] || { echo "error: resume meta not found: $RESUME_META" >&2; exit 2; }
  resume_harness=$(meta_value "$RESUME_META" harness)
  [ -n "$resume_harness" ] || { echo "error: resume meta has no pinned harness: $RESUME_META" >&2; exit 2; }
  resume_provider=$(meta_value "$RESUME_META" provider)
  [ -n "$resume_provider" ] || resume_provider=$resume_harness
  resume_model=$(meta_value "$RESUME_META" model)
  resume_effort=$(meta_value "$RESUME_META" effort)
  SPEC_JSON=$(jq -cn \
    --arg provider "$resume_provider" \
    --arg harness "$resume_harness" \
    --arg model "${resume_model:-default}" \
    --arg effort "${resume_effort:-default}" \
    '{provider:$provider,harness:$harness,model:$model,effort:$effort}')
else
  if [ "${#ARGS[@]}" -eq 1 ]; then
    SPEC_JSON=${ARGS[0]}
  else
    SPEC_JSON=$(cat)
  fi
fi

profiles_json=$(printf '%s\n' "$SPEC_JSON" | jq -ec '
  (if type == "object" and has("use") then .use else . end)
  | if type == "array" then .
    elif type == "object" then [.]
    else empty
    end
' 2>/dev/null) || { echo "error: dispatch input must be a rule, profile, or profile array" >&2; exit 2; }

profile_count=$(printf '%s\n' "$profiles_json" | jq 'length')
[ "$profile_count" -gt 0 ] || { echo "error: dispatch profile array must not be empty" >&2; exit 2; }

first_profile() {
  printf '%s\n' "$profiles_json" | jq -c '
    def clean($p):
      {harness: $p.harness}
      + (if ($p.model? | type) == "string" then {model: $p.model} else {} end)
      + (if ($p.effort? | type) == "string" then {effort: $p.effort} else {} end);
    clean(.[0])
  '
}

select_strategy=$SELECT_OVERRIDE
if [ -z "$select_strategy" ]; then
  select_strategy=$(printf '%s\n' "$SPEC_JSON" | jq -r '
    if type == "object" and has("use") and (.select? | type) == "string" then .select else "" end
  ' 2>/dev/null || true)
fi

# Normalize strategy aliases.
case "$select_strategy" in
  quota-balanced) select_strategy=usage-burndown ;;
esac

# Legacy path: no multi-select and no admission — first profile, no quota call.
if [ "$select_strategy" != usage-burndown ] && [ "$ADMIT" -eq 0 ]; then
  if [ -n "$select_strategy" ]; then
    log "unknown select strategy '$select_strategy'; using first profile"
  fi
  first_profile
  exit 0
fi

if [ -n "$select_strategy" ] && [ "$select_strategy" != usage-burndown ]; then
  echo "error: unknown select strategy '$select_strategy' cannot be used for admission" >&2
  exit 2
fi

# Multi-select is usage-burndown (including legacy quota-balanced alias).
# Admit-only (single pin / first profile) still scores observation for posture.
mode=admit
if [ "$select_strategy" = usage-burndown ]; then
  mode=multi
fi

recognized_providers_json=$(fm_usage_source_provider_ids | jq -Rsc '
  split("\n") | map(select(length > 0))
')
recognized_providers_csv=$(fm_usage_source_provider_ids_csv)
profile_providers_json=$(printf '%s\n' "$profiles_json" | jq -c '
  [.[] | (.provider // .harness // empty) | select(type == "string" and length > 0)]
  | unique
')
unrecognized_providers_json=$(jq -cn \
  --argjson profiles "$profile_providers_json" \
  --argjson recognized "$recognized_providers_json" \
  '$profiles | map(select(. as $provider | ($recognized | index($provider)) == null))')
if [ "$(printf '%s\n' "$unrecognized_providers_json" | jq 'length')" -gt 0 ]; then
  while IFS= read -r unrecognized_provider; do
    [ -z "$unrecognized_provider" ] || \
      log "error: unrecognized provider token '$unrecognized_provider'; recognized providers: $recognized_providers_csv"
  done < <(printf '%s\n' "$unrecognized_providers_json" | jq -r '.[]')
  printf '%s\n' "$profiles_json" | jq -c \
    --argjson unrecognized "$unrecognized_providers_json" \
    --argjson recognized "$recognized_providers_json" '
    (
      map(
        select(
          (.provider // .harness) as $provider
          | ($unrecognized | index($provider)) != null
        )
      )
      | .[0]
    ) as $profile
    | {
        provider: ($profile.provider // $profile.harness),
        harness: $profile.harness
      }
      + (if ($profile.model? | type) == "string" then {model:$profile.model} else {} end)
      + (if ($profile.effort? | type) == "string" then {effort:$profile.effort} else {} end)
      + {
          provider_recognition:"unrecognized",
          quota_posture:"unknown",
          dispatch_strategy:"usage-burndown",
          dispatch_explain:"unrecognized provider token: \($unrecognized | join(", "))",
          dispatch_error:"unrecognized-provider",
          unrecognized_providers:$unrecognized,
          recognized_providers:$recognized
        }
  '
  exit 64
fi

quota_unavailable() {
  log "$1; retaining selected provider with quota posture unknown"
  # When multi was requested but evidence is wholly unusable, still emit first
  # profile with unknown posture (never silent freeze, never fabricated numbers).
  printf '%s\n' "$profiles_json" | jq -c '
    def clean($p):
      {provider: ($p.provider // $p.harness), harness: $p.harness}
      + (if ($p.model? | type) == "string" then {model: $p.model} else {} end)
      + (if ($p.effort? | type) == "string" then {effort: $p.effort} else {} end);
    clean(.[0]) + {
      provider_recognition:"recognized",
      quota_posture:"unknown",
      dispatch_strategy:"usage-burndown",
      dispatch_explain:"usage evidence unavailable; retained first profile"
    }
  '
  exit 0
}

if [ -n "$QUOTA_JSON_FILE" ]; then
  quota_json=$(cat "$QUOTA_JSON_FILE" 2>/dev/null) || quota_unavailable "cannot read quota JSON"
else
  quota_cmd=${FM_DISPATCH_QUOTA_AXI:-quota-axi}
  command -v "$quota_cmd" >/dev/null 2>&1 || quota_unavailable "quota-axi missing"
  quota_json=$("$quota_cmd" --json 2>/dev/null)
  quota_status=$?
  [ "$quota_status" -eq 0 ] || quota_unavailable "quota-axi exited $quota_status"
fi

printf '%s\n' "$quota_json" | jq -e 'type == "object" and (.providers | type) == "array"' >/dev/null 2>&1 \
  || quota_unavailable "quota-axi returned unparseable JSON"

# Surface non-fresh provider diagnostics for profile providers (observable).
quota_notices=$(printf '%s\n' "$quota_json" | jq -r \
  --argjson profiles "$profiles_json" '
  def one_line: tostring | gsub("[\\r\\n\\t]+"; " ");
  ([$profiles[] | (.provider // .harness)] | unique) as $profile_providers
  | .providers[]?
  | select(.provider as $provider | $profile_providers | index($provider))
  | (.state.status? // "unknown") as $status
  | select($status != "fresh")
  | "provider '\''\(.provider)'\'' quota status is \($status)"
    + (if $status == "stale" then "; cached snapshot refreshed at \(.state.refreshedAt // "unknown" | one_line)" else "" end)
    + (if (.state.error? | type) == "string" then "; refresh error: \(.state.error | one_line)" else "" end)
    + (if (.state.reason? | type) == "string" then "; reason: \(.state.reason | one_line)" else "" end)
    + (if (.state.remedyCommand? | type) == "string" then "; remedy: \(.state.remedyCommand | one_line)" else "" end)
' 2>/dev/null || true)
while IFS= read -r quota_notice; do
  [ -z "$quota_notice" ] || log "$quota_notice"
done <<< "$quota_notices"

observations=$(fm_usage_source_observe_profiles "$profiles_json" "$quota_json" "$NOW_EPOCH") \
  || quota_unavailable "usage source adapters failed"

scored=$(fm_usage_burndown_score_all "$observations") \
  || quota_unavailable "usage burndown scoring failed"

selection=$(fm_usage_burndown_select "$profiles_json" "$scored" "$mode") \
  || quota_unavailable "usage burndown selection failed"

# Inspectable explanation on stderr.
while IFS= read -r explain_line; do
  [ -z "$explain_line" ] || log "$explain_line"
done < <(fm_usage_burndown_format_explain "$selection")

if [ "$(printf '%s\n' "$selection" | jq -r '.frozen')" = true ]; then
  frozen_provider=$(printf '%s\n' "$selection" | jq -r '.provider')
  frozen_used=$(printf '%s\n' "$selection" | jq -r '.used')
  frozen_remaining=$(printf '%s\n' "$selection" | jq -r '.min')
  log "admission refused: provider '$frozen_provider' is freeze at ${frozen_used}% used (general-window minimum ${frozen_remaining}% remaining); keep the selected task/profile and retry after quota clears"
  exit 75
fi

# Record burn sample so B adapts after every scored dispatch with evidence.
fm_usage_burndown_record_choice "$selection" "$NOW_EPOCH"

# Emit profile (unavailable still prints retained profile with unknown posture).
printf '%s\n' "$selection" | jq -c '.profile + {provider_recognition:"recognized"}'
