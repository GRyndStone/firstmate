#!/usr/bin/env bash
# Read-only duplicate recovery-endpoint audit.
#
# The audit examines exact Herdr workspaces and Zellij sessions named by this
# home's own task meta, and matches cmux workspaces by exact home-scoped title.
# It never closes or mutates an endpoint.
#
# A task label with more than one live endpoint, or one live endpoint that does
# not match the recorded endpoint, is reported deterministically with the
# meta-owned worktree, recorded endpoint, and sorted live endpoints.
# Usage: fm-endpoint-audit.sh [--json] [--task <id>]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

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

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-endpoint-audit.XXXXXX") || exit 1
LIVE="$TMP_ROOT/live.tsv"
ROWS="$TMP_ROOT/rows.jsonl"
TARGETS="$TMP_ROOT/targets.tsv"
: > "$LIVE"
: > "$ROWS"
: > "$TARGETS"
cleanup() {
  rm -f "$LIVE" "$ROWS" "$TARGETS" "$TMP_ROOT"/cmux-live.*
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

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  meta_selected "$meta" || continue
  [ "$(fm_backend_of_meta "$meta")" = herdr ] || continue
  fm_backend_source herdr || exit 1
  session=$(fm_meta_get "$meta" herdr_session)
  pane=$(fm_meta_get "$meta" herdr_pane_id)
  workspace=$(fm_meta_get "$meta" herdr_workspace_id)
  target=$(fm_backend_target_of_meta "$meta")
  if [ -z "$session" ]; then
    session=${target%%:*}
  fi
  if [ -z "$pane" ]; then
    pane=${target#*:}
  fi
  if [ -z "$workspace" ]; then
    case "$pane" in
      *:*) workspace=${pane%%:*} ;;
    esac
  fi
  if [ -z "$session" ] || [ -z "$workspace" ]; then
    echo "fm-endpoint-audit: Herdr meta $meta lacks an exact session/workspace target" >&2
    exit 1
  fi
  printf '%s\t%s\n' "$session" "$workspace" >> "$TARGETS"
done

LC_ALL=C sort -u "$TARGETS" -o "$TARGETS"
while IFS=$'\t' read -r session workspace; do
  [ -n "$session" ] && [ -n "$workspace" ] || continue
  workspace_read=0
  if workspace_info=$(fm_backend_herdr_cli "$session" workspace get "$workspace" 2>&1); then
    workspace_read=1
  fi
  workspace_code=$(printf '%s' "$workspace_info" | jq -r '.error.code // empty' 2>/dev/null)
  if [ "$workspace_code" = workspace_not_found ]; then
    continue
  fi
  if [ "$workspace_read" -ne 1 ]; then
    echo "fm-endpoint-audit: cannot read Herdr workspace $session:$workspace" >&2
    exit 1
  fi
  printf '%s' "$workspace_info" | jq -e --arg workspace "$workspace" \
    '.result.workspace.workspace_id == $workspace' >/dev/null 2>&1 || {
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
  printf '%s' "$tabs" | jq -e '.result.tabs | type == "array"' >/dev/null 2>&1 || {
    echo "fm-endpoint-audit: invalid tab inventory for $session:$workspace" >&2
    exit 1
  }
  printf '%s' "$panes" | jq -e '.result.panes | type == "array"' >/dev/null 2>&1 || {
    echo "fm-endpoint-audit: invalid pane inventory for $session:$workspace" >&2
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
  [ -e "$meta" ] || continue
  meta_selected "$meta" || continue
  [ "$(fm_backend_of_meta "$meta")" = herdr ] || continue
  id=$(basename "$meta" .meta)
  label="fm-$id"
  recorded=$(fm_backend_target_of_meta "$meta")
  live_json=$(awk -F '\t' -v label="$label" '$2 == label { print $1 }' "$LIVE" \
    | LC_ALL=C sort -u \
    | jq -R -s '[splits("\\n") | select(length > 0)]') || exit 1
  append_anomaly herdr "$meta" "$live_json" "$recorded" || exit 1
done

audit_zellij_meta() {
  local meta=$1 id session target sessions tabs panes scoped live_json recorded recorded_tab ghost count
  id=$(basename "$meta" .meta)
  target=$(fm_backend_target_of_meta "$meta")
  session=$(fm_meta_get "$meta" zellij_session)
  [ -n "$session" ] || session=${target%%:*}
  [ -n "$session" ] || { echo "fm-endpoint-audit: Zellij meta $meta lacks an exact session target" >&2; return 1; }
  fm_backend_source zellij || return 1
  if ! sessions=$(zellij list-sessions --short --no-formatting 2>&1); then
    if printf '%s\n' "$sessions" | grep -Eqi 'no active zellij sessions|no sessions'; then
      return 0
    fi
    echo "fm-endpoint-audit: cannot read Zellij session inventory for $session" >&2
    return 1
  fi
  printf '%s\n' "$sessions" | grep -qxF "$session" || return 0
  tabs=$(fm_backend_zellij_cli "$session" action list-tabs --json 2>&1) || {
    echo "fm-endpoint-audit: cannot read Zellij tabs for $session" >&2
    return 1
  }
  printf '%s' "$tabs" | jq -e '
    type == "array"
    and all(.[]?; ((.tab_id | type) == "number") and (.tab_id == (.tab_id | floor)) and ((.name | type) == "string"))
  ' >/dev/null 2>&1 || { echo "fm-endpoint-audit: invalid Zellij tab inventory for $session" >&2; return 1; }
  scoped=$(fm_backend_zellij_scoped_title "fm-$id")
  if ! printf '%s' "$tabs" | jq -e --arg want "$scoped" 'any(.[]?; .name == $want)' >/dev/null 2>&1; then
    return 0
  fi
  panes=$(fm_backend_zellij_cli "$session" action list-panes --json 2>&1) || {
    echo "fm-endpoint-audit: cannot read Zellij panes for $session" >&2
    return 1
  }
  printf '%s' "$panes" | jq -e '
    type == "array"
    and all(.[]?;
      ((.id | type) == "number") and (.id == (.id | floor))
      and ((.tab_id | type) == "number") and (.tab_id == (.tab_id | floor))
      and ((.is_plugin | type) == "boolean")
    )
  ' >/dev/null 2>&1 || { echo "fm-endpoint-audit: invalid Zellij pane inventory for $session" >&2; return 1; }
  live_json=$(jq -cn \
    --arg session "$session" \
    --arg want "$scoped" \
    --argjson tabs "$tabs" \
    --argjson panes "$panes" '
      [
        $tabs[]?
        | select(.name == $want)
        | . as $tab
        | ([$panes[]? | select(.tab_id == $tab.tab_id and .is_plugin == false) | .id] | unique | sort) as $terminal
        | if ($terminal | length) > 0
          then $terminal[] | "\($session):\(.)"
          else "\($session):tab:\($tab.tab_id)"
          end
      ]
      | unique
      | sort
    ') || return 1
  recorded=$target
  recorded_tab=$(fm_meta_get "$meta" zellij_tab_id)
  count=$(printf '%s' "$live_json" | jq 'length') || return 1
  case "$recorded_tab" in
    ''|*[!0-9]*) ;;
    *)
      ghost="$session:tab:$recorded_tab"
      if [ "$count" -eq 1 ] && printf '%s' "$live_json" | jq -e --arg ghost "$ghost" 'index($ghost) != null' >/dev/null; then
        return 0
      fi
      ;;
  esac
  append_anomaly zellij "$meta" "$live_json" "$recorded"
}

audit_cmux_meta() {
  local meta=$1 id recorded scoped wins wid workspaces wsid panes sfids live_json state live_file
  id=$(basename "$meta" .meta)
  recorded=$(fm_backend_target_of_meta "$meta")
  fm_backend_source cmux || return 1
  state=$(fm_backend_cmux_ping_state)
  [ "$state" = ok ] || { echo "fm-endpoint-audit: cannot read cmux inventory for $id" >&2; return 1; }
  scoped=$(fm_backend_cmux_scoped_title "fm-$id")
  wins=$(fm_backend_cmux_cli list-windows --json --id-format uuids 2>&1) || {
    echo "fm-endpoint-audit: cannot read cmux windows for $id" >&2
    return 1
  }
  printf '%s' "$wins" | jq -e 'type == "array" and all(.[]?; ((.id | type) == "string") and ((.id | length) > 0))' >/dev/null 2>&1 || {
    echo "fm-endpoint-audit: invalid cmux window inventory for $id" >&2
    return 1
  }
  live_file=$(mktemp "$TMP_ROOT/cmux-live.XXXXXX") || return 1
  while IFS= read -r wid; do
    [ -n "$wid" ] || continue
    workspaces=$(fm_backend_cmux_cli workspace list --json --id-format uuids --window "$wid" 2>&1) || {
      echo "fm-endpoint-audit: cannot read cmux workspaces in window $wid" >&2
      return 1
    }
    printf '%s' "$workspaces" | jq -e '
      (.workspaces | type == "array")
      and all(.workspaces[]?; ((.id | type) == "string") and ((.id | length) > 0) and ((.title | type) == "string"))
    ' >/dev/null 2>&1 || { echo "fm-endpoint-audit: invalid cmux workspace inventory in window $wid" >&2; return 1; }
    while IFS= read -r wsid; do
      [ -n "$wsid" ] || continue
      panes=$(fm_backend_cmux_cli list-panes --workspace "$wsid" --json --id-format uuids 2>&1) || {
        echo "fm-endpoint-audit: cannot read cmux panes for workspace $wsid" >&2
        return 1
      }
      printf '%s' "$panes" | jq -e '
        (.panes | type == "array")
        and all(.panes[]?;
          ((.surface_ids | type) == "array")
          and all(.surface_ids[]?; ((type == "string") and (length > 0)))
          and ((.selected_surface_id == null) or (((.selected_surface_id | type) == "string") and ((.selected_surface_id | length) > 0)))
        )
      ' >/dev/null 2>&1 || { echo "fm-endpoint-audit: invalid cmux pane inventory for workspace $wsid" >&2; return 1; }
      sfids=$(printf '%s' "$panes" | jq -r '[.panes[]? | ((.selected_surface_id? // empty), .surface_ids[]?)] | map(select(type == "string" and length > 0)) | unique | sort | .[]' 2>/dev/null) || return 1
      if [ -n "$sfids" ]; then
        while IFS= read -r sfid; do
          [ -n "$sfid" ] && printf '%s:%s\n' "$wsid" "$sfid" >> "$live_file"
        done <<< "$sfids"
      else
        printf '%s:workspace\n' "$wsid" >> "$live_file"
      fi
    done < <(printf '%s' "$workspaces" | jq -r --arg want "$scoped" '.workspaces[]? | select(.title == $want) | .id' 2>/dev/null)
  done < <(printf '%s' "$wins" | jq -r '.[]? | .id' 2>/dev/null)
  live_json=$(LC_ALL=C sort -u "$live_file" | jq -R -s '[splits("\\n") | select(length > 0)]') || return 1
  append_anomaly cmux "$meta" "$live_json" "$recorded"
}

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  meta_selected "$meta" || continue
  case "$(fm_backend_of_meta "$meta")" in
    zellij) audit_zellij_meta "$meta" || exit 1 ;;
    cmux) audit_cmux_meta "$meta" || exit 1 ;;
  esac
done

if [ -s "$ROWS" ]; then
  RESULT=$(jq -s 'sort_by(.task,.worktree,.recorded_endpoint)' "$ROWS") || exit 1
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
printf '%s' "$RESULT" | jq -r '.[] | "ALERT endpoint-ownership: kind=\(.kind) task=\(.task) worktree=\(.worktree) backend=\(.backend) recorded=\(.recorded_endpoint) live=\(.live_endpoints | join(",")) action=inspect-only"'
