#!/usr/bin/env bash
# Read-only duplicate recovery-endpoint audit.
#
# The audit examines exact Herdr workspaces and home-identified tmux windows
# named by this home's own task meta.
# Zellij, Orca, and cmux do not expose verified exact-home inventories, so
# their audits emit structured unavailable findings instead of enumerating
# shared namespaces.
# It never closes or mutates an endpoint.
#
# A task label with more than one live endpoint, one live endpoint that does
# not match the recorded endpoint, or a recorded target whose exact ownership
# cannot be confirmed is reported deterministically with the meta-owned
# worktree, recorded endpoint, and sorted live endpoints.
# Usage: fm-endpoint-audit.sh [--json] [--task <id>]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
FM_WAKE_STATE_INIT=skip
. "$SCRIPT_DIR/fm-wake-lib.sh" || exit 1
unset FM_WAKE_STATE_INIT
fm_validate_effective_state_path "$STATE" allow-missing-final || exit 1
STATE=$FM_VALIDATED_STATE_PATH
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

FORMAT=text
TARGET_TASK=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    --task)
      [ "$#" -ge 2 ] || { printf 'Usage: fm-endpoint-audit.sh [--json] [--task <id>]\n' >&2; exit 2; }
      TARGET_TASK=$2
      shift
      ;;
    -h|--help)
      printf 'Usage: fm-endpoint-audit.sh [--json] [--task <id>]\n'
      exit 0
      ;;
    *) printf 'Usage: fm-endpoint-audit.sh [--json] [--task <id>]\n' >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fm-endpoint-audit: jq not found" >&2; exit 1; }

if [ ! -d "$STATE" ]; then
  if [ "$FORMAT" = json ]; then
    printf '[]\n'
  else
    printf 'endpoint-audit: no same-home endpoint ownership anomalies found\n'
  fi
  exit 0
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-endpoint-audit.XXXXXX") || exit 1
LIVE="$TMP_ROOT/live.tsv"
ROWS="$TMP_ROOT/rows.jsonl"
TARGETS="$TMP_ROOT/targets.tsv"
UNAVAILABLE="$TMP_ROOT/unavailable.tsv"
: > "$LIVE"
: > "$ROWS"
: > "$TARGETS"
: > "$UNAVAILABLE"
cleanup() {
  rm -f "$LIVE" "$ROWS" "$TARGETS" "$UNAVAILABLE"
  rmdir "$TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

meta_selected() {
  local meta=$1
  [ -z "$TARGET_TASK" ] || [ "$(basename "$meta" .meta)" = "$TARGET_TASK" ]
}

append_anomaly() {
  local backend=$1 meta=$2 live_json=$3 recorded=$4 count kind id worktree
  id=$(basename "$meta" .meta)
  worktree=$(fm_meta_get "$meta" worktree)
  count=$(printf '%s' "$live_json" | jq 'length') || return 1
  case "$count" in
    ''|*[!0-9]*) echo "fm-endpoint-audit: invalid live endpoint count" >&2; return 1 ;;
  esac
  kind=
  if [ "$count" -gt 1 ]; then
    kind=duplicate_recovery_endpoints
  elif [ "$count" -eq 1 ] && ! printf '%s' "$live_json" | jq -e --arg recorded "$recorded" 'index($recorded) != null' >/dev/null; then
    kind=endpoint_ownership_mismatch
  fi
  [ -n "$kind" ] || return 0
  jq -n \
    --arg kind "$kind" \
    --arg backend "$backend" \
    --arg task "$id" \
    --arg worktree "$worktree" \
    --arg recorded "$recorded" \
    --argjson live "$live_json" \
    '{kind:$kind,backend:$backend,task:$task,worktree:$worktree,recorded_endpoint:$recorded,live_endpoints:$live,action:"inspect; do not auto-close"}' \
    >> "$ROWS"
}

