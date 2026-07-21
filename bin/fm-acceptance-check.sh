#!/usr/bin/env bash
# Fail-closed criterion-to-evidence acceptance gate for ship tasks.
#
# Before Firstmate advances a ship task to validation, PR-ready, merge
# recommendation, or captain-facing completion, it runs this check against the
# task brief and the worker's handoff at data/<id>/acceptance.md.
#
# A bare worker `done:` status line is a claim, not evidence. Incomplete or
# wrong-surface mappings fail with precise repair lines for the existing worker.
#
# Usage:
#   fm-acceptance-check.sh <task-id>
#     Read brief and evidence under the active firstmate home (FM_HOME).
#   fm-acceptance-check.sh --brief <path> --evidence <path>
#     Fixture / offline check (no task id required).
#   fm-acceptance-check.sh --extract-ids --brief <path>
#     Print AC-N ids found in the Task section.
#   fm-acceptance-check.sh --help
#
# Exit codes:
#   0  every concrete criterion maps to compatible direct evidence
#      (or proportional none: when the brief has no AC-* ids)
#   1  missing handoff, incomplete fields, proxy class rejection, or mismatch
#   2  usage error
#
# Contract owner: this script plus bin/fm-acceptance-lib.sh and
# docs/acceptance-evidence.md. AGENTS.md carries only the load/run trigger.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-acceptance-lib.sh
. "$SCRIPT_DIR/fm-acceptance-lib.sh"

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

BRIEF=
EVIDENCE=
ID=
EXTRACT_ONLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --brief)
      [ "$#" -ge 2 ] || { echo "usage: --brief needs a path" >&2; exit 2; }
      BRIEF=$2
      shift 2
      ;;
    --evidence)
      [ "$#" -ge 2 ] || { echo "usage: --evidence needs a path" >&2; exit 2; }
      EVIDENCE=$2
      shift 2
      ;;
    --extract-ids)
      EXTRACT_ONLY=1
      shift
      ;;
    -*)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -n "$ID" ]; then
        echo "usage: only one task id allowed" >&2
        exit 2
      fi
      ID=$1
      shift
      ;;
  esac
done

if [ -n "$ID" ]; then
  case "$ID" in
    ''|*[!A-Za-z0-9._-]*)
      echo "error: invalid task id '$ID'" >&2
      exit 2
      ;;
  esac
  if [ -z "$BRIEF" ] || [ -z "$EVIDENCE" ]; then
    fm_acceptance_paths_for_task "$FM_HOME" "$ID"
  fi
fi

if [ "$EXTRACT_ONLY" -eq 1 ]; then
  if [ -z "$BRIEF" ]; then
    echo "usage: --extract-ids requires --brief <path> or a task id" >&2
    exit 2
  fi
  fm_acceptance_extract_ids "$BRIEF"
  exit 0
fi

if [ -z "$BRIEF" ] || [ -z "$EVIDENCE" ]; then
  echo "usage: fm-acceptance-check.sh <task-id> | --brief PATH --evidence PATH" >&2
  exit 2
fi

fm_acceptance_check "$BRIEF" "$EVIDENCE"
