#!/usr/bin/env bash
# Primary session compaction and rotation controls (usage-burn Layer 4).
#
# This header is the single owner of primary-session lifecycle thresholds,
# counter state, rotation handoff inventory, and restart-preservation checks.
# Quiet monitoring stays model-free: callers record counters and evaluate in
# shell; at most one durable wake is queued per distinct compact/rotate
# recommendation (deduped by action).
#
# Usage:
#   fm-session-lifecycle.sh ensure
#     Create state/.primary-session if missing; print session_id.
#
#   fm-session-lifecycle.sh status
#     Print key=value session counters and resolved thresholds.
#
#   fm-session-lifecycle.sh thresholds
#     Print resolved compact/rotate thresholds only.
#
#   fm-session-lifecycle.sh record-traffic <bytes>
#   fm-session-lifecycle.sh record-turn [<n>]
#   fm-session-lifecycle.sh record-forced-continuation [<n>]
#     Mutate counters (non-negative integers). Prints updated evaluate line.
#
#   fm-session-lifecycle.sh evaluate [--queue-wake]
#     Model-free classification. Prints one line:
#       action=ok|compact|rotate reasons=... session_id=... ...
#     Rotate wins over compact when both would apply.
#     With --queue-wake, enqueue at most one check-kind durable wake when the
#     action is compact|rotate and differs from the last queued action.
#
#   fm-session-lifecycle.sh mark-compacted [--reason <text>]
#     After a successful compact: reset since-compact counters; keep session.
#
#   fm-session-lifecycle.sh write-handoff [--reason <text>]
#     Snapshot durable supervisor inventory to state/.session-handoff and a
#     human summary at data/session-handoff.md for stow/session-start.
#     Inventory: direct reports, queued wakes, open decisions, scheduled
#     rechecks (external waits).
#
#   fm-session-lifecycle.sh show-handoff
#     Print the machine handoff file (or ABSENT).
#
#   fm-session-lifecycle.sh verify-preservation [--against <handoff-file>]
#     Prove live state still contains every handoff inventory entry.
#     Exit 0 when preserved; exit 1 with missing items on stderr.
#
#   fm-session-lifecycle.sh begin-session [--reason <text>]
#     After rotation: write handoff if missing, then start a fresh session
#     record (new session_id, zeroed counters). Does not tear down reports.
#
# Defaults (env or config/session-lifecycle key=value, env wins):
#   FM_COMPACT_TRAFFIC_BYTES=50000000          # ~50M raw traffic
#   FM_COMPACT_TURN_CAP=80                    # configurable turn cap
#   FM_ROTATE_TRAFFIC_BYTES=100000000          # ~100M raw traffic
#   FM_ROTATE_MAX_AGE_SECS=14400              # four hours
#   FM_ROTATE_FORCED_CONTINUATIONS=3
#
# State files:
#   state/.primary-session     schema fm-primary-session.v1
#   state/.session-handoff     schema fm-session-handoff.v1
#   data/session-handoff.md    human summary for stow / session-start
#
# Docs: docs/configuration.md "Primary session lifecycle".
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

SESSION_FILE="$STATE/.primary-session"
HANDOFF_FILE="$STATE/.session-handoff"
HANDOFF_MD="$DATA/session-handoff.md"

# shellcheck source=bin/fm-task-identity-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-task-identity-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

is_nonneg_int() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

session_value() {
  local key=$1 file=${2:-$SESSION_FILE}
  [ -f "$file" ] || return 0
  sed -n "s/^${key}=//p" "$file" 2>/dev/null | tail -1
}

load_config_file() {
  local file="$CONFIG/session-lifecycle" line key value
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      compact_traffic_bytes|FM_COMPACT_TRAFFIC_BYTES)
        [ -n "${FM_COMPACT_TRAFFIC_BYTES+x}" ] || FM_COMPACT_TRAFFIC_BYTES=$value
        ;;
      compact_turn_cap|FM_COMPACT_TURN_CAP)
        [ -n "${FM_COMPACT_TURN_CAP+x}" ] || FM_COMPACT_TURN_CAP=$value
        ;;
      rotate_traffic_bytes|FM_ROTATE_TRAFFIC_BYTES)
        [ -n "${FM_ROTATE_TRAFFIC_BYTES+x}" ] || FM_ROTATE_TRAFFIC_BYTES=$value
        ;;
      rotate_max_age_secs|FM_ROTATE_MAX_AGE_SECS)
        [ -n "${FM_ROTATE_MAX_AGE_SECS+x}" ] || FM_ROTATE_MAX_AGE_SECS=$value
        ;;
      rotate_forced_continuations|FM_ROTATE_FORCED_CONTINUATIONS)
        [ -n "${FM_ROTATE_FORCED_CONTINUATIONS+x}" ] || FM_ROTATE_FORCED_CONTINUATIONS=$value
        ;;
    esac
  done < "$file"
}