append_recorded_mismatch() {
  local backend=$1 meta=$2 live_json=$3 reason=$4 id worktree recorded
  id=$(basename "$meta" .meta)
  worktree=$(fm_meta_get "$meta" worktree)
  recorded=$(fm_backend_target_of_meta "$meta")
  jq -n \
    --arg backend "$backend" \
    --arg task "$id" \
    --arg worktree "$worktree" \
    --arg recorded "$recorded" \
    --arg reason "$reason" \
    --argjson live "$live_json" \
    '{kind:"endpoint_ownership_mismatch",backend:$backend,task:$task,worktree:$worktree,recorded_endpoint:$recorded,live_endpoints:$live,reason:$reason,action:"inspect; do not auto-close"}' \
    >> "$ROWS"
}

append_duplicate_anomaly() {
  local backend=$1 meta=$2 live_json=$3 recorded=$4 count id worktree
  count=$(printf '%s' "$live_json" | jq 'length') || return 1
  [ "$count" -gt 1 ] || return 0
  id=$(basename "$meta" .meta)
  worktree=$(fm_meta_get "$meta" worktree)
  jq -n \
    --arg backend "$backend" \
    --arg task "$id" \
    --arg worktree "$worktree" \
    --arg recorded "$recorded" \
    --argjson live "$live_json" \
    '{kind:"duplicate_recovery_endpoints",backend:$backend,task:$task,worktree:$worktree,recorded_endpoint:$recorded,live_endpoints:$live,action:"inspect; do not auto-close"}' \
    >> "$ROWS"
}

append_inventory_unavailable() {
  local backend=$1 meta=$2 reason=$3 id worktree recorded
  id=$(basename "$meta" .meta)
  worktree=$(fm_meta_get "$meta" worktree)
  recorded=$(fm_backend_target_of_meta "$meta")
  jq -n \
    --arg backend "$backend" \
    --arg task "$id" \
    --arg worktree "$worktree" \
    --arg recorded "$recorded" \
    --arg reason "$reason" \
    '{kind:"inventory_unavailable",backend:$backend,task:$task,worktree:$worktree,recorded_endpoint:$recorded,live_endpoints:[],reason:$reason,action:"inspect; do not auto-close"}' \
    >> "$ROWS"
}

append_invalid_meta() {
  local meta=$1 reason=$2 id
  id=$(basename "$meta" .meta)
  jq -n \
    --arg task "$id" \
    --arg reason "$reason" \
    '{kind:"inventory_unavailable",backend:"unknown",task:$task,worktree:"",recorded_endpoint:"",live_endpoints:[],reason:$reason,action:"inspect; do not auto-close"}' \
    >> "$ROWS"
}

meta_is_regular() {
  [ -f "$1" ] && [ ! -L "$1" ]
}

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || [ -L "$meta" ] || continue
  meta_selected "$meta" || continue
  meta_is_regular "$meta" || append_invalid_meta "$meta" "task metadata is symlinked or non-regular; cross-home read refused"
done

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || [ -L "$meta" ] || continue
  meta_selected "$meta" || continue
  meta_is_regular "$meta" || continue
  [ "$(fm_backend_of_meta "$meta")" = herdr ] || continue
  fm_backend_source herdr || exit 1
  session=$(fm_meta_get "$meta" herdr_session)
  pane=$(fm_meta_get "$meta" herdr_pane_id)
  workspace=$(fm_meta_get "$meta" herdr_workspace_id)
  target=$(fm_backend_target_of_meta "$meta")
  window=$(fm_meta_get "$meta" window)
  id=$(basename "$meta" .meta)
  kind=$(fm_meta_get "$meta" kind)
  if [ -z "$session" ] || [ -z "$workspace" ] || [ -z "$pane" ] \
     || [ "$window" != "$session:$pane" ] || [ "$target" != "$window" ]; then
    append_inventory_unavailable herdr "$meta" "Herdr meta lacks a consistent exact window/session/workspace/pane identity"
    continue
  fi
  if [ "$kind" = secondmate ]; then
    home=$(fm_meta_get "$meta" home)
    expected_workspace_label=$(fm_backend_herdr_workspace_label_for_home "$home" "$id" 2>/dev/null) || {
      append_inventory_unavailable herdr "$meta" "Herdr secondmate home marker is unsafe or does not match the task identity"
      continue
    }
  else
    expected_workspace_label=$(fm_backend_herdr_workspace_label_for_home "$FM_HOME" 2>/dev/null) || {
      append_inventory_unavailable herdr "$meta" "Herdr home marker is unsafe or invalid"
      continue
    }
  fi
  printf '%s\t%s\t%s\n' "$session" "$workspace" "$expected_workspace_label" >> "$TARGETS"
