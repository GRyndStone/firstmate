#!/usr/bin/env bash
# Home-scoped, serialized entry point for routine tasks-axi reads and writes.
# Every mutating invocation takes state/.backlog.lock before touching this
# home's data/backlog.md, so update/hold and other last-writer races cannot run
# concurrently against one backend file.
#
# `done` additionally refuses while state/<id>.meta or
# state/<id>.tearing-down exists.
# A scout report completion must name the owned data/<id>/report.md and that
# report must exist.
# fm-teardown.sh calls this command only after successful endpoint/worktree and
# meta cleanup, after its duplicate-endpoint preflight, which makes the
# supported completion order fail-closed.
#
# Manual backlog mode remains an explicit operator-owned path and is outside
# this mechanical serialization boundary.
# Usage: fm-backlog.sh <tasks-axi-command> [args...]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BACKLOG="$DATA/backlog.md"
BACKLOG_LOCK="$STATE/.backlog.lock"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  cat <<'EOF'
Usage: fm-backlog.sh <tasks-axi-command> [args...]

Run tasks-axi against this Firstmate home's data/backlog.md.
Mutations are serialized with state/.backlog.lock.
Completion refuses until the owned task meta/teardown lifecycle is resolved.
Use bin/fm-backlog-handoff.sh, not `mv`, for secondmate handoffs.
EOF
}

[ "$#" -gt 0 ] || { usage >&2; exit 2; }
case "$1" in
  -h|--help) usage; exit 0 ;;
esac

if fm_backlog_backend_manual "$CONFIG"; then
  echo "error: config/backlog-backend=manual; fm-backlog.sh will not mutate or reinterpret the manual backend" >&2
  exit 1
fi
fm_tasks_axi_compatible || {
  echo "error: compatible tasks-axi is required for fm-backlog.sh" >&2
  exit 1
}

for arg in "$@"; do
  case "$arg" in
    --file|--file=*|--backend|--backend=*)
      echo "error: fm-backlog.sh owns --file and --backend scoping; do not override them" >&2
      exit 2
      ;;
  esac
done

COMMAND=$1
case "$COMMAND" in
  mv)
    echo "error: use bin/fm-backlog-handoff.sh for cross-home backlog moves" >&2
    exit 2
    ;;
esac

if [ "$COMMAND" = "done" ]; then
  ID=${2:-}
  [ -n "$ID" ] || { echo "error: done requires a task id" >&2; exit 2; }
  HELP=0
  REPORT_ARG=
  previous=
  for arg in "$@"; do
    if [ "$previous" = --report ]; then
      REPORT_ARG=$arg
      previous=
      continue
    fi
    case "$arg" in
      -h|--help) HELP=1 ;;
      --report) previous=--report ;;
      --report=*) REPORT_ARG=${arg#--report=} ;;
    esac
  done
fi

LOCKED=0
release_backlog_lock() {
  if [ "$LOCKED" -eq 1 ]; then
    fm_lock_release "$BACKLOG_LOCK"
    LOCKED=0
  fi
}
trap release_backlog_lock EXIT

# Reads take the same lock as writes so a show/ready result cannot observe a
# half-completed mutation or cross-home move.
fm_lock_acquire_wait "$BACKLOG_LOCK"
LOCKED=1

if [ "$COMMAND" = "done" ] && [ "$HELP" -eq 0 ]; then
  if [ -e "$STATE/$ID.meta" ] || [ -e "$STATE/$ID.tearing-down" ]; then
    echo "REFUSED: task $ID still has unresolved owned lifecycle state." >&2
    echo "Run bin/fm-teardown.sh $ID successfully before recording Done." >&2
    exit 1
  fi
  TASK_INFO=$(tasks-axi show "$ID" --full --file "$BACKLOG") || exit $?
  TASK_KIND=$(printf '%s\n' "$TASK_INFO" | sed -n 's/^[[:space:]]*kind:[[:space:]]*//p' | head -n 1)
  if [ "$TASK_KIND" = scout ]; then
    EXPECTED_REL="data/$ID/report.md"
    EXPECTED_ABS="$DATA/$ID/report.md"
    if [ -z "$REPORT_ARG" ]; then
      echo "REFUSED: scout completion for $ID requires --report $EXPECTED_REL." >&2
      exit 1
    fi
    case "$REPORT_ARG" in
      "$EXPECTED_REL"|"$EXPECTED_ABS") ;;
      *)
        echo "REFUSED: scout completion for $ID must use $EXPECTED_REL." >&2
        exit 1
        ;;
    esac
    if [ ! -f "$EXPECTED_ABS" ]; then
      echo "REFUSED: scout task $ID has no report at $EXPECTED_ABS." >&2
      exit 1
    fi
  fi
fi

tasks-axi "$@" --file "$BACKLOG"
STATUS=$?
release_backlog_lock
exit "$STATUS"