resolve_thresholds() {
  load_config_file
  COMPACT_TRAFFIC=${FM_COMPACT_TRAFFIC_BYTES:-50000000}
  COMPACT_TURNS=${FM_COMPACT_TURN_CAP:-80}
  ROTATE_TRAFFIC=${FM_ROTATE_TRAFFIC_BYTES:-100000000}
  ROTATE_AGE=${FM_ROTATE_MAX_AGE_SECS:-14400}
  ROTATE_FORCED=${FM_ROTATE_FORCED_CONTINUATIONS:-3}
  is_nonneg_int "$COMPACT_TRAFFIC" || COMPACT_TRAFFIC=50000000
  is_nonneg_int "$COMPACT_TURNS" || COMPACT_TURNS=80
  is_nonneg_int "$ROTATE_TRAFFIC" || ROTATE_TRAFFIC=100000000
  is_nonneg_int "$ROTATE_AGE" || ROTATE_AGE=14400
  is_nonneg_int "$ROTATE_FORCED" || ROTATE_FORCED=3
  # Zero means "disabled" for that axis; keep as 0.
}

now_epoch() {
  date +%s
}

write_session_file() {
  local tmp
  mkdir -p "$STATE"
  tmp="$SESSION_FILE.tmp.$$"
  {
    printf 'schema=fm-primary-session.v1\n'
    printf 'session_id=%s\n' "$SESSION_ID"
    printf 'started_at=%s\n' "$STARTED_AT"
    printf 'traffic_bytes=%s\n' "$TRAFFIC_BYTES"
    printf 'traffic_since_compact=%s\n' "$TRAFFIC_SINCE_COMPACT"
    printf 'turns=%s\n' "$TURNS"
    printf 'turns_since_compact=%s\n' "$TURNS_SINCE_COMPACT"
    printf 'forced_continuations=%s\n' "$FORCED_CONTINUATIONS"
    printf 'compact_count=%s\n' "$COMPACT_COUNT"
    printf 'last_compact_at=%s\n' "${LAST_COMPACT_AT:-}"
    printf 'last_action=%s\n' "${LAST_ACTION:-}"
    printf 'last_action_reason=%s\n' "${LAST_ACTION_REASON:-}"
    printf 'last_action_at=%s\n' "${LAST_ACTION_AT:-}"
    printf 'last_queued_action=%s\n' "${LAST_QUEUED_ACTION:-}"
    printf 'last_queued_at=%s\n' "${LAST_QUEUED_AT:-}"
  } > "$tmp"
  mv "$tmp" "$SESSION_FILE"
}

load_session() {
  SESSION_ID=$(session_value session_id)
  STARTED_AT=$(session_value started_at)
  TRAFFIC_BYTES=$(session_value traffic_bytes)
  TRAFFIC_SINCE_COMPACT=$(session_value traffic_since_compact)
  TURNS=$(session_value turns)
  TURNS_SINCE_COMPACT=$(session_value turns_since_compact)
  FORCED_CONTINUATIONS=$(session_value forced_continuations)
  COMPACT_COUNT=$(session_value compact_count)
  LAST_COMPACT_AT=$(session_value last_compact_at)
  LAST_ACTION=$(session_value last_action)
  LAST_ACTION_REASON=$(session_value last_action_reason)
  LAST_ACTION_AT=$(session_value last_action_at)
  LAST_QUEUED_ACTION=$(session_value last_queued_action)
  LAST_QUEUED_AT=$(session_value last_queued_at)

  is_nonneg_int "${TRAFFIC_BYTES:-}" || TRAFFIC_BYTES=0
  is_nonneg_int "${TRAFFIC_SINCE_COMPACT:-}" || TRAFFIC_SINCE_COMPACT=0
  is_nonneg_int "${TURNS:-}" || TURNS=0
  is_nonneg_int "${TURNS_SINCE_COMPACT:-}" || TURNS_SINCE_COMPACT=0
  is_nonneg_int "${FORCED_CONTINUATIONS:-}" || FORCED_CONTINUATIONS=0
  is_nonneg_int "${COMPACT_COUNT:-}" || COMPACT_COUNT=0
  is_nonneg_int "${STARTED_AT:-}" || STARTED_AT=
}

