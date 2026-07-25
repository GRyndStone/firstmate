#!/usr/bin/env bash
# Audit existing task metadata for recorded-worktree ownership mismatches.
# Read-only: reports proven mismatches and exits nonzero; repairs are manual.
# Usage: fm-worktree-audit.sh [state-dir]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${1:-${FM_STATE_OVERRIDE:-$FM_HOME/state}}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-worktree-ownership-lib.sh
. "$SCRIPT_DIR/fm-worktree-ownership-lib.sh"

found=0
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  id=$(basename "$meta" .meta)
  out=$(fm_worktree_validate_task_ownership "$id" "$meta" audit 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    [ -n "$out" ] && printf '%s\n' "$out"
    found=1
  fi
done

if [ "$found" -eq 0 ]; then
  printf 'OK: no worktree ownership mismatches found in %s\n' "$STATE"
fi
exit "$found"
