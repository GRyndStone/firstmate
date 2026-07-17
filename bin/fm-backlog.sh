#!/usr/bin/env bash
# Home-scoped, serialized entry point for routine tasks-axi reads and writes.
# Every mutating invocation takes state/.backlog.lock before touching this
# home's data/backlog.md, so update/hold and other last-writer races cannot run
# concurrently against one backend file.
#
# `done` additionally requires a single-use state/<id>.teardown-complete proof
# written by successful lifecycle teardown.
# Interrupted proof claims are reconciled from the task's resulting backlog
# state, and every other successful mutation invalidates affected receipts.
# A scout report completion must name the owned data/<id>/report.md, which must
# be a regular non-symlink file canonically contained by this home.
# fm-teardown.sh calls this command only after successful endpoint/worktree
# cleanup from its retained backlog-done-started stage, after duplicate-endpoint preflight,
# which makes the supported completion order fail-closed.
#
# Manual backlog mode suppresses automatic availability reporting, but every
# read and mutation still uses this serialized wrapper.
# Usage: fm-backlog.sh <tasks-axi-command> [args...]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

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
  create) shift; set -- "add" "$@" ;;
  view) shift; set -- "show" "$@" ;;
  close) shift; set -- "done" "$@" ;;
  edit) shift; set -- "update" "$@" ;;
  delete) shift; set -- "rm" "$@" ;;
esac

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
  add|list|show|start|done|reopen|update|rm|block|unblock|hold|unhold|ready|prune|render|setup|-v|-V|--version) ;;
  *)
    echo "error: unsupported tasks-axi command: $COMMAND" >&2
    exit 2
    ;;
esac

run_tasks_axi() {
  (cd "$FM_HOME" && HOME="$FM_HOME" tasks-axi "$@" --backend markdown --file "$BACKLOG")
}

archive_has_canonical_done_record() {  # <id>
  local id=$1
  [ -f "$ARCHIVE_PATH" ] || return 1
  awk -v id="$id" '
    /^- \[x\] / {
      row = $0
      sub(/^- \[x\] /, "", row)
      prefix = id " - "
      if (substr(row, 1, length(prefix)) == prefix) {
        found = 1
        exit
      }
    }
    END { exit found ? 0 : 1 }
  ' "$ARCHIVE_PATH"
}

completion_claim_settle() {
  local task_info task_state show_status proof_present=0
  [ -n "${CLAIMED_PROOF:-}" ] || return 0
  if [ -L "$CLAIM_DIR" ] || [ ! -d "$CLAIM_DIR" ] || [ -L "$CLAIMED_PROOF" ]; then
    echo "error: teardown proof claim for $ID is not a regular owned claim" >&2
    return 1
  fi
  [ ! -f "$CLAIMED_PROOF" ] || proof_present=1
  show_status=0
  task_info=$(run_tasks_axi show "$ID" --full 2>&1) || show_status=$?
  if [ "$show_status" -ne 0 ]; then
    if printf '%s\n' "$task_info" | grep -Fx 'code: NOT_FOUND' >/dev/null \
      && archive_has_canonical_done_record "$ID"; then
      task_state=done
    else
      echo "error: could not determine backlog state while recovering the teardown proof claim for $ID" >&2
      return 1
    fi
  else
    task_state=$(printf '%s\n' "$task_info" | sed -n 's/^[[:space:]]*state:[[:space:]]*//p' | head -n 1)
  fi
  if [ -z "$task_state" ]; then
    echo "error: could not determine backlog state while recovering the teardown proof claim for $ID" >&2
    return 1
  fi
  if [ "$task_state" = done ]; then
    rm -f "$CLAIMED_PROOF" || return 1
    rmdir "$CLAIM_DIR" || return 1
    CLAIMED_PROOF=
    CLAIM_DIR=
    CLAIM_SETTLED_STATE=done
    return 0
  fi
  case "$task_state" in
    queued|in_flight)
      if [ "$proof_present" -ne 1 ]; then
        if [ -f "$COMPLETION_PROOF" ] && [ ! -L "$COMPLETION_PROOF" ] \
          && rmdir "$CLAIM_DIR"; then
          CLAIMED_PROOF=
          CLAIM_DIR=
          CLAIM_SETTLED_STATE=retry
          return 0
        fi
        echo "error: cannot recover empty teardown proof claim for active task $ID" >&2
        return 1
      fi
      if [ -e "$COMPLETION_PROOF" ] || [ -L "$COMPLETION_PROOF" ]; then
        echo "error: cannot recover teardown proof claim for $ID because its proof path is occupied" >&2
        return 1
      fi
      mv "$CLAIMED_PROOF" "$COMPLETION_PROOF" || return 1
      rmdir "$CLAIM_DIR" || return 1
      CLAIMED_PROOF=
      CLAIM_DIR=
      CLAIM_SETTLED_STATE=retry
      return 0
      ;;
  esac
  echo "error: cannot recover teardown proof claim for $ID from backlog state ${task_state:-unknown}" >&2
  return 1
}

