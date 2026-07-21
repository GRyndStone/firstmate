#!/usr/bin/env bash
# Resolve one already-matched crew-dispatch rule to a concrete profile and,
# when requested, apply provider quota admission to that selected profile.
# Usage:
#   fm-dispatch-select.sh [--select <strategy>] [--admit] [--quota-json <file>] [<rule-or-use-json>]
#   fm-dispatch-select.sh --resume-meta <state/task.meta> [--quota-json <file>]
#
# Input may be a full rule object with `use` and optional `select`, a single
# profile object, or an ordered array of profile objects.
# Output is one compact JSON profile object on stdout.
#
# This header is the single owner of provider quota admission:
#   - `provider` is the quota identity and `harness` is the launch adapter.
#     A profile may state both; provider defaults to harness for compatibility.
#   - Per candidate provider, the minimum percentRemaining across GENERAL
#     windows determines percent used. Claude uses five_hour and seven_day;
#     Codex uses five_hour and weekly. Model-scoped windows are ignored.
#   - Below 60% used the posture is normal, at 60% it is conserve, at 80% it
#     is protect, and at 90% it is freeze. The boundary is inclusive.
#   - Freeze refuses admission with an actionable stderr reason and exit 75.
#     An explicitly admitted profile is checked in place and another candidate
#     is never substituted merely because its provider is frozen.
#   - quota-balanced is deterministic: the candidate with the higher minimum
#     remaining quota wins, and an exact tie between equally trusted candidates
#     uses the first array element. The selected candidate is then admitted;
#     freeze never triggers a second selection pass.
#   - Stale-but-cached general-window numbers are usable only while their
#     refreshedAt and resetsAt timestamps prove they still describe the current
#     five-hour or seven-day window. A fresh candidate wins unless the stale
#     candidate's minimum is at least the stale-clear margin higher (default 20
#     points). Expired or unverifiable stale windows degrade to unavailable.
#   - A provider absent from quota output, or with no usable general windows,
#     is unavailable to quota-balanced selection.
#   - Missing, failed, stale-shape, or malformed quota data stays observable on
#     stderr but cannot prove freeze. New admission therefore retains the
#     selected profile with quota_posture=unknown instead of switching it.
#   - --resume-meta reconstructs only the recorded provider/harness/model/effort
#     pin. It never evaluates candidates or replaces a task, branch, or run.
#     Freeze pauses that pinned provider; once it clears, the same pin is output.
#
# quota-balanced and --admit use quota-axi --json unless --quota-json supplies
# a fixture. FM_DISPATCH_QUOTA_AXI overrides the quota command.
# FM_DISPATCH_STALE_CLEAR_MARGIN overrides the default 20 point stale margin.
set -u

STALE_CLEAR_MARGIN=${FM_DISPATCH_STALE_CLEAR_MARGIN:-20}
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