cmd_ensure() {
  local now
  mkdir -p "$STATE"
  if [ -f "$SESSION_FILE" ]; then
    load_session
    if [ -n "$SESSION_ID" ] && [ -n "$STARTED_AT" ]; then
      printf '%s\n' "$SESSION_ID"
      return 0
    fi
  fi
  now=$(now_epoch)
  SESSION_ID=$(fm_task_identity_new_token 2>/dev/null || printf 'sess-%s' "$now")
  STARTED_AT=$now
  TRAFFIC_BYTES=0
  TRAFFIC_SINCE_COMPACT=0
  TURNS=0
  TURNS_SINCE_COMPACT=0
  FORCED_CONTINUATIONS=0
  COMPACT_COUNT=0
  LAST_COMPACT_AT=
  LAST_ACTION=ok
  LAST_ACTION_REASON=session-started
  LAST_ACTION_AT=$now
  LAST_QUEUED_ACTION=
  LAST_QUEUED_AT=
  write_session_file
  printf '%s\n' "$SESSION_ID"
}

cmd_thresholds() {
  resolve_thresholds
  printf 'compact_traffic_bytes=%s\n' "$COMPACT_TRAFFIC"
  printf 'compact_turn_cap=%s\n' "$COMPACT_TURNS"
  printf 'rotate_traffic_bytes=%s\n' "$ROTATE_TRAFFIC"
  printf 'rotate_max_age_secs=%s\n' "$ROTATE_AGE"
  printf 'rotate_forced_continuations=%s\n' "$ROTATE_FORCED"
}

print_status_body() {
  local now age=0
  resolve_thresholds
  load_session
  now=$(now_epoch)
  if is_nonneg_int "${STARTED_AT:-}"; then
    age=$((now - STARTED_AT))
    [ "$age" -ge 0 ] || age=0
  fi
  printf 'schema=fm-primary-session.v1\n'
  printf 'session_id=%s\n' "${SESSION_ID:-}"
  printf 'started_at=%s\n' "${STARTED_AT:-}"
  printf 'age_secs=%s\n' "$age"
  printf 'traffic_bytes=%s\n' "${TRAFFIC_BYTES:-0}"
  printf 'traffic_since_compact=%s\n' "${TRAFFIC_SINCE_COMPACT:-0}"
  printf 'turns=%s\n' "${TURNS:-0}"
  printf 'turns_since_compact=%s\n' "${TURNS_SINCE_COMPACT:-0}"
  printf 'forced_continuations=%s\n' "${FORCED_CONTINUATIONS:-0}"
  printf 'compact_count=%s\n' "${COMPACT_COUNT:-0}"
  printf 'last_compact_at=%s\n' "${LAST_COMPACT_AT:-}"
  printf 'last_action=%s\n' "${LAST_ACTION:-}"
  printf 'last_action_reason=%s\n' "${LAST_ACTION_REASON:-}"
  printf 'last_queued_action=%s\n' "${LAST_QUEUED_ACTION:-}"
  cmd_thresholds
}

cmd_status() {
  cmd_ensure >/dev/null
  print_status_body
}

