#!/usr/bin/env bash
# Finite workflow bounds for admitted tasks: budget inheritance, two-attempt
# obstacle caps, deterministic auth preflight, and standing analyst lanes.
#
# This header is the single owner of those contracts. Provider quota admission
# remains bin/fm-dispatch-select.sh; this script extends an already-admitted
# pin so expensive workflows cannot burn unbounded provider turns.
#
# Usage:
#   fm-workflow-bound.sh inherit-budget --parent-meta <file> [--parent-id <id>]
#       [--depth N] [--concurrency N] [--max-turns N]
#       [--provider P] [--harness H] [--model M] [--effort E]
#     Print key=value budget fields for a child (stdout). Child depth is
#     parent depth minus one; concurrency and remaining turns inherit unless
#     overridden. Provider/model/effort/harness pin inherit from the parent
#     when not passed. Exit 1 when parent depth is already 0.
#
#   fm-workflow-bound.sh default-budget [--depth N] [--concurrency N]
#       [--max-turns N] [--provider P] [--harness H] [--model M] [--effort E]
#     Print key=value budget fields for a root task (no parent).
#
#   fm-workflow-bound.sh note-obstacle <task-id> <obstacle-key>
#     Record one attempt against a normalized obstacle key under
#     state/<id>.obstacles. Attempts 1 and 2 exit 0 with "allow: ...".
#     A third (or later) attempt prints needs-decision text, never silently
#     allows another retry, and exits 3.
#
#   fm-workflow-bound.sh obstacle-count <task-id> <obstacle-key>
#     Print the current attempt count for the key (0 if none).
#
#   fm-workflow-bound.sh auth-preflight [--provider <name>] [--harness <name>]
#       [--require-gh]
#     Deterministic credential/auth checks with no model loop. Exit 0 when
#     every required check passes; exit 1 with a single actionable reason on
#     stderr when one fails. Overridable command hooks for tests:
#     FM_AUTH_GH_STATUS_CMD, FM_AUTH_CODEX_CMD, FM_AUTH_CLAUDE_CMD,
#     FM_AUTH_GROK_CMD.
#
#   fm-workflow-bound.sh analyst-checkpoint <task-id> [--summary <text>]
#       [--body-file <path>]
#     Write the next finite checkpoint artifact under
#     data/<id>/checkpoints/NNN.md and print its path. Analysts remain additive;
#     this never opens a dependency edge.
#
#   fm-workflow-bound.sh analyst-idle <task-id> [--reason <text>]
#     Append a model-free paused status line and register a no-op predicate wait
#     so the lane idles without waking a model between checkpoints. Exit 0.
#
#   fm-workflow-bound.sh assert-no-analyst-dependency <consumer-id>
#       [--blocked-by <id>]...
#     Refuse (exit 1) when any blocked-by id's meta records lane_kind=analyst.
#     Implementation and validation lanes must never depend on independent
#     analysts.
#
# Defaults (env overrides):
#   FM_BUDGET_DEFAULT_DEPTH=2
#   FM_BUDGET_DEFAULT_CONCURRENCY=2
#   FM_BUDGET_DEFAULT_MAX_TURNS=40
#   FM_OBSTACLE_MAX_ATTEMPTS=2   # free attempts; (max+1) requires captain
#
# Meta fields this owner writes or expects (on state/<id>.meta):
#   parent_id=, budget_depth=, budget_concurrency=, budget_max_turns=,
#   budget_turns_used=, lane_kind= (optional: analyst|impl|validation|gsd)
# Provider/harness/model/effort remain the admission pin fields on meta.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

DEFAULT_DEPTH=${FM_BUDGET_DEFAULT_DEPTH:-2}
DEFAULT_CONCURRENCY=${FM_BUDGET_DEFAULT_CONCURRENCY:-2}
DEFAULT_MAX_TURNS=${FM_BUDGET_DEFAULT_MAX_TURNS:-40}
OBSTACLE_MAX=${FM_OBSTACLE_MAX_ATTEMPTS:-2}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