done

LC_ALL=C sort -u "$TARGETS" -o "$TARGETS"
while IFS=$'\t' read -r session workspace expected_workspace_label; do
  [ -n "$session" ] && [ -n "$workspace" ] || continue
  workspace_read=0
  if workspace_info=$(fm_backend_herdr_cli "$session" workspace get "$workspace" 2>&1); then
    workspace_read=1
  fi
  workspace_code=$(printf '%s' "$workspace_info" | jq -r '.error.code // empty' 2>/dev/null)
  if [ "$workspace_code" = workspace_not_found ]; then
    printf '%s\t%s\n' "$session" "$workspace" >> "$UNAVAILABLE"
    continue
  fi
  if [ "$workspace_read" -ne 1 ]; then
    echo "fm-endpoint-audit: cannot read Herdr workspace $session:$workspace" >&2
    exit 1
  fi
  printf '%s' "$workspace_info" | jq -e --arg workspace "$workspace" --arg label "$expected_workspace_label" \
    '.result.workspace.workspace_id == $workspace and .result.workspace.label == $label' >/dev/null 2>&1 || {
    echo "fm-endpoint-audit: invalid exact workspace response for $session:$workspace" >&2
    exit 1
  }
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$workspace" 2>/dev/null) || {
    echo "fm-endpoint-audit: cannot read tabs for $session:$workspace" >&2
    exit 1
  }
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$workspace" 2>/dev/null) || {
    echo "fm-endpoint-audit: cannot read panes for $session:$workspace" >&2
    exit 1
  }
  printf '%s' "$tabs" | jq -e '
    (.result.tabs | type == "array")
    and all(.result.tabs[]?;
      ((.tab_id | type) == "string") and ((.tab_id | length) > 0)
      and ((.label | type) == "string")
    )
  ' >/dev/null 2>&1 || {
    echo "fm-endpoint-audit: invalid tab inventory for $session:$workspace" >&2
    exit 1
  }
  printf '%s' "$panes" | jq -e '
    (.result.panes | type == "array")
    and all(.result.panes[]?;
      ((.pane_id | type) == "string") and ((.pane_id | length) > 0)
      and ((.tab_id | type) == "string") and ((.tab_id | length) > 0)
    )
  ' >/dev/null 2>&1 || {
    echo "fm-endpoint-audit: invalid pane inventory for $session:$workspace" >&2
    exit 1
  }
  jq -en \
    --argjson tabs "$tabs" \
    --argjson panes "$panes" '
      ($tabs.result.tabs | map(.tab_id)) as $tab_ids
      | all($panes.result.panes[]?;
          .tab_id as $pane_tab_id
          | ($tab_ids | index($pane_tab_id)) != null
        )
    ' >/dev/null 2>&1 || {
    echo "fm-endpoint-audit: unresolved pane tab reference for $session:$workspace" >&2
    exit 1
  }
  jq -nr \
    --arg session "$session" \
    --argjson tabs "$tabs" \
    --argjson panes "$panes" '
      $tabs.result.tabs[]?
      | select(.label | startswith("fm-")) as $tab
      | $panes.result.panes[]?
      | select(.tab_id == $tab.tab_id)
      | "\($session):\(.pane_id)\t\($tab.label)"
    ' >> "$LIVE" || exit 1