# evaluate_into ACTION_VAR REASONS_VAR — sets caller's named vars; no print.
# Locals here must not reuse the caller's variable names (bash dynamic scope).
evaluate_into() {
  local _action_var=$1 _reasons_var=$2
  local now age=0 _reasons=() _action=ok joined
  resolve_thresholds
  load_session
  now=$(now_epoch)
  if is_nonneg_int "${STARTED_AT:-}"; then
    age=$((now - STARTED_AT))
    [ "$age" -ge 0 ] || age=0
  fi

  # Rotate axes (any one trips). Zero threshold disables that axis.
  if [ "$ROTATE_FORCED" -gt 0 ] && [ "${FORCED_CONTINUATIONS:-0}" -ge "$ROTATE_FORCED" ]; then
    _action=rotate
    _reasons+=("forced_continuations=${FORCED_CONTINUATIONS}>=${ROTATE_FORCED}")
  fi
  if [ "$ROTATE_TRAFFIC" -gt 0 ] && [ "${TRAFFIC_BYTES:-0}" -ge "$ROTATE_TRAFFIC" ]; then
    _action=rotate
    _reasons+=("traffic_bytes=${TRAFFIC_BYTES}>=${ROTATE_TRAFFIC}")
  fi
  if [ "$ROTATE_AGE" -gt 0 ] && [ "$age" -ge "$ROTATE_AGE" ]; then
    _action=rotate
    _reasons+=("age_secs=${age}>=${ROTATE_AGE}")
  fi

  if [ "$_action" = ok ]; then
    if [ "$COMPACT_TRAFFIC" -gt 0 ] && [ "${TRAFFIC_SINCE_COMPACT:-0}" -ge "$COMPACT_TRAFFIC" ]; then
      _action=compact
      _reasons+=("traffic_since_compact=${TRAFFIC_SINCE_COMPACT}>=${COMPACT_TRAFFIC}")
    fi
    if [ "$COMPACT_TURNS" -gt 0 ] && [ "${TURNS_SINCE_COMPACT:-0}" -ge "$COMPACT_TURNS" ]; then
      _action=compact
      _reasons+=("turns_since_compact=${TURNS_SINCE_COMPACT}>=${COMPACT_TURNS}")
    fi
  fi

  if [ "${#_reasons[@]}" -eq 0 ]; then
    _reasons=("under-thresholds")
  fi

  joined=$(IFS=,; printf '%s' "${_reasons[*]}")
  printf -v "$_action_var" '%s' "$_action"
  printf -v "$_reasons_var" '%s' "$joined"
}

print_evaluate_line() {
  local action=$1 reasons=$2 now age=0
  now=$(now_epoch)
  if is_nonneg_int "${STARTED_AT:-}"; then
    age=$((now - STARTED_AT))
    [ "$age" -ge 0 ] || age=0
  fi
  printf 'action=%s reasons=%s session_id=%s traffic_bytes=%s traffic_since_compact=%s turns=%s turns_since_compact=%s forced_continuations=%s age_secs=%s\n' \
    "$action" "$reasons" "${SESSION_ID:-}" "${TRAFFIC_BYTES:-0}" \
    "${TRAFFIC_SINCE_COMPACT:-0}" "${TURNS:-0}" "${TURNS_SINCE_COMPACT:-0}" \
    "${FORCED_CONTINUATIONS:-0}" "$age"
}

persist_last_action() {
  local action=$1 reasons=$2
  LAST_ACTION=$action
  LAST_ACTION_REASON=$reasons
  LAST_ACTION_AT=$(now_epoch)
  write_session_file
}

maybe_queue_wake() {
  local action=$1 reasons=$2
  case "$action" in
    compact|rotate) ;;
    *) return 0 ;;
  esac
  [ "$action" = "${LAST_QUEUED_ACTION:-}" ] && return 0

  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
  FM_WAKE_QUEUE_LOCK="${FM_WAKE_QUEUE_LOCK:-$STATE/.wake-queue.lock}"
  mkdir -p "$STATE"
  fm_wake_append check "session-lifecycle" \
    "session-lifecycle action=${action} reasons=${reasons} session_id=${SESSION_ID:-}"
  LAST_QUEUED_ACTION=$action
  LAST_QUEUED_AT=$(now_epoch)
  write_session_file
}

cmd_evaluate() {
  local queue=0 action reasons
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --queue-wake) queue=1; shift ;;
      *) echo "error: unknown evaluate flag: $1" >&2; exit 2 ;;
    esac
  done
  cmd_ensure >/dev/null
  evaluate_into action reasons
  persist_last_action "$action" "$reasons"
  if [ "$queue" -eq 1 ]; then
    maybe_queue_wake "$action" "$reasons"
  fi
  print_evaluate_line "$action" "$reasons"
}

bump_int() {
  local cur=$1 add=$2
  is_nonneg_int "$cur" || cur=0
  is_nonneg_int "$add" || return 1
  printf '%s\n' "$((cur + add))"
}