recover_existing_completion_claim() {
  local candidate
  local -a claims=()
  for candidate in "$STATE"/."$ID".teardown-complete.claimed.*; do
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then
      claims+=("$candidate")
    fi
  done
  if [ "${#claims[@]}" -gt 1 ]; then
    echo "error: multiple interrupted teardown proof claims exist for $ID" >&2
    return 1
  fi
  [ "${#claims[@]}" -eq 1 ] || return 0
  CLAIM_DIR=${claims[0]}
  CLAIMED_PROOF="$CLAIM_DIR/proof"
  completion_claim_settle
}

finalizing_stage_is_owned() {  # <stage-path> <task-id>
  local stage=$1 id=$2 meta meta_cksum aux aux_cksum owner kind target backend endpoint endpoint_state
  [ ! -L "$stage" ] && [ -f "$stage" ] || return 1
  meta="$STATE/$id.meta"
  [ ! -L "$meta" ] && [ -f "$meta" ] || return 1
  meta_cksum=$(cksum < "$meta" | awk '{print $1 ":" $2}') || return 1
  awk -F= -v id="$id" -v want_meta_cksum="$meta_cksum" '
    $1 == "version" { versions++; version = substr($0, index($0, "=") + 1) }
    $1 == "task" { tasks++; task = substr($0, index($0, "=") + 1) }
    $1 == "phase" { phases++; phase = substr($0, index($0, "=") + 1) }
    $1 == "meta-cksum" { metas++; meta_cksum = substr($0, index($0, "=") + 1) }
    $1 == "record-cksum" { records++; record_cksum = substr($0, index($0, "=") + 1) }
    $1 == "owner-identity" { identities++; identity = substr($0, index($0, "=") + 1) }
    $1 == "owner-marker" { markers++; marker = substr($0, index($0, "=") + 1) }
    $1 == "owner-token" { tokens++; token = substr($0, index($0, "=") + 1) }
    $1 == "force" { forces++; force = substr($0, index($0, "=") + 1) }
    $1 == "outcome" { outcomes++; outcome = substr($0, index($0, "=") + 1) }
    $1 == "aux-cksum" { auxes++; aux = substr($0, index($0, "=") + 1) }
    { lines++ }
    END {
      exit !(versions == 1 && version == "3" && tasks == 1 && task == id \
        && phases == 1 && phase == "backlog-done-started" \
        && metas == 1 && meta_cksum == want_meta_cksum \
        && records == 1 && record_cksum != "" \
        && identities == 1 && identity != "" \
        && markers == 1 && marker != "" \
        && tokens == 1 && token != "" \
        && forces == 1 && force == "0" \
        && outcomes == 1 && outcome ~ /^delivered-(report|local|pr|default)$/ \
        && auxes == 1 && aux != "" && lines == 11 \
        && ((identity == "absent" && marker == "none" && token == "none") \
          || (identity != "absent" && marker != "none" && token != "none")))
    }
  ' "$stage" || return 1
  owner=$(sed -n 's/^owner-marker=//p' "$stage")
  [ "$owner" = none ] || { [ ! -e "$owner" ] && [ ! -L "$owner" ]; } || return 1
  aux="$STATE/$id.teardown-owners"
  [ -f "$aux" ] && [ ! -L "$aux" ] || return 1
  aux_cksum=$(sed -n 's/^aux-cksum=//p' "$stage")
  [ "$(cksum < "$aux" | awk '{print $1 ":" $2}')" = "$aux_cksum" ] || return 1
  awk -F '\t' '
    NF != 5 || $1 !~ /^(child-home|child-worktree|tasktmp)$/ || $2 == "" \
      || $3 == "" || $4 == "" || $5 == "" || seen[$2]++ { exit 1 }
  ' "$aux" || return 1
  while IFS=$'\t' read -r kind target _; do
    [ -n "$kind" ] && [ -n "$target" ] || return 1
    [ ! -e "$target" ] && [ ! -L "$target" ] || return 1
  done < "$aux"
  kind=$(sed -n 's/^kind=//p' "$meta" | tail -1)
  if [ "$kind" = secondmate ]; then
    target=$(sed -n 's/^home=//p' "$meta" | tail -1)
    [ -n "$target" ] || target=$(sed -n 's/^worktree=//p' "$meta" | tail -1)
  else
    target=$(sed -n 's/^worktree=//p' "$meta" | tail -1)
  fi
  [ -z "$target" ] || { [ ! -e "$target" ] && [ ! -L "$target" ]; } || return 1
  backend=$(fm_backend_of_meta "$meta")
  endpoint=$(fm_backend_target_of_meta "$meta")
  [ -n "$endpoint" ] || return 1
  endpoint_state=$(fm_backend_target_state "$backend" "$endpoint" "fm-$id" "$(fm_meta_get "$meta" zellij_tab_id)") || return 1
  [ "$endpoint_state" = absent ]
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
CLAIMED_PROOF=
CLAIM_DIR=
CLAIM_SETTLED_STATE=
release_backlog_lock() {
  if [ "$LOCKED" -eq 1 ]; then
    fm_lock_release "$BACKLOG_LOCK"
    LOCKED=0
  fi
}
cleanup_backlog_wrapper() {
  local status=$?
  trap - EXIT INT TERM
  if [ -n "${CLAIMED_PROOF:-}" ] && ! completion_claim_settle; then
    [ "$status" -ne 0 ] || status=1
  fi
  release_backlog_lock
  exit "$status"
}
trap cleanup_backlog_wrapper EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Reads take the same lock as writes so a show/ready result cannot observe a
# half-completed mutation or cross-home move.
fm_lock_acquire_wait "$BACKLOG_LOCK"
LOCKED=1

if [ "$COMMAND" = "done" ] && [ "$HELP" -eq 0 ]; then
  COMPLETION_PROOF="$STATE/$ID.teardown-complete"
  FINALIZING_STAGE=0
  FINALIZING_OUTCOME=
  FINALIZING_RECORD_CKSUM=
  if finalizing_stage_is_owned "$STATE/$ID.teardown-stage" "$ID"; then
    FINALIZING_STAGE=1
    FINALIZING_OUTCOME=$(sed -n 's/^outcome=//p' "$STATE/$ID.teardown-stage")
    FINALIZING_RECORD_CKSUM=$(sed -n 's/^record-cksum=//p' "$STATE/$ID.teardown-stage")
  fi
  if [ "$FINALIZING_STAGE" -ne 1 ] && { [ -e "$STATE/$ID.tearing-down" ] \
     || [ -e "$STATE/$ID.meta" ] \
     || [ -e "$STATE/$ID.teardown-stage" ] || [ -L "$STATE/$ID.teardown-stage" ]; }; then
    echo "REFUSED: task $ID still has unresolved owned lifecycle state." >&2
    echo "Run bin/fm-teardown.sh $ID successfully before recording Done." >&2
    exit 1
  fi
  recover_existing_completion_claim || exit 1
  if [ "$CLAIM_SETTLED_STATE" = done ]; then
    echo "Done for $ID was already recorded before interrupted proof cleanup completed."
    exit 0
  fi
  if [ "$FINALIZING_STAGE" -eq 1 ]; then
    FINALIZING_INFO_STATUS=0
    FINALIZING_INFO=$(run_tasks_axi show "$ID" --full 2>&1) || FINALIZING_INFO_STATUS=$?
    if [ "$FINALIZING_INFO_STATUS" -eq 0 ] \
       && [ "$(printf '%s\n' "$FINALIZING_INFO" | sed -n 's/^[[:space:]]*state:[[:space:]]*//p' | head -1)" = done ]; then
      echo "Done for $ID was already recorded before teardown finalization completed."
      exit 0
    fi
    if [ "$FINALIZING_INFO_STATUS" -ne 0 ] \
       && printf '%s\n' "$FINALIZING_INFO" | grep -Fx 'code: NOT_FOUND' >/dev/null \
       && archive_has_canonical_done_record "$ID"; then
      echo "Done for $ID was already archived before teardown finalization completed."
      exit 0
    fi
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
  if [ "$FINALIZING_STAGE" -eq 1 ] \
     && { [ "$PROOF_OUTCOME" != "$FINALIZING_OUTCOME" ] \
       || [ "$PROOF_RECORD_CKSUM" != "$FINALIZING_RECORD_CKSUM" ]; }; then
    echo "REFUSED: teardown proof does not match the complete finalization stage for $ID." >&2
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
    EXPECTED_ABS="$FM_HOME/data/$ID/report.md"
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
    if ! fm_firstmate_scout_report_path "$FM_HOME" "$ID" >/dev/null; then
      echo "REFUSED: scout task $ID has no regular home-contained report at $EXPECTED_ABS." >&2
      exit 1
    fi
  fi
fi

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
    else
      CLAIMED_PROOF=
      CLAIM_DIR=
    fi
  else
    if mv "$CLAIMED_PROOF" "$COMPLETION_PROOF"; then
      rmdir "$CLAIM_DIR" 2>/dev/null || true
      CLAIMED_PROOF=
      CLAIM_DIR=
    else
      echo "error: Done failed and teardown proof claim could not be restored for $ID" >&2
      STATUS=1
    fi
  fi
fi
if [ "$STATUS" -eq 0 ] && [ "$COMMAND" != "done" ]; then
  case "$COMMAND" in
    add|start|reopen|update|rm|block|unblock|hold|unhold)
      MUTATED_ID=${2:-}
      ADD_MINTED=0
      if [ "$COMMAND" = add ]; then
        for arg in "$@"; do
          [ "$arg" != --mint ] || ADD_MINTED=1
        done
      fi
      if [ "$ADD_MINTED" -eq 1 ]; then
        if ! fm_tasks_axi_invalidate_all_completion_receipts "$STATE"; then
          echo "error: backlog mutation succeeded but completion receipts could not be invalidated safely" >&2
          STATUS=1
        fi
      elif fm_tasks_axi_valid_task_id "$MUTATED_ID"; then
        if ! fm_tasks_axi_invalidate_completion_receipt "$STATE" "$MUTATED_ID"; then
          echo "error: backlog mutation succeeded but completion receipts for $MUTATED_ID could not be invalidated safely" >&2
          STATUS=1
        fi
      fi
      ;;
    prune|render)
      if ! fm_tasks_axi_invalidate_all_completion_receipts "$STATE"; then
        echo "error: backlog mutation succeeded but completion receipts could not be invalidated safely" >&2
        STATUS=1
      fi
      ;;
  esac
fi
release_backlog_lock
exit "$STATUS"