done < "$TARGETS"
LC_ALL=C sort -u "$LIVE" -o "$LIVE"

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || [ -L "$meta" ] || continue
  meta_selected "$meta" || continue
  meta_is_regular "$meta" || continue
  [ "$(fm_backend_of_meta "$meta")" = herdr ] || continue
  id=$(basename "$meta" .meta)
  label="fm-$id"
  recorded=$(fm_backend_target_of_meta "$meta")
  session=$(fm_meta_get "$meta" herdr_session)
  pane=$(fm_meta_get "$meta" herdr_pane_id)
  workspace=$(fm_meta_get "$meta" herdr_workspace_id)
  window=$(fm_meta_get "$meta" window)
  kind=$(fm_meta_get "$meta" kind)
  if [ -z "$session" ] || [ -z "$workspace" ] || [ -z "$pane" ] \
     || [ "$window" != "$session:$pane" ] || [ "$recorded" != "$window" ]; then
    continue
  fi
  if [ "$kind" = secondmate ]; then
    home=$(fm_meta_get "$meta" home)
    fm_backend_herdr_workspace_label_for_home "$home" "$id" >/dev/null 2>&1 || continue
  else
    fm_backend_herdr_workspace_label_for_home "$FM_HOME" >/dev/null 2>&1 || continue
  fi
  if awk -F '\t' -v session="$session" -v workspace="$workspace" \
    '$1 == session && $2 == workspace { found=1 } END { exit found ? 0 : 1 }' "$UNAVAILABLE"; then
    append_inventory_unavailable herdr "$meta" \
      "recorded Herdr workspace is missing; exact-home replacement inventory is unavailable"
    continue
  fi
  live_json=$(awk -F '\t' -v label="$label" '$2 == label { print $1 }' "$LIVE" \
    | LC_ALL=C sort -u \
    | jq -R -s '[splits("\\n") | select(length > 0)]') || exit 1
  recorded_state=$(fm_backend_target_state_of_meta "$meta" "$label")
  if [ "$recorded_state" = unknown ]; then
    append_recorded_mismatch herdr "$meta" "$live_json" \
      "recorded Herdr pane ownership could not be confirmed from its exact workspace"
    append_duplicate_anomaly herdr "$meta" "$live_json" "$recorded" || exit 1
    continue
  fi
  append_anomaly herdr "$meta" "$live_json" "$recorded" || exit 1
done

audit_zellij_meta() {
  local meta=$1
  append_inventory_unavailable zellij "$meta" "zellij has no exact-home duplicate inventory; shared-session sweep refused"
}