governed_first_profile() {
  printf '%s\n' "$profiles_json" | jq -c '
    def clean($p):
      {provider: ($p.provider // $p.harness), harness: $p.harness}
      + (if ($p.model? | type) == "string" then {model: $p.model} else {} end)
      + (if ($p.effort? | type) == "string" then {effort: $p.effort} else {} end);
    clean(.[0]) + {quota_posture:"unknown"}
  '
}

select_strategy=$SELECT_OVERRIDE
if [ -z "$select_strategy" ]; then
  select_strategy=$(printf '%s\n' "$SPEC_JSON" | jq -r '
    if type == "object" and has("use") and (.select? | type) == "string" then .select else "" end
  ' 2>/dev/null || true)
fi

if [ "$select_strategy" != quota-balanced ] && [ "$ADMIT" -eq 0 ]; then
  if [ -n "$select_strategy" ]; then
    log "unknown select strategy '$select_strategy'; using first profile"
  fi
  first_profile
  exit 0
fi

if [ -n "$select_strategy" ] && [ "$select_strategy" != quota-balanced ]; then
  echo "error: unknown select strategy '$select_strategy' cannot be used for admission" >&2
  exit 2
fi

quota_unavailable() {
  log "$1; retaining selected provider with quota posture unknown"
  governed_first_profile
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

selection=$(printf '%s\n' "$quota_json" | jq -ec \
  --argjson profiles "$profiles_json" \
  --argjson margin "$STALE_CLEAR_MARGIN" \
  --argjson now "$NOW_EPOCH" \
  --arg strategy "$select_strategy" '
  def clean($p):
    {provider: ($p.provider // $p.harness), harness: $p.harness}
    + (if ($p.model? | type) == "string" then {model: $p.model} else {} end)
    + (if ($p.effort? | type) == "string" then {effort: $p.effort} else {} end);
  def provider_for($provider): [.providers[]? | select(.provider == $provider)][0];
  def general_ids($provider):
    if $provider == "claude" then ["five_hour", "seven_day"]
    elif $provider == "codex" then ["five_hour", "weekly"]
    else []
    end;
  def general_window_seconds($provider; $id):
    if $id == "five_hour" then 18000
    elif ($provider == "claude" and $id == "seven_day")
      or ($provider == "codex" and $id == "weekly") then 604800
    else null
    end;
  def iso_epoch:
    if type != "string" then null
    else try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null
    end;
  def stale_window_is_current($provider; $refreshed; $now):
    (.resetsAt | iso_epoch) as $reset
    | (general_window_seconds($provider; .id)) as $duration
    | ($refreshed != null)
      and ($refreshed <= $now)
      and ($reset != null)
      and ($reset > $now)
      and ($reset > $refreshed)
      and ($duration != null)
      and (($reset - $refreshed) <= $duration);
  def posture($used):
    if $used >= 90 then "freeze"
    elif $used >= 80 then "protect"
    elif $used >= 60 then "conserve"
    else "normal"
    end;
  def candidate_metric($p; $i):
    . as $root
    | ($p.provider // $p.harness // "") as $provider_id
    | ($root | provider_for($provider_id)) as $provider
    | if ($provider == null) or ((general_ids($provider_id) | length) == 0) then empty
      else
        (($provider.state.status? // "") as $status
          | ($provider.state.refreshedAt? | iso_epoch) as $refreshed
          | (($provider.windows // [])
          | map(. as $window
            | select(((general_ids($provider_id) | index($window.id)) != null)
              and (($window.kind? // "") != "model")
              and (($window.percentRemaining? | type) == "number")
              and ($window.percentRemaining >= 0)
              and ($window.percentRemaining <= 100)
              and (($status == "fresh")
                or ($status == "stale" and ($window | stale_window_is_current($provider_id; $refreshed; $now))))))) as $windows
        | if ($windows | length) == 0 then empty
          else
            ($windows | map(.percentRemaining) | min) as $min
            | (100 - $min) as $used
            | {
                index: $i,
                profile: clean($p),
                provider: $provider_id,
                min: $min,
                used: $used,
                posture: posture($used),
                fresh: ($status == "fresh")
              }
          end
        )
      end;
  def better($a; $b):
    if $a == null then $b
    elif $b == null then $a
    elif ($b.min > $a.min) then $b
    elif ($b.min == $a.min and $b.index < $a.index) then $b
    else $a
    end;
  def best_by_min($xs): reduce $xs[] as $x (null; better(.; $x));
  . as $quota_root
  | ([$profiles | to_entries[] | . as $entry | ($quota_root | candidate_metric($entry.value; $entry.key))]) as $candidates
  | (if $strategy == "quota-balanced" then
      if ($candidates | length) == 0 then null
      else
        (best_by_min($candidates | map(select(.fresh)))) as $fresh_best
        | (best_by_min($candidates | map(select(.fresh | not)))) as $stale_best
        | if $fresh_best != null and $stale_best != null then
            if $stale_best.min >= ($fresh_best.min + $margin) then $stale_best else $fresh_best end
          elif $fresh_best != null then $fresh_best
          else $stale_best
          end
      end
    else
      ($candidates | map(select(.index == 0)) | .[0] // null)
    end) as $chosen
  | if $chosen == null then {
      unavailable: true,
      profile: (clean($profiles[0]) + {quota_posture:"unknown"})
    }
    else {
      unavailable: false,
      frozen: ($chosen.posture == "freeze"),
      provider: $chosen.provider,
      used: $chosen.used,
      min: $chosen.min,
      profile: ($chosen.profile + {
        quota_posture: $chosen.posture,
        quota_percent_used: $chosen.used
      })
    }
    end
' 2>/dev/null) || quota_unavailable "quota-axi data could not be evaluated"

if [ "$(printf '%s\n' "$selection" | jq -r '.unavailable')" = true ]; then
  log "no usable quota windows for selected provider; retaining it with quota posture unknown"
  printf '%s\n' "$selection" | jq -c '.profile'
  exit 0
fi

if [ "$(printf '%s\n' "$selection" | jq -r '.frozen')" = true ]; then
  frozen_provider=$(printf '%s\n' "$selection" | jq -r '.provider')
  frozen_used=$(printf '%s\n' "$selection" | jq -r '.used')
  frozen_remaining=$(printf '%s\n' "$selection" | jq -r '.min')
  log "admission refused: provider '$frozen_provider' is freeze at ${frozen_used}% used (general-window minimum ${frozen_remaining}% remaining); keep the selected task/profile and retry after quota clears"
  exit 75
fi

printf '%s\n' "$selection" | jq -c '.profile'
