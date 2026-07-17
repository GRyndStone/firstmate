#!/usr/bin/env bash
# Home-scoped, serialized entry point for routine tasks-axi reads and writes.
# Every mutating invocation takes state/.backlog.lock before touching this
# home's data/backlog.md, so update/hold and other last-writer races cannot run
# concurrently against one backend file.
#
# `done` additionally requires a single-use state/<id>.teardown-complete proof
# written by successful lifecycle teardown.
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

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  cat <<'EOF'
Usage: fm-backlog.sh <tasks-axi-command> [args...]

Run tasks-axi against this Firstmate home's data/backlog.md.
Mutations are serialized with state/.backlog.lock.
Completion requires single-use proof from successful owned lifecycle teardown.
Use bin/fm-backlog-handoff.sh, not `mv`, for secondmate handoffs.
EOF
}

[ "$#" -gt 0 ] || { usage >&2; exit 2; }
case "$1" in
  -h|--help) usage; exit 0 ;;
  task)
    case "${2:-}" in -h|--help) usage; exit 0 ;; esac
    ;;
esac

FM_HOME=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || {
  echo "error: FM_HOME is not an accessible directory: $FM_HOME" >&2
  exit 1
}

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BACKLOG_SOURCE="$DATA/backlog.md"
BACKLOG_LOCK="$STATE/.backlog.lock"

resolved_path() {
  local path=$1 label=$2 parent
  case "$path" in
    /*) ;;
    *) path="$PWD/$path" ;;
  esac
  parent=$(dirname "$path")
  (cd "$parent" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$path")") || {
    echo "error: cannot resolve $label parent: $path" >&2
    return 1
  }
}

contained_path() {
  local path=$1 label=$2 parent resolved
  case "$path" in
    /*) ;;
    *) path="$FM_HOME/$path" ;;
  esac
  parent=$(dirname "$path")
  resolved=$(cd "$parent" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$path")") || {
    echo "error: cannot resolve $label parent inside FM_HOME: $path" >&2
    return 1
  }
  case "$resolved" in
    "$FM_HOME"/*) printf '%s\n' "$resolved" ;;
    *) echo "error: $label must remain inside FM_HOME: $path" >&2; return 1 ;;
  esac
}

if [ -L "$BACKLOG_SOURCE" ]; then
  echo "error: backlog must not be a symlink: $BACKLOG_SOURCE" >&2
  exit 1
fi
BACKLOG=$(resolved_path "$BACKLOG_SOURCE" backlog) || exit 1
if [ -z "${FM_DATA_OVERRIDE:-}" ]; then
  BACKLOG=$(contained_path "$BACKLOG" backlog) || exit 1
fi

TASKS_CONFIG="$FM_HOME/.tasks.toml"
if [ -L "$TASKS_CONFIG" ] || [ ! -f "$TASKS_CONFIG" ]; then
  echo "error: FM_HOME must contain a regular .tasks.toml: $TASKS_CONFIG" >&2
  exit 1
fi
ARCHIVE_REL=$(fm_tasks_axi_markdown_archive "$TASKS_CONFIG") || exit 1
ARCHIVE_PATH=$(contained_path "$ARCHIVE_REL" markdown.archive) || exit 1
if [ -L "$ARCHIVE_PATH" ]; then
  echo "error: markdown.archive must not be a symlink: $ARCHIVE_PATH" >&2
  exit 1
fi

if [ "$1" = task ]; then
  shift
  [ "$#" -gt 0 ] || { usage >&2; exit 2; }
fi
case "$1" in
  close) shift; set -- "done" "$@" ;;
esac

if fm_backlog_backend_manual "$CONFIG"; then
  echo "error: config/backlog-backend=manual; fm-backlog.sh will not mutate or reinterpret the manual backend" >&2
  exit 1
fi
(cd "$FM_HOME" && HOME="$FM_HOME" fm_tasks_axi_compatible) || {
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

run_tasks_axi() {
  (cd "$FM_HOME" && HOME="$FM_HOME" tasks-axi "$@" --backend markdown --file "$BACKLOG")
}

if [ "$COMMAND" = "done" ]; then
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
  ID=${2:-}
  if [ "$HELP" -eq 0 ]; then
    [ -n "$ID" ] || { echo "error: done requires a task id" >&2; exit 2; }
    fm_tasks_axi_valid_task_id "$ID" || {
      echo "error: invalid task id: $ID" >&2
      exit 2
    }
  fi
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
  COMPLETION_PROOF="$STATE/$ID.teardown-complete"
  if [ -e "$STATE/$ID.meta" ] || [ -e "$STATE/$ID.tearing-down" ]; then
    echo "REFUSED: task $ID still has unresolved owned lifecycle state." >&2
    echo "Run bin/fm-teardown.sh $ID successfully before recording Done." >&2
    exit 1
  fi
  if [ -L "$COMPLETION_PROOF" ] || [ ! -f "$COMPLETION_PROOF" ]; then
    echo "REFUSED: task $ID has no durable successful-teardown proof." >&2
    echo "Run bin/fm-teardown.sh $ID successfully; never-dispatched work must be removed or cancelled instead of recorded Done." >&2
    exit 1
  fi
  PROOF_TASK=$(sed -n 's/^task=//p' "$COMPLETION_PROOF" | tail -1)
  PROOF_VERSION=$(sed -n 's/^version=//p' "$COMPLETION_PROOF" | tail -1)
  PROOF_KIND=$(sed -n 's/^kind=//p' "$COMPLETION_PROOF" | tail -1)
  PROOF_OUTCOME=$(sed -n 's/^outcome=//p' "$COMPLETION_PROOF" | tail -1)
  PROOF_RECORD_CKSUM=$(sed -n 's/^record-cksum=//p' "$COMPLETION_PROOF" | tail -1)
  if [ "$PROOF_VERSION" != 1 ] || [ "$PROOF_TASK" != "$ID" ]; then
    echo "REFUSED: teardown proof is not bound to task $ID." >&2
    exit 1
  fi
  TASK_INFO=$(run_tasks_axi show "$ID" --full) || exit $?
  TASK_RECORD_CKSUM=$(printf '%s' "$TASK_INFO" | fm_tasks_axi_task_fingerprint) || {
    echo "REFUSED: tasks-axi returned no stable task record for $ID." >&2
    exit 1
  }
  if [ -z "$PROOF_RECORD_CKSUM" ] || [ "$PROOF_RECORD_CKSUM" != "$TASK_RECORD_CKSUM" ]; then
    echo "REFUSED: teardown proof does not match the current backlog record for $ID." >&2
    exit 1
  fi
  TASK_KIND=$(printf '%s\n' "$TASK_INFO" | sed -n 's/^[[:space:]]*kind:[[:space:]]*//p' | head -n 1)
  [ "$TASK_KIND" != task ] || TASK_KIND=ship
  if [ "$PROOF_KIND" != "$TASK_KIND" ]; then
    echo "REFUSED: teardown proof kind ${PROOF_KIND:-missing} does not match backlog kind ${TASK_KIND:-missing} for $ID." >&2
    exit 1
  fi
  case "$TASK_KIND:$PROOF_OUTCOME" in
    scout:delivered-report|ship:delivered-local|ship:delivered-pr|ship:delivered-default) ;;
    *)
      echo "REFUSED: teardown proof does not record a delivered outcome for $ID." >&2
      exit 1
      ;;
  esac
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