meta_value() {
  local file=$1 key=$2
  [ -f "$file" ] || return 0
  sed -n "s/^${key}=//p" "$file" 2>/dev/null | tail -1
}

is_nonneg_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

normalize_obstacle_key() {
  local raw=$1 key
  key=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-' | sed 's/^-//;s/-$//')
  [ -n "$key" ] || key=unnamed
  printf '%s\n' "$key"
}

print_budget_fields() {
  local provider=$1 harness=$2 model=$3 effort=$4 depth=$5 concurrency=$6 max_turns=$7 parent_id=$8 turns_used=$9 lane_kind=${10:-}
  if [ -n "$provider" ]; then printf 'provider=%s\n' "$provider"; fi
  if [ -n "$harness" ]; then printf 'harness=%s\n' "$harness"; fi
  if [ -n "$model" ]; then printf 'model=%s\n' "$model"; fi
  if [ -n "$effort" ]; then printf 'effort=%s\n' "$effort"; fi
  printf 'budget_depth=%s\n' "$depth"
  printf 'budget_concurrency=%s\n' "$concurrency"
  printf 'budget_max_turns=%s\n' "$max_turns"
  printf 'budget_turns_used=%s\n' "$turns_used"
  if [ -n "$parent_id" ]; then printf 'parent_id=%s\n' "$parent_id"; fi
  if [ -n "$lane_kind" ]; then printf 'lane_kind=%s\n' "$lane_kind"; fi
}

cmd_default_budget() {
  local provider='' harness='' model='' effort='' depth=$DEFAULT_DEPTH concurrency=$DEFAULT_CONCURRENCY max_turns=$DEFAULT_MAX_TURNS lane_kind=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --provider) provider=$2; shift 2 ;;
      --provider=*) provider=${1#--provider=}; shift ;;
      --harness) harness=$2; shift 2 ;;
      --harness=*) harness=${1#--harness=}; shift ;;
      --model) model=$2; shift 2 ;;
      --model=*) model=${1#--model=}; shift ;;
      --effort) effort=$2; shift 2 ;;
      --effort=*) effort=${1#--effort=}; shift ;;
      --depth) depth=$2; shift 2 ;;
      --depth=*) depth=${1#--depth=}; shift ;;
      --concurrency) concurrency=$2; shift 2 ;;
      --concurrency=*) concurrency=${1#--concurrency=}; shift ;;
      --max-turns) max_turns=$2; shift 2 ;;
      --max-turns=*) max_turns=${1#--max-turns=}; shift ;;
      --lane-kind) lane_kind=$2; shift 2 ;;
      --lane-kind=*) lane_kind=${1#--lane-kind=}; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "error: unknown default-budget option: $1" >&2; exit 2 ;;
    esac
  done
  is_nonneg_int "$depth" || { echo "error: depth must be a non-negative integer" >&2; exit 2; }
  is_nonneg_int "$concurrency" || { echo "error: concurrency must be a non-negative integer" >&2; exit 2; }
  is_nonneg_int "$max_turns" || { echo "error: max-turns must be a non-negative integer" >&2; exit 2; }
  print_budget_fields "$provider" "$harness" "$model" "$effort" "$depth" "$concurrency" "$max_turns" "" 0 "$lane_kind"
}

