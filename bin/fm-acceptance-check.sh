#!/usr/bin/env bash
# Fail-closed criterion-to-evidence acceptance gate for ship tasks.
#
# Before Firstmate advances a ship task to validation, PR-ready, merge
# recommendation, or captain-facing completion, it runs this check against the
# task brief and the worker's handoff at data/<id>/acceptance.md.
#
# A bare worker `done:` status line is a claim, not evidence. Incomplete,
# wrong-surface, ambiguous-verdict, and nonpassing-verdict mappings fail with
# precise repair lines for the existing worker.
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
#   0  every concrete criterion maps to compatible direct evidence whose result
#      declares PASS (or proportional none: when the brief has no AC-* ids)
#   1  missing handoff, incomplete fields, proxy rejection, verdict failure,
#      or mismatch
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

fm_acceptance_declared_verdict() {
  local result normalized token remainder separator
  result=${1:-}
  normalized=$(printf '%s' "$result" |
    tr '[:upper:]' '[:lower:]' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  case "$normalized" in
    pass|pass:\ *|pass\ -\ *)
      printf 'PASS\n'
      return 0
      ;;
    fail|fail:\ *|fail\ -\ *)
      printf 'FAIL\n'
      return 0
      ;;
    partial|partial:\ *|partial\ -\ *)
      printf 'PARTIAL\n'
      return 0
      ;;
    unknown|unknown:\ *|unknown\ -\ *)
      printf 'UNKNOWN\n'
      return 0
      ;;
    *)
      ;;
  esac

  token=${normalized%%[[:space:]]*}
  [ "$token" != "$normalized" ] || return 1
  case "$token" in
    pass|fail|partial|unknown) ;;
    *) return 1 ;;
  esac
  remainder=${normalized#"$token"}
  remainder=$(printf '%s' "$remainder" | sed 's/^[[:space:]]*//')
  [ -n "$remainder" ] || return 1
  separator=${remainder%"${remainder#?}"}
  case "$separator" in
    [[:alnum:]]) return 1 ;;
  esac
  printf '%s\n' "$(printf '%s' "$token" | tr '[:lower:]' '[:upper:]')"
}

fm_acceptance_check_declared_verdicts() {
  local brief=$1 evidence=$2 id entry result verdict rc=0
  local -a ids=()

  while IFS= read -r id; do
    [ -n "$id" ] && ids+=("$id")
  done < <(fm_acceptance_extract_ids "$brief")
  [ "${#ids[@]}" -gt 0 ] || return 0

  for id in "${ids[@]}"; do
    entry=$(fm_acceptance_parse_entry "$evidence" "$id" || true)
    result=$(fm_acceptance_entry_field "$entry" result)
    verdict=
    if verdict=$(fm_acceptance_declared_verdict "$result"); then
      if [ "$verdict" = PASS ]; then
        continue
      fi
      if [ "$rc" -eq 0 ]; then
        printf 'criteria: %s\n' "${ids[*]}"
        printf 'shape/surface: compatible direct evidence found; result verdict gate failed\n'
      fi
      printf 'FAIL %s: verdict not achieved (declared=%s)\n' "$id" "$verdict"
      printf '  result: %s\n' "$result"
      printf 'repair %s: rerun direct evidence and record PASS only after the criterion is achieved\n' "$id"
      rc=1
      continue
    fi
    if [ "$rc" -eq 0 ]; then
      printf 'criteria: %s\n' "${ids[*]}"
      printf 'shape/surface: compatible direct evidence found; result verdict gate failed\n'
    fi
    printf 'FAIL %s: verdict ambiguous (result must begin PASS, FAIL, PARTIAL, or UNKNOWN)\n' "$id"
    printf '  result: %s\n' "$result"
    printf 'repair %s: begin result with a declared verdict; only PASS advances\n' "$id"
    rc=1
  done
  [ "$rc" -ne 0 ] || return 0
  printf 'note: verdicts are declared result prefixes, not keywords inferred from free-form prose\n'
  return 1
}

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

SHAPE_REPORT=
if ! SHAPE_REPORT=$(fm_acceptance_check "$BRIEF" "$EVIDENCE"); then
  printf '%s\n' "$SHAPE_REPORT"
  exit 1
fi
if ! fm_acceptance_check_declared_verdicts "$BRIEF" "$EVIDENCE"; then
  exit 1
fi
printf '%s\n' "$SHAPE_REPORT"
printf 'PASS: all evidence results declare PASS\n'