CLAIMED_PROOF=
CLAIM_DIR=
if [ "$COMMAND" = "done" ] && [ "${HELP:-0}" -eq 0 ]; then
  CLAIM_DIR=$(mktemp -d "$STATE/.${ID}.teardown-complete.claimed.XXXXXXXX") || {
    echo "error: could not prepare a single-use teardown proof claim for $ID" >&2
    exit 1
  }
  CLAIMED_PROOF="$CLAIM_DIR/proof"
  if ! mv "$COMPLETION_PROOF" "$CLAIMED_PROOF"; then
    rmdir "$CLAIM_DIR" 2>/dev/null || true
    echo "REFUSED: teardown proof for $ID could not be claimed for single use." >&2
    exit 1
  fi
fi

run_tasks_axi "$@"
STATUS=$?
if [ "$COMMAND" = "done" ] && [ "${HELP:-0}" -eq 0 ]; then
  if [ "$STATUS" -eq 0 ]; then
    if ! rm -f "$CLAIMED_PROOF" || ! rmdir "$CLAIM_DIR"; then
      echo "error: Done succeeded but teardown proof claim could not be consumed for $ID" >&2
      STATUS=1
    fi
  else
    if mv "$CLAIMED_PROOF" "$COMPLETION_PROOF"; then
      rmdir "$CLAIM_DIR" 2>/dev/null || true
    else
      echo "error: Done failed and teardown proof claim could not be restored for $ID" >&2
      STATUS=1
    fi
  fi
fi
if [ "$STATUS" -eq 0 ] && [ "$COMMAND" != "done" ]; then
  case "$COMMAND" in
    add|update|hold|reopen|start|rm|remove|cancel)
      MUTATED_ID=${2:-}
      if fm_tasks_axi_valid_task_id "$MUTATED_ID"; then
        rm -f "$STATE/$MUTATED_ID.teardown-complete"
      fi
      ;;
  esac
fi
release_backlog_lock
exit "$STATUS"