cmd_inherit_budget() {
  local parent_meta='' parent_id='' provider='' harness='' model='' effort=''
  local depth_override='' concurrency_override='' max_turns_override='' lane_kind=''
  local p_provider p_harness p_model p_effort p_depth p_concurrency p_max p_used
  local child_depth child_concurrency child_max child_used
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --parent-meta) parent_meta=$2; shift 2 ;;
      --parent-meta=*) parent_meta=${1#--parent-meta=}; shift ;;
      --parent-id) parent_id=$2; shift 2 ;;
      --parent-id=*) parent_id=${1#--parent-id=}; shift ;;
      --provider) provider=$2; shift 2 ;;
      --provider=*) provider=${1#--provider=}; shift ;;
      --harness) harness=$2; shift 2 ;;
      --harness=*) harness=${1#--harness=}; shift ;;
      --model) model=$2; shift 2 ;;
      --model=*) model=${1#--model=}; shift ;;
      --effort) effort=$2; shift 2 ;;
      --effort=*) effort=${1#--effort=}; shift ;;
      --depth) depth_override=$2; shift 2 ;;
      --depth=*) depth_override=${1#--depth=}; shift ;;
      --concurrency) concurrency_override=$2; shift 2 ;;
      --concurrency=*) concurrency_override=${1#--concurrency=}; shift ;;
      --max-turns) max_turns_override=$2; shift 2 ;;
      --max-turns=*) max_turns_override=${1#--max-turns=}; shift ;;
      --lane-kind) lane_kind=$2; shift 2 ;;
      --lane-kind=*) lane_kind=${1#--lane-kind=}; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "error: unknown inherit-budget option: $1" >&2; exit 2 ;;
    esac
  done
  [ -n "$parent_meta" ] || { echo "error: inherit-budget requires --parent-meta" >&2; exit 2; }
  [ -f "$parent_meta" ] || { echo "error: parent meta not found: $parent_meta" >&2; exit 1; }

  p_provider=$(meta_value "$parent_meta" provider)
  p_harness=$(meta_value "$parent_meta" harness)
  p_model=$(meta_value "$parent_meta" model)
  p_effort=$(meta_value "$parent_meta" effort)
  p_depth=$(meta_value "$parent_meta" budget_depth)
  p_concurrency=$(meta_value "$parent_meta" budget_concurrency)
  p_max=$(meta_value "$parent_meta" budget_max_turns)
  p_used=$(meta_value "$parent_meta" budget_turns_used)
  [ -n "$p_depth" ] || p_depth=$DEFAULT_DEPTH
  [ -n "$p_concurrency" ] || p_concurrency=$DEFAULT_CONCURRENCY
  [ -n "$p_max" ] || p_max=$DEFAULT_MAX_TURNS
  [ -n "$p_used" ] || p_used=0
  is_nonneg_int "$p_depth" || { echo "error: parent budget_depth is not a non-negative integer: $p_depth" >&2; exit 1; }
  is_nonneg_int "$p_concurrency" || { echo "error: parent budget_concurrency is not a non-negative integer: $p_concurrency" >&2; exit 1; }
  is_nonneg_int "$p_max" || { echo "error: parent budget_max_turns is not a non-negative integer: $p_max" >&2; exit 1; }
  is_nonneg_int "$p_used" || { echo "error: parent budget_turns_used is not a non-negative integer: $p_used" >&2; exit 1; }

  if [ "$p_depth" -eq 0 ]; then
    echo "error: parent budget_depth is 0; refusing unbounded child spawn" >&2
    exit 1
  fi

  child_depth=$((p_depth - 1))
  [ -z "$depth_override" ] || child_depth=$depth_override
  child_concurrency=${concurrency_override:-$p_concurrency}
  if [ -n "$max_turns_override" ]; then
    child_max=$max_turns_override
  else
    child_max=$((p_max > p_used ? p_max - p_used : 0))
  fi
  child_used=0
  is_nonneg_int "$child_depth" || { echo "error: child depth must be a non-negative integer" >&2; exit 2; }
  is_nonneg_int "$child_concurrency" || { echo "error: child concurrency must be a non-negative integer" >&2; exit 2; }
  is_nonneg_int "$child_max" || { echo "error: child max-turns must be a non-negative integer" >&2; exit 2; }

  [ -n "$provider" ] || provider=$p_provider
  [ -n "$harness" ] || harness=$p_harness
  [ -n "$model" ] || model=$p_model
  [ -n "$effort" ] || effort=$p_effort
  [ -n "$parent_id" ] || parent_id=$(basename "$parent_meta" .meta)

  if [ -z "$lane_kind" ]; then
    case "$(meta_value "$parent_meta" lane_kind)" in
      gsd) lane_kind=gsd ;;
      analyst) lane_kind=analyst ;;
      *)
        case "$(meta_value "$parent_meta" kind)" in
          gsd) lane_kind=gsd ;;
        esac
        ;;
    esac
  fi

  print_budget_fields "$provider" "$harness" "$model" "$effort" \
    "$child_depth" "$child_concurrency" "$child_max" "$parent_id" "$child_used" "$lane_kind"
}