cmd_record_traffic() {
  local bytes=${1:-} action reasons
  is_nonneg_int "$bytes" || { echo "error: record-traffic requires non-negative integer bytes" >&2; exit 2; }
  cmd_ensure >/dev/null
  load_session
  TRAFFIC_BYTES=$(bump_int "$TRAFFIC_BYTES" "$bytes")
  TRAFFIC_SINCE_COMPACT=$(bump_int "$TRAFFIC_SINCE_COMPACT" "$bytes")
  write_session_file
  evaluate_into action reasons
  persist_last_action "$action" "$reasons"
  print_evaluate_line "$action" "$reasons"
}

cmd_record_turn() {
  local n=${1:-1} action reasons
  is_nonneg_int "$n" || { echo "error: record-turn requires non-negative integer" >&2; exit 2; }
  cmd_ensure >/dev/null
  load_session
  TURNS=$(bump_int "$TURNS" "$n")
  TURNS_SINCE_COMPACT=$(bump_int "$TURNS_SINCE_COMPACT" "$n")
  write_session_file
  evaluate_into action reasons
  persist_last_action "$action" "$reasons"
  print_evaluate_line "$action" "$reasons"
}

cmd_record_forced() {
  local n=${1:-1} action reasons
  is_nonneg_int "$n" || { echo "error: record-forced-continuation requires non-negative integer" >&2; exit 2; }
  cmd_ensure >/dev/null
  load_session
  FORCED_CONTINUATIONS=$(bump_int "$FORCED_CONTINUATIONS" "$n")
  write_session_file
  evaluate_into action reasons
  persist_last_action "$action" "$reasons"
  print_evaluate_line "$action" "$reasons"
}

cmd_mark_compacted() {
  local reason=manual action reasons
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) reason=$2; shift 2 ;;
      --reason=*) reason=${1#--reason=}; shift ;;
      *) echo "error: unknown mark-compacted flag: $1" >&2; exit 2 ;;
    esac
  done
  cmd_ensure >/dev/null
  load_session
  TRAFFIC_SINCE_COMPACT=0
  TURNS_SINCE_COMPACT=0
  COMPACT_COUNT=$((COMPACT_COUNT + 1))
  LAST_COMPACT_AT=$(now_epoch)
  LAST_QUEUED_ACTION=
  LAST_QUEUED_AT=
  write_session_file
  evaluate_into action reasons
  persist_last_action "$action" "compacted:${reason};${reasons}"
  print_evaluate_line "$action" "compacted:${reason}"
}

# --- handoff inventory -------------------------------------------------------

clean_field() {
  LC_ALL=C tr '\t\r\n' '   ' | sed 's/  */ /g; s/^ //; s/ $//'
}

last_status_line() {
  local id=$1
  local f="$STATE/$id.status"
  [ -f "$f" ] || return 0
  tail -n 1 "$f" 2>/dev/null || true
}

meta_field() {
  local meta=$1 key=$2
  sed -n "s/^${key}=//p" "$meta" 2>/dev/null | tail -1
}

