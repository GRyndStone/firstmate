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
#   - Short rate windows are eligibility gates only. The provider's durable
#     budget window supplies remaining R, time-to-reset T, learned
#     counterfactual burn B, and an observed or reset-history-derived period W.
#     Spendable expiry surplus S = max(0, R - spend_floor - B*T);
#     score = (S/T) * pressure. Highest score wins.
#   - Observational postures remain normal/conserve/protect. Freeze begins when
#     budget remaining reaches FM_BURNDOWN_SPEND_FLOOR (default 5%). An
#     exhausted rate gate or a frozen explicit pin exits 75 without substitution.
#   - Stale-but-current general-window numbers remain usable under adapter rules
#     (refreshedAt/resetsAt prove the window is still current). Stale status is
#     always logged on stderr so cached-vs-live cannot pass unnoticed.
#   - A metered provider whose usage cannot be read is an ERROR, not silent
#     degradation: stderr names the provider and reason with an "error:" line,
#     the profile carries dispatch_error=usage-evidence-unreadable, and when no
#     live scorable candidate remains the selector exits 70. When other live
#     candidates exist, routing continues to the engine winner but still emits
#     the error fields so the decision cannot be mistaken for clean success.
#     Unmetered recognized providers may still report honest unknown evidence.
#   - Missing quota-axi, unparseable meter JSON, and total meter failure refuse
#     with the same usage-evidence-unreadable contract (exit 70), never a silent
#     first-profile retain.
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
#     place and dispatch_explain records that path. Bypass of the engine without
#     an explicit override is refused by fm-spawn.sh, not this selector.
#
# usage-burndown and --admit fetch live usage via
# fm_usage_source_fetch_quota_json (quota-axi --allow-keychain-prompt --json)
# unless --quota-json supplies a fixture. FM_DISPATCH_QUOTA_AXI overrides the
# quota command. The keychain flag is always passed so macOS Claude reads succeed;
# on non-macOS it is a no-op. FM_DISPATCH_NOW_EPOCH overrides the clock for frozen
# fixtures. FM_BURNDOWN_PRESSURE_K overrides the expiry-pressure coefficient
# (default 4). FM_BURNDOWN_SPEND_FLOOR overrides the budget remaining floor
# (default 5). FM_BURNDOWN_RATE_FLOOR overrides the gate exhaustion boundary
# (default 0). FM_USAGE_BURN_HISTORY overrides the burn-sample history path.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/fm-usage-burndown-lib.sh
. "$SCRIPT_DIR/fm-usage-burndown-lib.sh"

NOW_EPOCH=${FM_DISPATCH_NOW_EPOCH:-$(date +%s)}
case "$NOW_EPOCH" in
  ''|*[!0-9]*) echo "error: FM_DISPATCH_NOW_EPOCH must be an integer epoch" >&2; exit 2 ;;
esac
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