obstacle_file_for() {
  printf '%s/%s.obstacles\n' "$STATE" "$1"
}

read_obstacle_count() {
  local file=$1 key=$2 line k v
  [ -f "$file" ] || { printf '0\n'; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
      *=*)
        k=${line%%=*}
        v=${line#*=}
        if [ "$k" = "$key" ]; then
          is_nonneg_int "$v" || v=0
          printf '%s\n' "$v"
          return 0
        fi
        ;;
    esac
  done < "$file"
  printf '0\n'
}

write_obstacle_count() {
  local file=$1 key=$2 count=$3 tmp k v line
  mkdir -p "$(dirname "$file")"
  tmp="$file.tmp.${BASHPID:-$$}"
  {
    if [ -f "$file" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          ''|\#*) continue ;;
          *=*)
            k=${line%%=*}
            v=${line#*=}
            if [ "$k" = "$key" ]; then
              continue
            fi
            printf '%s=%s\n' "$k" "$v"
            ;;
        esac
      done < "$file"
    fi
    printf '%s=%s\n' "$key" "$count"
  } > "$tmp"
  mv "$tmp" "$file"
}

cmd_obstacle_count() {
  local id=$1 key
  [ -n "$id" ] || { echo "error: obstacle-count requires <task-id> <obstacle-key>" >&2; exit 2; }
  shift
  [ "$#" -ge 1 ] || { echo "error: obstacle-count requires <obstacle-key>" >&2; exit 2; }
  key=$(normalize_obstacle_key "$*")
  read_obstacle_count "$(obstacle_file_for "$id")" "$key"
}

cmd_note_obstacle() {
  local id=$1 key count next file
  [ -n "${1:-}" ] || { echo "error: note-obstacle requires <task-id> <obstacle-key>" >&2; exit 2; }
  shift
  [ "$#" -ge 1 ] || { echo "error: note-obstacle requires <obstacle-key>" >&2; exit 2; }
  key=$(normalize_obstacle_key "$*")
  file=$(obstacle_file_for "$id")
  count=$(read_obstacle_count "$file" "$key")
  next=$((count + 1))
  if [ "$next" -gt "$OBSTACLE_MAX" ]; then
    write_obstacle_count "$file" "$key" "$next"
    printf 'needs-decision: obstacle %s exceeded %s free attempts (attempt %s); captain must authorize another try or change approach\n' \
      "$key" "$OBSTACLE_MAX" "$next"
    exit 3
  fi
  write_obstacle_count "$file" "$key" "$next"
  if [ "$next" -eq "$OBSTACLE_MAX" ]; then
    printf 'allow: attempt %s of %s for obstacle %s; a further attempt requires captain decision\n' \
      "$next" "$OBSTACLE_MAX" "$key"
  else
    printf 'allow: attempt %s of %s for obstacle %s\n' \
      "$next" "$OBSTACLE_MAX" "$key"
  fi
  exit 0
}

run_check() {
  # run_check <label> <command...>
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then
    return 0
  fi
  echo "error: auth-preflight failed: $label" >&2
  return 1
}

cmd_auth_preflight() {
  local provider='' harness='' require_gh=0 target
  local gh_cmd codex_cmd claude_cmd grok_cmd
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --provider) provider=$2; shift 2 ;;
      --provider=*) provider=${1#--provider=}; shift ;;
      --harness) harness=$2; shift 2 ;;
      --harness=*) harness=${1#--harness=}; shift ;;
      --require-gh) require_gh=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "error: unknown auth-preflight option: $1" >&2; exit 2 ;;
    esac
  done
  target=${provider:-$harness}
  [ -n "$target" ] || target=generic

  gh_cmd=${FM_AUTH_GH_STATUS_CMD:-gh auth status}
  codex_cmd=${FM_AUTH_CODEX_CMD:-codex login status}
  claude_cmd=${FM_AUTH_CLAUDE_CMD:-claude auth status}
  grok_cmd=${FM_AUTH_GROK_CMD:-true}

  if [ "$require_gh" -eq 1 ] || [ "$target" = generic ]; then
    # shellcheck disable=SC2086 # intentional word-split of overridable command strings
    run_check "GitHub CLI not authenticated (run: gh auth login)" $gh_cmd || exit 1
  fi

  case "$target" in
    codex|openai)
      # shellcheck disable=SC2086
      run_check "Codex auth missing or unusable (run provider login; do not spawn an agent to re-auth)" $codex_cmd || exit 1
      ;;
    claude|anthropic)
      if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        :
      else
        # shellcheck disable=SC2086
        run_check "Claude auth missing or unusable (set CLAUDE_CODE_OAUTH_TOKEN or run claude auth login)" $claude_cmd || exit 1
      fi
      ;;
    grok|xai)
      # shellcheck disable=SC2086
      run_check "Grok auth missing or unusable" $grok_cmd || exit 1
      ;;
    generic)
      ;;
    *)
      # Unknown provider: only the optional gh check above applies.
      ;;
  esac
  printf 'ok: auth-preflight passed for %s\n' "$target"
}