audit_tmux_meta() {
  local meta=$1 id label recorded session window_id inventory live_json identity current_identity filter recorded_state
  id=$(basename "$meta" .meta)
  label="fm-$id"
  recorded=$(fm_backend_target_of_meta "$meta")
  identity=$(fm_meta_get "$meta" tmux_home_identity)
  session=$(fm_meta_get "$meta" tmux_session)
  window_id=$(fm_meta_get "$meta" tmux_window_id)
  current_identity=$(fm_backend_home_identity 2>/dev/null || true)
  if [ -z "$identity" ] || [ -z "$current_identity" ] || [ "$identity" != "$current_identity" ]; then
    append_inventory_unavailable tmux "$meta" "tmux meta lacks this home's recorded endpoint identity; shared-session sweep refused"
    return
  fi
  if [ -z "$session" ] || [ -z "$window_id" ] || [ "$recorded" != "$window_id" ]; then
    append_inventory_unavailable tmux "$meta" "tmux meta lacks a consistent exact session/window identity; shared-session sweep refused"
    return
  fi
  case "$window_id" in
    @*)
      case "${window_id#@}" in
        ''|*[!0-9]*)
          append_inventory_unavailable tmux "$meta" "tmux meta has an invalid exact window identity"
          return
          ;;
      esac
      ;;
    *) append_inventory_unavailable tmux "$meta" "tmux meta has an invalid exact window identity"; return ;;
  esac
  if ! command -v tmux >/dev/null 2>&1; then
    echo "fm-endpoint-audit: tmux not found" >&2
    return 1
  fi
  filter="#{==:#{window_name},$label}"
  if ! inventory=$(tmux list-windows -t "=$session" -f "$filter" -F $'#{window_id}\t#{window_name}\t#{@firstmate_home}\t_' 2>&1); then
    if printf '%s\n' "$inventory" | grep -Eqi "can't find session|no server running|(failed to connect|error connecting).*(no such file|connection refused)|no sessions"; then
      inventory=
    else
      echo "fm-endpoint-audit: cannot read exact tmux session $session for $id" >&2
      return 1
    fi
  fi
  if [ -n "$inventory" ] && ! printf '%s\n' "$inventory" | awk -F '\t' -v label="$label" '
    NF != 4 || $1 !~ /^@[0-9]+$/ || $2 != label || $4 != "_" { bad=1 }
    END { exit bad ? 1 : 0 }
  '; then
    echo "fm-endpoint-audit: invalid exact-home tmux window inventory for $session:$label" >&2
    return 1
  fi
  if printf '%s\n' "$inventory" | awk -F '\t' 'NF == 4 && $3 == "" { found=1 } END { exit found ? 0 : 1 }'; then
    append_inventory_unavailable tmux "$meta" "untagged legacy tmux window has ambiguous Firstmate-home ownership"
  fi
  live_json=$(printf '%s\n' "$inventory" | awk -F '\t' -v owner="$identity" 'NF == 4 && $3 == owner { print $1 }' \
    | jq -R -s '[splits("\\n") | select(length > 0)] | unique | sort') || return 1
  recorded_state=$(fm_backend_target_state_of_meta "$meta" "$label")
  if [ "$recorded_state" = unknown ]; then
    append_recorded_mismatch tmux "$meta" "$live_json" \
      "recorded tmux window ownership could not be confirmed from its exact id, session, task label, and home identity"
    append_duplicate_anomaly tmux "$meta" "$live_json" "$recorded" || return 1
    return
  fi
  append_anomaly tmux "$meta" "$live_json" "$recorded"
}

audit_cmux_meta() {
  local meta=$1 id
  id=$(basename "$meta" .meta)
  append_inventory_unavailable cmux "$meta" "cmux has no exact-home duplicate inventory; app-global sweep refused"
}

audit_orca_meta() {
  local meta=$1
  append_inventory_unavailable orca "$meta" "orca has no verified exact-worktree terminal inventory; app-global sweep refused"
}

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || [ -L "$meta" ] || continue
  meta_selected "$meta" || continue
  meta_is_regular "$meta" || continue
  case "$(fm_backend_of_meta "$meta")" in
    tmux) audit_tmux_meta "$meta" || exit 1 ;;
    zellij) audit_zellij_meta "$meta" || exit 1 ;;
    orca) audit_orca_meta "$meta" || exit 1 ;;
    cmux) audit_cmux_meta "$meta" || exit 1 ;;
  esac
done

if [ -s "$ROWS" ]; then
  RESULT=$(jq -s 'sort_by(.task,.worktree,.recorded_endpoint,.kind)' "$ROWS") || exit 1
else
  RESULT='[]'
fi
if [ "$FORMAT" = json ]; then
  printf '%s\n' "$RESULT"
  exit 0
fi

if [ "$RESULT" = '[]' ]; then
  printf 'endpoint-audit: no same-home endpoint ownership anomalies found\n'
  exit 0
fi
printf '%s' "$RESULT" | jq -r '.[] | "ALERT endpoint-ownership: kind=\(.kind) task=\(.task) worktree=\(.worktree) backend=\(.backend) recorded=\(.recorded_endpoint) live=\(.live_endpoints | join(",")) reason=\(.reason // "-") action=inspect-only"'