# Emit a machine-distinct usage-evidence error profile and exit 70.
# $1 = short reason for stderr; optional $2 = compact JSON array of unreadable provider names.
usage_evidence_error() {
  local reason=$1 unreadable_json=${2:-[]}
  log "error: $reason"
  printf '%s\n' "$profiles_json" | jq -c \
    --arg reason "$reason" \
    --argjson unreadable "$unreadable_json" '
    def clean($p):
      {provider: ($p.provider // $p.harness), harness: $p.harness}
      + (if ($p.model? | type) == "string" then {model: $p.model} else {} end)
      + (if ($p.effort? | type) == "string" then {effort: $p.effort} else {} end);
    ([to_entries[]
      | {
          index:.key,
          provider:(.value.provider // .value.harness),
          harness:.value.harness,
          profile:clean(.value),
          evidence:"unknown",
          scorable:false,
          eligible:true,
          ineligible_reason:null,
          R:null,
          T:null,
          W:null,
          W_source:"missing",
          B:null,
          B_source:"none",
          S:null,
          spendable_surplus:null,
          required_rate:null,
          pressure:null,
          urgency:null,
          score:null,
          posture:"unknown",
          percent_used:null,
          window_id:null,
          binding_reason:null,
          window_roles:[]
        }
    ]) as $rows
    | clean(.[0]) + {
        provider_recognition:"recognized",
        quota_posture:"unknown",
        dispatch_strategy:"usage-burndown",
        dispatch_explain:("usage evidence unreadable: " + $reason),
        dispatch_error:"usage-evidence-unreadable",
        unreadable_providers:$unreadable,
        dispatch_candidates:$rows,
        dispatch_selected_index:0,
        dispatch_tie_break:"profile-order",
        dispatch_order:"score-desc,S-desc,R-desc,T-asc,index-asc"
      }
  '
  exit 70
}

if [ -n "$QUOTA_JSON_FILE" ]; then
  quota_json=$(cat "$QUOTA_JSON_FILE" 2>/dev/null) \
    || usage_evidence_error "cannot read quota JSON file '$QUOTA_JSON_FILE'"
else
  quota_cmd=${FM_DISPATCH_QUOTA_AXI:-quota-axi}
  quota_status=0
  quota_json=$(fm_usage_source_fetch_quota_json "$quota_cmd" 2>/dev/null) || quota_status=$?
  if [ "$quota_status" -eq 127 ]; then
    usage_evidence_error "quota-axi missing; install quota-axi before usage-burndown dispatch"
  fi
  [ "$quota_status" -eq 0 ] \
    || usage_evidence_error "quota-axi exited $quota_status while reading live usage"
  # Live meter path: quota-axi drops rateLimitResetCredits. When codex is a
  # candidate, observe it read-only via the app-server and attach it before
  # scoring (never redeem/consume a reset).
  if printf '%s\n' "$profiles_json" | jq -e '
    [.[] | (.provider // .harness // empty)] | index("codex")
  ' >/dev/null 2>&1; then
    quota_json=$(fm_usage_source_enrich_codex_reset_credits "$quota_json" "$NOW_EPOCH") \
      || usage_evidence_error "failed to observe codex rate-limit reset credits"
  fi
fi

printf '%s\n' "$quota_json" | jq -e 'type == "object" and (.providers | type) == "array"' >/dev/null 2>&1 \
  || usage_evidence_error "quota-axi returned unparseable JSON (expected object with providers array)"

# Surface non-fresh provider diagnostics for profile providers (operator-visible).
# Stale cached snapshots are always named so they cannot be treated as silent live data.
quota_notices=$(printf '%s\n' "$quota_json" | jq -r \
  --argjson profiles "$profiles_json" '
  def one_line: tostring | gsub("[\\r\\n\\t]+"; " ");
  ([$profiles[] | (.provider // .harness)] | unique) as $profile_providers
  | .providers[]?
  | select(.provider as $provider | $profile_providers | index($provider))
  | (.state.status? // "unknown") as $status
  | select($status != "fresh")
  | (if $status == "stale" then "warning: " else "error: " end)
    + "provider '\''\(.provider)'\'' quota status is \($status)"
    + (if $status == "stale" then "; reading cached snapshot refreshed at \(.state.refreshedAt // "unknown" | one_line), not a live refresh" else "" end)
    + (if (.state.error? | type) == "string" then "; refresh error: \(.state.error | one_line)" else "" end)
    + (if (.state.reason? | type) == "string" then "; reason: \(.state.reason | one_line)" else "" end)
    + (if (.state.remedyCommand? | type) == "string" then "; remedy: \(.state.remedyCommand | one_line)" else "" end)
' 2>/dev/null || true)
while IFS= read -r quota_notice; do
  [ -z "$quota_notice" ] || log "$quota_notice"
done <<< "$quota_notices"

observations=$(fm_usage_source_observe_profiles "$profiles_json" "$quota_json" "$NOW_EPOCH") \
  || usage_evidence_error "usage source adapters failed while observing providers"

scored=$(fm_usage_burndown_score_all "$observations") \
  || usage_evidence_error "usage burndown scoring failed"

selection=$(fm_usage_burndown_select "$profiles_json" "$scored" "$mode") \
  || usage_evidence_error "usage burndown selection failed"

# Metered providers with evidence=unknown are read failures (not honest unmetered).
# Collect names and surface one explicit error line per provider with reason text.
unreadable_providers_json='[]'
while IFS= read -r obs_line; do
  [ -n "$obs_line" ] || continue
  obs_provider=$(printf '%s\n' "$obs_line" | jq -r '.provider // empty')
  obs_evidence=$(printf '%s\n' "$obs_line" | jq -r '.evidence // "unknown"')
  [ -n "$obs_provider" ] || continue
  [ "$obs_evidence" = unknown ] || continue
  fm_usage_source_provider_is_metered "$obs_provider" || continue
  obs_reason=$(printf '%s\n' "$obs_line" | jq -r '
    def one_line: tostring | gsub("[\\r\\n\\t]+"; " ");
    ((.diagnostics // []) | map(one_line) | join("; ")) as $diag
    | if ($diag | length) > 0 then $diag else "no usable usage evidence" end
  ')
  log "error: unreadable usage evidence for provider '$obs_provider': $obs_reason"
  unreadable_providers_json=$(jq -cn \
    --argjson acc "$unreadable_providers_json" \
    --arg p "$obs_provider" \
    '$acc + [$p] | unique')
done < <(printf '%s\n' "$observations" | jq -c '.[]')

# Inspectable explanation on stderr.
while IFS= read -r explain_line; do
  [ -z "$explain_line" ] || log "$explain_line"
done < <(fm_usage_burndown_format_explain "$selection")

if [ "$(printf '%s\n' "$selection" | jq -r '.frozen')" = true ]; then
  frozen_provider=$(printf '%s\n' "$selection" | jq -r '.provider')
  frozen_used=$(printf '%s\n' "$selection" | jq -r '.used')
  frozen_remaining=$(printf '%s\n' "$selection" | jq -r '.min')
  block_reason=$(printf '%s\n' "$selection" | jq -r '.block_reason // "budget-spend-floor"')
  if [ "$block_reason" = rate-window-exhausted ]; then
    log "admission refused: provider '$frozen_provider' has no rate-window capacity; keep the selected task/profile and retry after the rate window clears"
  else
    log "admission refused: provider '$frozen_provider' reached the ${FM_BURNDOWN_SPEND_FLOOR}% budget spend floor (${frozen_used}% used, ${frozen_remaining}% remaining); keep the selected task/profile and retry after quota clears"
  fi
  exit 75
fi

unreadable_count=$(printf '%s\n' "$unreadable_providers_json" | jq 'length')
selection_unavailable=$(printf '%s\n' "$selection" | jq -r '.unavailable // false')
chosen_scorable=$(printf '%s\n' "$selection" | jq -r '
  (.candidates // []) as $cands
  | (.profile.dispatch_selected_index // 0) as $idx
  | ([$cands[] | select(.index == $idx)][0].scorable // false)
')

# No live scorable winner while a metered provider failed to read: refuse.
# Partial failure with a live winner continues below with dispatch_error attached.
if [ "$unreadable_count" -gt 0 ] && { [ "$selection_unavailable" = true ] || [ "$chosen_scorable" != true ]; }; then
  unreadable_csv=$(printf '%s\n' "$unreadable_providers_json" | jq -r 'join(", ")')
  usage_evidence_error \
    "metered provider usage unreadable for: $unreadable_csv; refusing dispatch without live evidence" \
    "$unreadable_providers_json"
fi

# Record burn sample so B adapts after every scored dispatch with evidence.
fm_usage_burndown_record_choice "$selection" "$NOW_EPOCH"

# Emit profile. Partial unreadable metered providers keep the live winner but
# attach dispatch_error so the decision is not a clean silent success.
if [ "$unreadable_count" -gt 0 ]; then
  unreadable_csv=$(printf '%s\n' "$unreadable_providers_json" | jq -r 'join(", ")')
  log "error: routing with partial unreadable usage evidence for: $unreadable_csv; live candidates still scored"
  printf '%s\n' "$selection" | jq -c \
    --argjson unreadable "$unreadable_providers_json" \
    --arg csv "$unreadable_csv" '
    .profile as $p
    | $p + {
        provider_recognition:"recognized",
        dispatch_error:"usage-evidence-unreadable",
        unreadable_providers:$unreadable,
        dispatch_explain:(
          (
            if ($p.dispatch_explain | type) == "string" and ($p.dispatch_explain | length) > 0
            then $p.dispatch_explain
            else "usage-burndown"
            end
          )
          + "; ERROR unreadable metered providers: " + $csv
        )
      }
  '
else
  printf '%s\n' "$selection" | jq -c '.profile + {provider_recognition:"recognized"}'
fi