cmd_analyst_checkpoint() {
  local id=$1 summary='' body_file='' dir next path n
  shift || true
  [ -n "$id" ] || { echo "error: analyst-checkpoint requires <task-id>" >&2; exit 2; }
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --summary) summary=$2; shift 2 ;;
      --summary=*) summary=${1#--summary=}; shift ;;
      --body-file) body_file=$2; shift 2 ;;
      --body-file=*) body_file=${1#--body-file=}; shift ;;
      *) echo "error: unknown analyst-checkpoint option: $1" >&2; exit 2 ;;
    esac
  done
  dir="$DATA/$id/checkpoints"
  mkdir -p "$dir"
  next=1
  if ls "$dir"/*.md >/dev/null 2>&1; then
    n=$(find "$dir" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')
    next=$((n + 1))
  fi
  path=$(printf '%s/%03d.md' "$dir" "$next")
  {
    printf '# Analyst checkpoint %03d\n' "$next"
    printf '\n'
    printf 'task: %s\n' "$id"
    printf 'written_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'lane_kind: analyst\n'
    printf 'additive: true\n'
    printf 'blocks_implementation: false\n'
    printf '\n'
    if [ -n "$summary" ]; then
      printf '## Summary\n\n%s\n\n' "$summary"
    fi
    if [ -n "$body_file" ]; then
      [ -f "$body_file" ] || { echo "error: body file not found: $body_file" >&2; exit 1; }
      printf '## Body\n\n'
      cat "$body_file"
      printf '\n'
    fi
  } > "$path"
  # Ensure meta records additive analyst lane when present.
  if [ -f "$STATE/$id.meta" ]; then
    if ! grep -q '^lane_kind=' "$STATE/$id.meta" 2>/dev/null; then
      printf 'lane_kind=analyst\n' >> "$STATE/$id.meta"
    fi
  fi
  printf '%s\n' "$path"
}

cmd_analyst_idle() {
  local id=$1 reason="analyst idle between checkpoints (model-free)" pred
  shift || true
  [ -n "$id" ] || { echo "error: analyst-idle requires <task-id>" >&2; exit 2; }
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) reason=$2; shift 2 ;;
      --reason=*) reason=${1#--reason=}; shift ;;
      *) echo "error: unknown analyst-idle option: $1" >&2; exit 2 ;;
    esac
  done
  mkdir -p "$STATE" "$DATA/$id"
  if [ ! -f "$STATE/$id.meta" ]; then
    {
      printf 'kind=scout\n'
      printf 'lane_kind=analyst\n'
      printf 'harness=none\n'
    } > "$STATE/$id.meta"
  elif ! grep -q '^lane_kind=' "$STATE/$id.meta" 2>/dev/null; then
    printf 'lane_kind=analyst\n' >> "$STATE/$id.meta"
  fi
  # Model-free always-pending predicate: exit 1 means still waiting; no model wake.
  pred="$DATA/$id/idle-predicate.sh"
  cat > "$pred" <<'SH'
#!/usr/bin/env bash
# Always-pending model-free idle predicate for standing analyst lanes.
# Exit 1 + empty stdout = still idle between checkpoints (not complete).
exit 1
SH
  chmod +x "$pred"
  if [ -x "$FM_ROOT/bin/fm-external-wait.sh" ] && [ -f "$STATE/$id.meta" ]; then
    FM_STATE_OVERRIDE="$STATE" "$FM_ROOT/bin/fm-external-wait.sh" register-predicate "$id" "$pred" \
      "analyst model-free idle" >/dev/null 2>&1 || true
  fi
  printf 'paused: %s\n' "$reason" >> "$STATE/$id.status"
  printf 'ok: analyst %s idling model-free\n' "$id"
}

cmd_assert_no_analyst_dependency() {
  local consumer=$1 dep meta lane kind
  shift || true
  [ -n "$consumer" ] || { echo "error: assert-no-analyst-dependency requires <consumer-id>" >&2; exit 2; }
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --blocked-by)
        dep=$2
        shift 2
        meta="$STATE/$dep.meta"
        if [ -f "$meta" ]; then
          lane=$(meta_value "$meta" lane_kind)
          kind=$(meta_value "$meta" kind)
          if [ "$lane" = analyst ] || [ "$kind" = analyst ]; then
            echo "error: implementation/validation lane '$consumer' must not depend on analyst '$dep' (analysts are additive only)" >&2
            exit 1
          fi
        fi
        ;;
      --blocked-by=*)
        dep=${1#--blocked-by=}
        shift
        meta="$STATE/$dep.meta"
        if [ -f "$meta" ]; then
          lane=$(meta_value "$meta" lane_kind)
          kind=$(meta_value "$meta" kind)
          if [ "$lane" = analyst ] || [ "$kind" = analyst ]; then
            echo "error: implementation/validation lane '$consumer' must not depend on analyst '$dep' (analysts are additive only)" >&2
            exit 1
          fi
        fi
        ;;
      *) echo "error: unknown assert-no-analyst-dependency option: $1" >&2; exit 2 ;;
    esac
  done
  printf 'ok: no analyst dependencies for %s\n' "$consumer"
}

cmd=${1:-}
[ -n "$cmd" ] || { usage >&2; exit 2; }
shift || true

case "$cmd" in
  -h|--help) usage; exit 0 ;;
  inherit-budget) cmd_inherit_budget "$@" ;;
  default-budget) cmd_default_budget "$@" ;;
  note-obstacle)
    [ "$#" -ge 2 ] || { echo "error: note-obstacle requires <task-id> <obstacle-key>" >&2; exit 2; }
    cmd_note_obstacle "$@"
    ;;
  obstacle-count)
    [ "$#" -ge 2 ] || { echo "error: obstacle-count requires <task-id> <obstacle-key>" >&2; exit 2; }
    cmd_obstacle_count "$@"
    ;;
  auth-preflight) cmd_auth_preflight "$@" ;;
  analyst-checkpoint)
    [ "$#" -ge 1 ] || { echo "error: analyst-checkpoint requires <task-id>" >&2; exit 2; }
    cmd_analyst_checkpoint "$@"
    ;;
  analyst-idle)
    [ "$#" -ge 1 ] || { echo "error: analyst-idle requires <task-id>" >&2; exit 2; }
    cmd_analyst_idle "$@"
    ;;
  assert-no-analyst-dependency)
    [ "$#" -ge 1 ] || { echo "error: assert-no-analyst-dependency requires <consumer-id>" >&2; exit 2; }
    cmd_assert_no_analyst_dependency "$@"
    ;;
  *)
    echo "error: unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