cmd_write_handoff() {
  local reason=manual now tmp md_tmp reports=0 wakes=0 decisions=0 rechecks=0
  local id meta line waitf kind desc role
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) reason=$2; shift 2 ;;
      --reason=*) reason=${1#--reason=}; shift ;;
      *) echo "error: unknown write-handoff flag: $1" >&2; exit 2 ;;
    esac
  done
  cmd_ensure >/dev/null
  load_session
  now=$(now_epoch)
  mkdir -p "$STATE" "$DATA"
  tmp="$HANDOFF_FILE.tmp.$$"
  md_tmp="$HANDOFF_MD.tmp.$$"

  {
    printf 'schema=fm-session-handoff.v1\n'
    printf 'written_at=%s\n' "$now"
    printf 'from_session_id=%s\n' "${SESSION_ID:-}"
    printf 'reason=%s\n' "$(printf '%s' "$reason" | clean_field)"
    printf 'traffic_bytes=%s\n' "${TRAFFIC_BYTES:-0}"
    printf 'forced_continuations=%s\n' "${FORCED_CONTINUATIONS:-0}"
    printf '\n[direct_reports]\n'
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      printf '%s|%s|%s|%s|%s\n' \
        "$id" \
        "$(meta_field "$meta" kind | clean_field)" \
        "$(meta_field "$meta" window | clean_field)" \
        "$(meta_field "$meta" project | clean_field)" \
        "$(meta_field "$meta" harness | clean_field)"
      reports=$((reports + 1))
    done
    printf '\n[queued_wakes]\n'
    if [ -f "$STATE/.wake-queue" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        printf '%s\n' "$line"
        wakes=$((wakes + 1))
      done < "$STATE/.wake-queue"
    fi
    printf '\n[decisions]\n'
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      line=$(last_status_line "$id")
      case "$line" in
        needs-decision:*|blocked:*)
          printf '%s|%s\n' "$id" "$(printf '%s' "$line" | clean_field)"
          decisions=$((decisions + 1))
          ;;
      esac
    done
    printf '\n[scheduled_rechecks]\n'
    for waitf in "$STATE"/*.wait; do
      [ -f "$waitf" ] || continue
      id=$(basename "$waitf" .wait)
      kind=$(sed -n 's/^kind=//p' "$waitf" 2>/dev/null | tail -1)
      desc=$(sed -n 's/^description=//p' "$waitf" 2>/dev/null | tail -1)
      role=$(sed -n 's/^role=//p' "$waitf" 2>/dev/null | tail -1)
      printf '%s|%s|%s|%s\n' \
        "$id" \
        "$(printf '%s' "${kind:-}" | clean_field)" \
        "$(printf '%s' "${desc:-}" | clean_field)" \
        "$(printf '%s' "${role:-}" | clean_field)"
      rechecks=$((rechecks + 1))
    done
    printf '\n[counts]\n'
    printf 'direct_reports=%s\n' "$reports"
    printf 'queued_wakes=%s\n' "$wakes"
    printf 'decisions=%s\n' "$decisions"
    printf 'scheduled_rechecks=%s\n' "$rechecks"
  } > "$tmp"
  mv "$tmp" "$HANDOFF_FILE"

  {
    printf '# Session handoff\n\n'
    printf 'Written: %s (epoch %s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" "$now"
    printf 'From session: %s\n' "${SESSION_ID:-unknown}"
    printf 'Reason: %s\n\n' "$reason"
    printf '## Inventory counts\n\n'
    printf -- '- Direct reports: %s\n' "$reports"
    printf -- '- Queued wakes: %s\n' "$wakes"
    printf -- '- Open decisions/blockers: %s\n' "$decisions"
    printf -- '- Scheduled rechecks (external waits): %s\n\n' "$rechecks"
    printf 'Machine inventory: state/.session-handoff (schema fm-session-handoff.v1).\n'
    printf 'Verify after restart: bin/fm-session-lifecycle.sh verify-preservation.\n'
  } > "$md_tmp"
  mv "$md_tmp" "$HANDOFF_MD"

  printf 'handoff=%s reports=%s wakes=%s decisions=%s rechecks=%s\n' \
    "$HANDOFF_FILE" "$reports" "$wakes" "$decisions" "$rechecks"
}

cmd_show_handoff() {
  if [ -f "$HANDOFF_FILE" ]; then
    cat "$HANDOFF_FILE"
  else
    printf 'ABSENT\n'
    return 0
  fi
}

cmd_verify_preservation() {
  local against=$HANDOFF_FILE section='' missing=0 line id rest wake_line found
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --against) against=$2; shift 2 ;;
      --against=*) against=${1#--against=}; shift ;;
      *) echo "error: unknown verify-preservation flag: $1" >&2; exit 2 ;;
    esac
  done
  if [ ! -f "$against" ]; then
    echo "error: handoff missing: $against" >&2
    exit 1
  fi

  section=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      \[direct_reports\]) section=direct_reports; continue ;;
      \[queued_wakes\]) section=queued_wakes; continue ;;
      \[decisions\]) section=decisions; continue ;;
      \[scheduled_rechecks\]) section=scheduled_rechecks; continue ;;
      \[counts\]|\[*\]|'') section=; continue ;;
      schema=*|written_at=*|from_session_id=*|reason=*|traffic_bytes=*|forced_continuations=*|direct_reports=*|queued_wakes=*|decisions=*|scheduled_rechecks=*)
        continue
        ;;
    esac
    [ -n "$section" ] || continue
    case "$section" in
      direct_reports)
        id=${line%%|*}
        if [ ! -f "$STATE/$id.meta" ]; then
          printf 'missing direct report meta: %s\n' "$id" >&2
          missing=$((missing + 1))
        fi
        ;;
      queued_wakes)
        found=0
        if [ -f "$STATE/.wake-queue" ]; then
          while IFS= read -r wake_line || [ -n "$wake_line" ]; do
            if [ "$wake_line" = "$line" ]; then
              found=1
              break
            fi
          done < "$STATE/.wake-queue"
        fi
        if [ "$found" -eq 0 ]; then
          printf 'missing queued wake: %s\n' "$line" >&2
          missing=$((missing + 1))
        fi
        ;;
      decisions)
        id=${line%%|*}
        rest=${line#*|}
        if [ ! -f "$STATE/$id.status" ]; then
          printf 'missing decision status file: %s\n' "$id" >&2
          missing=$((missing + 1))
          continue
        fi
        # Decision still open if any status line still carries needs-decision/blocked for this id,
        # or the exact last-line text is still present (substring match on the status log).
        if ! grep -F -q "$rest" "$STATE/$id.status" 2>/dev/null \
          && ! grep -E -q '^(needs-decision:|blocked:)' "$STATE/$id.status" 2>/dev/null; then
          printf 'missing open decision for %s: %s\n' "$id" "$rest" >&2
          missing=$((missing + 1))
        fi
        ;;
      scheduled_rechecks)
        id=${line%%|*}
        if [ ! -f "$STATE/$id.wait" ]; then
          printf 'missing scheduled recheck wait: %s\n' "$id" >&2
          missing=$((missing + 1))
        fi
        ;;
    esac
  done < "$against"

  if [ "$missing" -gt 0 ]; then
    printf 'verify-preservation: FAILED missing=%s\n' "$missing" >&2
    return 1
  fi
  printf 'verify-preservation: ok against=%s\n' "$against"
  return 0
}

cmd_begin_session() {
  local reason=rotate action reasons
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) reason=$2; shift 2 ;;
      --reason=*) reason=${1#--reason=}; shift ;;
      *) echo "error: unknown begin-session flag: $1" >&2; exit 2 ;;
    esac
  done
  # Always snapshot before discarding counters so restart can verify.
  if [ ! -f "$HANDOFF_FILE" ]; then
    cmd_write_handoff --reason "$reason" >/dev/null
  fi
  # Fresh session record; fleet state files stay untouched.
  SESSION_ID=$(fm_task_identity_new_token 2>/dev/null || printf 'sess-%s' "$(now_epoch)")
  STARTED_AT=$(now_epoch)
  TRAFFIC_BYTES=0
  TRAFFIC_SINCE_COMPACT=0
  TURNS=0
  TURNS_SINCE_COMPACT=0
  FORCED_CONTINUATIONS=0
  COMPACT_COUNT=0
  LAST_COMPACT_AT=
  LAST_QUEUED_ACTION=
  LAST_QUEUED_AT=
  write_session_file
  evaluate_into action reasons
  persist_last_action "$action" "begin-session:${reason}"
  printf 'session_id=%s action=%s handoff=%s\n' "$SESSION_ID" "$action" "$HANDOFF_FILE"
}

# --- dispatch ----------------------------------------------------------------

cmd=${1:-}
[ -n "$cmd" ] || { usage >&2; exit 2; }
shift || true

case "$cmd" in
  -h|--help) usage; exit 0 ;;
  ensure) cmd_ensure "$@" ;;
  status) cmd_status "$@" ;;
  thresholds) cmd_thresholds "$@" ;;
  record-traffic) cmd_record_traffic "$@" ;;
  record-turn) cmd_record_turn "$@" ;;
  record-forced-continuation) cmd_record_forced "$@" ;;
  evaluate) cmd_evaluate "$@" ;;
  mark-compacted) cmd_mark_compacted "$@" ;;
  write-handoff) cmd_write_handoff "$@" ;;
  show-handoff) cmd_show_handoff "$@" ;;
  verify-preservation) cmd_verify_preservation "$@" ;;
  begin-session) cmd_begin_session "$@" ;;
  *)
    echo "error: unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
