#!/usr/bin/env bash
# Read-only duplicate recovery-endpoint audit.
#
# The audit examines only Herdr sessions and exact workspace ids already named
# by this home's own task meta.
# It never enumerates another home's workspace, never sweeps unrelated Herdr
# sessions, and never closes or mutates an endpoint.
#
# A task label with more than one live endpoint is reported deterministically
# with the meta-owned worktree, recorded endpoint, and sorted live endpoints.
# Earlier recovery endpoints therefore remain visible even when task meta was
# overwritten to point only at the latest endpoint.
# Usage: fm-endpoint-audit.sh [--json]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

FORMAT=text
case "${1:-}" in
  "") ;;
  --json) FORMAT=json ;;
  -h|--help)
    printf 'Usage: fm-endpoint-audit.sh [--json]\n'
    exit 0
    ;;
  *) printf 'Usage: fm-endpoint-audit.sh [--json]\n' >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-endpoint-audit: jq not found" >&2; exit 1; }
fm_backend_source herdr || exit 1

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-endpoint-audit.XXXXXX") || exit 1
LIVE="$TMP_ROOT/live.tsv"
ROWS="$TMP_ROOT/rows.jsonl"
TARGETS="$TMP_ROOT/targets.tsv"
: > "$LIVE"
: > "$ROWS"
: > "$TARGETS"
cleanup() {
  rm -f "$LIVE" "$ROWS" "$TARGETS"
  rmdir "$TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  [ "$(fm_backend_of_meta "$meta")" = herdr ] || continue
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
  workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || {
    echo "fm-endpoint-audit: cannot read Herdr session $session" >&2
    exit 1
  }
  printf '%s' "$workspaces" | jq -e '.result.workspaces | type == "array"' >/dev/null 2>&1 || {
    echo "fm-endpoint-audit: invalid workspace inventory from Herdr session $session" >&2
    exit 1
  }
  if ! printf '%s' "$workspaces" | jq -e --arg workspace "$workspace" \
    'any(.result.workspaces[]?; .workspace_id == $workspace)' >/dev/null; then
    continue
  fi
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
  [ "$(fm_backend_of_meta "$meta")" = herdr ] || continue
  id=$(basename "$meta" .meta)
  label="fm-$id"
  recorded=$(fm_backend_target_of_meta "$meta")
  worktree=$(fm_meta_get "$meta" worktree)
  live_json=$(awk -F '\t' -v label="$label" '$2 == label { print $1 }' "$LIVE" \
    | LC_ALL=C sort -u \
    | jq -R -s '[splits("\\n") | select(length > 0)]') || exit 1
  count=$(printf '%s' "$live_json" | jq 'length') || exit 1
  case "$count" in
    ''|*[!0-9]*) echo "fm-endpoint-audit: invalid live endpoint count" >&2; exit 1 ;;
  esac
  [ "$count" -gt 1 ] || continue
  jq -n \
    --arg task "$id" \
    --arg worktree "$worktree" \
    --arg recorded "$recorded" \
    --argjson live "$live_json" \
    '{kind:"duplicate_recovery_endpoints",backend:"herdr",task:$task,worktree:$worktree,recorded_endpoint:$recorded,live_endpoints:$live,action:"inspect; do not auto-close"}' \
    >> "$ROWS"
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
  printf 'endpoint-audit: no same-home duplicate recovery endpoints found\n'
  exit 0
fi
printf '%s' "$RESULT" | jq -r '.[] | "ALERT duplicate-endpoints: task=\(.task) worktree=\(.worktree) backend=\(.backend) recorded=\(.recorded_endpoint) live=\(.live_endpoints | join(",")) action=inspect-only"'
