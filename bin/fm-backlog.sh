#!/usr/bin/env bash
# Home-scoped, serialized entry point for routine tasks-axi reads and writes.
# Every mutating invocation takes state/.backlog.lock before touching this
# home's data/backlog.md, so update/hold and other last-writer races cannot run
# concurrently against one backend file.
#
# `done` additionally requires a single-use state/<id>.teardown-complete proof
# written by successful lifecycle teardown.
# Interrupted proof claims are reconciled from the task's resulting backlog
# state, and every other mutation claims affected receipts before backend write.
# A scout report completion must name the owned data/<id>/report.md, which must
# be a regular non-symlink file canonically contained by this home.
# fm-teardown.sh calls this command only after successful endpoint/worktree
# cleanup from its retained backlog-done-started stage, after duplicate-endpoint preflight,
# which makes the supported completion order fail-closed.
#
# Manual backlog mode suppresses automatic availability reporting.
# docs/configuration.md owns its exclusive single-owner hand-edit exception.
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
COMMAND_HELP=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) COMMAND_HELP=1 ;;
  esac
done

run_tasks_axi() {
  (cd "$FM_HOME" && HOME="$FM_HOME" tasks-axi "$@" --backend markdown --file "$BACKLOG")
}

done_ack_is_valid() {
  case "${1:-}" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) return 0 ;;
    *) return 1 ;;
  esac
}

done_ack_marker() {
  printf 'fm-done-ack:%s' "$1"
}

output_has_done_ack() {
  local output=$1 ack=$2 marker
  done_ack_is_valid "$ack" || return 1
  marker=$(done_ack_marker "$ack")
  printf '%s\n' "$output" | grep -F -- "$marker" >/dev/null
}

archive_has_done_ack() {  # <id> <done-ack>
  local id=$1 ack=$2 marker
  done_ack_is_valid "$ack" || return 1
  [ -f "$ARCHIVE_PATH" ] || return 1
  marker=$(done_ack_marker "$ack")
  awk -v id="$id" -v marker="  $marker" '
    /^- \[x\] / {
      row = $0
      sub(/^- \[x\] /, "", row)
      prefix = id " - "
      owned = (substr(row, 1, length(prefix)) == prefix)
      next
    }
    /^## / { owned = 0 }
    /^- / { owned = 0 }
    owned && $0 == marker {
        found = 1
        exit
    }
    END { exit found ? 0 : 1 }
  ' "$ARCHIVE_PATH"
}

proof_done_ack() {  # <proof-path> <task-id>
  local proof=$1 id=$2 version task ack
  [ -f "$proof" ] && [ ! -L "$proof" ] || return 1
  awk -F= -v id="$id" '
    $1 == "version" { versions++; version = substr($0, index($0, "=") + 1) }
    $1 == "task" { tasks++; task = substr($0, index($0, "=") + 1) }
    $1 == "kind" { kinds++; kind = substr($0, index($0, "=") + 1) }
    $1 == "outcome" { outcomes++; outcome = substr($0, index($0, "=") + 1) }
    $1 == "record-cksum" { records++; record = substr($0, index($0, "=") + 1) }
    $1 == "done-ack" { acks++; ack = substr($0, index($0, "=") + 1) }
    { lines++ }
    END {
      exit !(versions == 1 && version == "2" && tasks == 1 && task == id \
        && kinds == 1 && kind != "" && outcomes == 1 && outcome != "" \
        && records == 1 && record != "" && acks == 1 \
        && length(ack) == 32 && ack !~ /[^0-9a-f]/ && lines == 6)
    }
  ' "$proof" || return 1
  version=$(sed -n 's/^version=//p' "$proof" | tail -1)
  task=$(sed -n 's/^task=//p' "$proof" | tail -1)
  ack=$(sed -n 's/^done-ack=//p' "$proof" | tail -1)
  [ "$version" = 2 ] && [ "$task" = "$id" ] && done_ack_is_valid "$ack" || return 1
  printf '%s\n' "$ack"
}

completion_claim_settle() {
  local task_info task_state show_status proof_present=0 proof_ack claim_ack completion_acked=0
  [ -n "${CLAIM_DIR:-}" ] || return 0
  if [ -L "$CLAIM_DIR" ] || [ ! -d "$CLAIM_DIR" ] || [ -L "$CLAIMED_PROOF" ]; then
    echo "error: teardown proof claim for $ID is not a regular owned claim" >&2
    return 1
  fi
  if [ ! -e "$CLAIMED_PROOF" ] && [ ! -L "$CLAIMED_PROOF" ] \
     && proof_ack=$(proof_done_ack "$COMPLETION_PROOF" "$ID" 2>/dev/null); then
    if [ -L "$CLAIM_ACK" ]; then
      echo "error: teardown proof claim for $ID is not a regular owned claim" >&2
      return 1
    fi
    if { [ ! -e "$CLAIM_ACK" ] || rm -f "$CLAIM_ACK"; } && rmdir "$CLAIM_DIR"; then
      CLAIMED_PROOF=
      CLAIM_ACK=
      CLAIM_DIR=
      CLAIM_SETTLED_STATE=retry
      return 0
    fi
  fi
  if [ -L "$CLAIM_ACK" ]; then
    echo "error: teardown proof claim for $ID is not a regular owned claim" >&2
    return 1
  fi
  if [ -f "$CLAIM_ACK" ]; then
    claim_ack=$(cat "$CLAIM_ACK" 2>/dev/null || true)
  elif done_ack_is_valid "${FINALIZING_DONE_ACK:-}"; then
    claim_ack=$FINALIZING_DONE_ACK
  else
    echo "error: teardown proof claim for $ID has no completion acknowledgement" >&2
    return 1
  fi
  done_ack_is_valid "$claim_ack" || {
    echo "error: teardown proof claim for $ID has no valid completion acknowledgement" >&2
    return 1
  }
  [ ! -f "$CLAIMED_PROOF" ] || proof_present=1
  if [ "$proof_present" -eq 1 ]; then
    proof_ack=$(proof_done_ack "$CLAIMED_PROOF" "$ID") || {
      echo "error: teardown proof claim for $ID is not bound to its completion acknowledgement" >&2
      return 1
    }
    [ "$proof_ack" = "$claim_ack" ] || {
      echo "error: teardown proof claim for $ID does not match its completion acknowledgement" >&2
      return 1
    }
  elif [ -f "$COMPLETION_PROOF" ] && [ ! -L "$COMPLETION_PROOF" ]; then
    proof_ack=$(proof_done_ack "$COMPLETION_PROOF" "$ID") || return 1
    [ "$proof_ack" = "$claim_ack" ] || return 1
  fi
  show_status=0
  task_info=$(run_tasks_axi show "$ID" --full 2>&1) || show_status=$?
  if [ "$show_status" -ne 0 ]; then
    if printf '%s\n' "$task_info" | grep -Fx 'code: NOT_FOUND' >/dev/null \
      && archive_has_done_ack "$ID" "$claim_ack"; then
      task_state=done
      completion_acked=1
    else
      echo "error: could not determine backlog state while recovering the teardown proof claim for $ID" >&2
      return 1
    fi
  else
    task_state=$(printf '%s\n' "$task_info" | sed -n 's/^[[:space:]]*state:[[:space:]]*//p' | head -n 1)
    if [ "$task_state" = done ] && output_has_done_ack "$task_info" "$claim_ack"; then
      completion_acked=1
    fi
  fi
  if [ -z "$task_state" ]; then
    echo "error: could not determine backlog state while recovering the teardown proof claim for $ID" >&2
    return 1
  fi
  if [ "$task_state" = done ] && [ "$completion_acked" -eq 1 ]; then
    rm -f "$CLAIMED_PROOF" || return 1
    rm -f "$CLAIM_ACK" || return 1
    rmdir "$CLAIM_DIR" || return 1
    CLAIMED_PROOF=
    CLAIM_ACK=
    CLAIM_DIR=
    CLAIM_SETTLED_STATE=done
    return 0
  fi
  case "$task_state" in
    queued|in_flight)
      if [ "$proof_present" -ne 1 ]; then
        if [ -f "$COMPLETION_PROOF" ] && [ ! -L "$COMPLETION_PROOF" ] \
          && rm -f "$CLAIM_ACK" && rmdir "$CLAIM_DIR"; then
          CLAIMED_PROOF=
          CLAIM_ACK=
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
      rm -f "$CLAIM_ACK" || return 1
      rmdir "$CLAIM_DIR" || return 1
      CLAIMED_PROOF=
      CLAIM_ACK=
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
  CLAIM_ACK="$CLAIM_DIR/done-ack"
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
    $1 == "done-ack" { acks++; ack = substr($0, index($0, "=") + 1) }
    $1 == "aux-cksum" { auxes++; aux = substr($0, index($0, "=") + 1) }
    { lines++ }
    END {
      exit !(versions == 1 && version == "4" && tasks == 1 && task == id \
        && phases == 1 && phase == "backlog-done-started" \
        && metas == 1 && meta_cksum == want_meta_cksum \
        && records == 1 && record_cksum != "" \
        && identities == 1 && identity != "" \
        && markers == 1 && marker != "" \
        && tokens == 1 && token != "" \
        && forces == 1 && force == "0" \
        && outcomes == 1 && outcome ~ /^delivered-(report|local|pr|default)$/ \
        && acks == 1 && length(ack) == 32 && ack !~ /[^0-9a-f]/ \
        && auxes == 1 && aux != "" && lines == 12 \
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
CLAIM_ACK=
CLAIM_DIR=
CLAIM_SETTLED_STATE=
MUTATION_RECEIPT_DIR=
MUTATION_SNAPSHOT_BEFORE=
MUTATION_COMMAND_SUCCEEDED=0
MUTATION_DURABLE=0
MUTATION_SCOPE=
MUTATION_ID=

mutation_files_snapshot() {
  local path
  for path in "$BACKLOG" "$ARCHIVE_PATH"; do
    if [ -L "$path" ]; then
      printf 'symlink:%s:%s\n' "$path" "$(readlink "$path" 2>/dev/null || true)"
    elif [ -f "$path" ]; then
      printf 'file:%s:' "$path"
      cksum < "$path" || return 1
    elif [ -e "$path" ]; then
      printf 'other:%s\n' "$path"
    else
      printf 'absent:%s\n' "$path"
    fi
  done
}

mutation_claim_is_removable() {
  local claim=$1 entry name
  [ -L "$claim" ] && return 0
  [ -d "$claim" ] || return 0
  for entry in "$claim"/* "$claim"/.[!.]* "$claim"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=$(basename "$entry")
    case "$name" in
      proof|done-ack) [ ! -d "$entry" ] || return 1 ;;
      *) return 1 ;;
    esac
  done
}

mutation_receipt_claim_is_valid() {
  local claim=$1 entry name snapshots=0
  [ -d "$claim" ] && [ ! -L "$claim" ] || return 1
  for entry in "$claim"/* "$claim"/.[!.]* "$claim"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=$(basename "$entry")
    case "$name" in
      snapshot-before)
        [ -f "$entry" ] && [ ! -L "$entry" ] || return 1
        snapshots=$((snapshots + 1))
        ;;
      backend-owner|backend-start)
        [ -f "$entry" ] && [ ! -L "$entry" ] || return 1
        ;;
      *.teardown-complete)
        [ ! -d "$entry" ] && [ ! -L "$entry" ] || return 1
        ;;
      .*.teardown-complete.claimed.*)
        mutation_claim_is_removable "$entry" || return 1
        ;;
      *) return 1 ;;
    esac
  done
  [ "$snapshots" -eq 1 ]
}

mutation_backend_owner_is_live() {
  local claim=$1 owner pid recorded_identity current_identity process_state
  owner="$claim/backend-owner"
  [ -f "$owner" ] && [ ! -L "$owner" ] || return 1
  pid=$(sed -n '1p' "$owner") || return 2
  recorded_identity=$(sed -n '2,$p' "$owner") || return 2
  case "$pid" in ''|*[!0-9]*) return 2 ;; esac
  [ -n "$recorded_identity" ] || return 2
  [ -z "$(sed -n '3p' "$owner")" ] || return 2
  kill -0 "$pid" 2>/dev/null || return 1
  process_state=$(ps -p "$pid" -o stat= 2>/dev/null) || return 2
  read -r process_state _ <<< "$process_state"
  case "$process_state" in Z*) return 1 ;; '') return 2 ;; esac
  current_identity=$(mutation_backend_pid_identity "$pid") || return 2
  [ "$current_identity" = "$recorded_identity" ]
}

mutation_backend_pid_identity() {
  local identity
  identity=$(LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null) || return 1
  identity=$(printf '%s\n' "$identity" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$identity" ] || return 1
  printf '%s\n' "$identity"
}

restore_mutation_receipts() {
  local held destination name
  [ -n "$MUTATION_RECEIPT_DIR" ] || return 0
  for held in "$MUTATION_RECEIPT_DIR"/* "$MUTATION_RECEIPT_DIR"/.[!.]* "$MUTATION_RECEIPT_DIR"/..?*; do
    [ -e "$held" ] || [ -L "$held" ] || continue
    name=$(basename "$held")
    case "$name" in
      snapshot-before) continue ;;
      backend-owner|backend-start|.backend-owner.tmp|.backend-start.tmp)
        rm -f "$held" || return 1
        continue
        ;;
    esac
    destination="$STATE/$name"
    if [ -e "$destination" ] || [ -L "$destination" ] || ! mv "$held" "$destination"; then
      return 1
    fi
  done
  rm -f "$MUTATION_RECEIPT_DIR/snapshot-before" || return 1
  rmdir "$MUTATION_RECEIPT_DIR" || return 1
  MUTATION_RECEIPT_DIR=
}

discard_mutation_receipts() {
  local held name status=0
  [ -n "$MUTATION_RECEIPT_DIR" ] || return 0
  for held in "$MUTATION_RECEIPT_DIR"/* "$MUTATION_RECEIPT_DIR"/.[!.]* "$MUTATION_RECEIPT_DIR"/..?*; do
    [ -e "$held" ] || [ -L "$held" ] || continue
    name=$(basename "$held")
    case "$name" in
      snapshot-before|backend-owner|backend-start|.backend-owner.tmp|.backend-start.tmp)
        rm -f "$held" || status=1
        ;;
      *.teardown-complete) rm -f "$held" || status=1 ;;
      .*.teardown-complete.claimed.*) fm_tasks_axi_remove_completion_claim "$held" || status=1 ;;
      *) status=1 ;;
    esac
  done
  [ "$status" -eq 0 ] && rmdir "$MUTATION_RECEIPT_DIR" || status=1
  if [ "$status" -eq 0 ]; then
    MUTATION_RECEIPT_DIR=
  fi
  return "$status"
}

prepare_mutation_transaction() {
  MUTATION_RECEIPT_DIR=$(mktemp -d "$STATE/.backlog-receipts.claimed.XXXXXXXX") || return 1
  if ! printf '%s\n' "$MUTATION_SNAPSHOT_BEFORE" > "$MUTATION_RECEIPT_DIR/.snapshot-before.tmp" \
     || ! mv "$MUTATION_RECEIPT_DIR/.snapshot-before.tmp" "$MUTATION_RECEIPT_DIR/snapshot-before"; then
    rm -f "$MUTATION_RECEIPT_DIR/.snapshot-before.tmp" 2>/dev/null || true
    rmdir "$MUTATION_RECEIPT_DIR" 2>/dev/null || true
    MUTATION_RECEIPT_DIR=
    return 1
  fi
}

claim_mutation_receipts() {
  local scope=$1 id=${2:-} candidate name candidate_count=0 candidate_index=0
  local -a candidates
  if [ "$scope" = all ]; then
    for candidate in "$STATE"/*.teardown-complete "$STATE"/.*.teardown-complete.claimed.*; do
      [ -e "$candidate" ] || [ -L "$candidate" ] || continue
      candidates[$candidate_count]=$candidate
      candidate_count=$((candidate_count + 1))
    done
  else
    candidate="$STATE/$id.teardown-complete"
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then
      candidates[$candidate_count]=$candidate
      candidate_count=$((candidate_count + 1))
    fi
    for candidate in "$STATE"/."$id".teardown-complete.claimed.*; do
      [ -e "$candidate" ] || [ -L "$candidate" ] || continue
      candidates[$candidate_count]=$candidate
      candidate_count=$((candidate_count + 1))
    done
  fi
  while [ "$candidate_index" -lt "$candidate_count" ]; do
    candidate=${candidates[$candidate_index]}
    name=$(basename "$candidate")
    case "$name" in
      *.teardown-complete) [ ! -d "$candidate" ] || return 1 ;;
      .*.teardown-complete.claimed.*) mutation_claim_is_removable "$candidate" || return 1 ;;
      *) return 1 ;;
    esac
    candidate_index=$((candidate_index + 1))
  done
  prepare_mutation_transaction || return 1
  candidate_index=0
  while [ "$candidate_index" -lt "$candidate_count" ]; do
    candidate=${candidates[$candidate_index]}
    if ! mv "$candidate" "$MUTATION_RECEIPT_DIR/"; then
      restore_mutation_receipts || true
      return 1
    fi
    candidate_index=$((candidate_index + 1))
  done
}

recover_mutation_receipt_claims() {
  local claim entry name has_receipt snapshot_before snapshot_after cleanup_only owner_status
  for claim in "$STATE"/.backlog-receipts.claimed.*; do
    [ -e "$claim" ] || [ -L "$claim" ] || continue
    [ -d "$claim" ] && [ ! -L "$claim" ] || return 1
    if [ ! -f "$claim/snapshot-before" ] || [ -L "$claim/snapshot-before" ]; then
      has_receipt=0
      cleanup_only=1
      for entry in "$claim"/* "$claim"/.[!.]* "$claim"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        name=$(basename "$entry")
        case "$name" in
          .snapshot-before.tmp) ;;
          *.teardown-complete|.*.teardown-complete.claimed.*) has_receipt=1 ;;
          *) cleanup_only=0 ;;
        esac
      done
      [ "$has_receipt" -eq 0 ] && [ "$cleanup_only" -eq 1 ] || return 1
      rm -f "$claim/.snapshot-before.tmp" || return 1
      rmdir "$claim" || return 1
      continue
    fi
    if [ -e "$claim/.backend-owner.tmp" ] || [ -e "$claim/.backend-start.tmp" ]; then
      [ ! -e "$claim/backend-start" ] || return 1
      rm -f "$claim/.backend-owner.tmp" "$claim/.backend-start.tmp" || return 1
    fi
    if [ -e "$claim/backend-start" ] && [ ! -e "$claim/backend-owner" ]; then
      return 1
    fi
    mutation_receipt_claim_is_valid "$claim" || return 1
    owner_status=0
    mutation_backend_owner_is_live "$claim" || owner_status=$?
    case "$owner_status" in
      0|2) return 1 ;;
    esac
    snapshot_before=$(cat "$claim/snapshot-before") || return 1
    snapshot_after=$(mutation_files_snapshot) || return 1
    MUTATION_RECEIPT_DIR=$claim
    if [ "$snapshot_after" = "$snapshot_before" ]; then
      restore_mutation_receipts || return 1
    else
      discard_mutation_receipts || return 1
    fi
  done
}

settle_mutation_receipts() {
  local snapshot_after owner_status=0
  [ -n "$MUTATION_RECEIPT_DIR" ] || return 0
  mutation_backend_owner_is_live "$MUTATION_RECEIPT_DIR" || owner_status=$?
  case "$owner_status" in
    0|2)
      MUTATION_RECEIPT_DIR=
      return 1
      ;;
  esac
  if [ "$MUTATION_COMMAND_SUCCEEDED" -eq 1 ]; then
    discard_mutation_receipts
    return $?
  fi
  snapshot_after=$(mutation_files_snapshot) || {
    discard_mutation_receipts
    return 1
  }
  if [ "$snapshot_after" = "$MUTATION_SNAPSHOT_BEFORE" ]; then
    restore_mutation_receipts
  else
    discard_mutation_receipts
  fi
}

run_mutation_tasks_axi() {
  local owner gate owner_tmp gate_tmp worker_pid worker_identity current_identity previous_identity=
  local parent_pid i=0 status=0
  owner="$MUTATION_RECEIPT_DIR/backend-owner"
  gate="$MUTATION_RECEIPT_DIR/backend-start"
  owner_tmp="$MUTATION_RECEIPT_DIR/.backend-owner.tmp"
  gate_tmp="$MUTATION_RECEIPT_DIR/.backend-start.tmp"
  parent_pid=${BASHPID:-$$}
  (
    local wait_count=0
    while [ ! -e "$gate" ]; do
      fm_pid_alive "$parent_pid" || exit 125
      [ "$wait_count" -lt 200 ] || exit 125
      sleep 0.05
      wait_count=$((wait_count + 1))
    done
    cd "$FM_HOME" || exit 1
    HOME="$FM_HOME" exec tasks-axi "$@" --backend markdown --file "$BACKLOG"
  ) &
  worker_pid=$!
  while [ "$i" -lt 40 ]; do
    current_identity=$(mutation_backend_pid_identity "$worker_pid" 2>/dev/null || true)
    if [ -n "$current_identity" ] && [ -n "$previous_identity" ] \
       && [ "$current_identity" = "$previous_identity" ]; then
      worker_identity=$current_identity
      break
    fi
    previous_identity=$current_identity
    sleep 0.01
    i=$((i + 1))
  done
  if [ -z "${worker_identity:-}" ]; then
    kill -TERM "$worker_pid" 2>/dev/null || true
    wait "$worker_pid" 2>/dev/null || true
    return 1
  fi
  if ! { printf '%s\n' "$worker_pid"; printf '%s\n' "$worker_identity"; } > "$owner_tmp" \
     || ! mv "$owner_tmp" "$owner"; then
    kill -TERM "$worker_pid" 2>/dev/null || true
    wait "$worker_pid" 2>/dev/null || true
    rm -f "$owner_tmp"
    return 1
  fi
  current_identity=$(mutation_backend_pid_identity "$worker_pid" 2>/dev/null || true)
  if ! fm_pid_alive "$worker_pid" || [ "$current_identity" != "$worker_identity" ] \
     || ! : > "$gate_tmp" || ! mv "$gate_tmp" "$gate"; then
    kill -TERM "$worker_pid" 2>/dev/null || true
    wait "$worker_pid" 2>/dev/null || true
    rm -f "$owner" "$owner_tmp" "$gate" "$gate_tmp"
    return 1
  fi
  wait "$worker_pid" || status=$?
  rm -f "$owner" "$gate" "$owner_tmp" "$gate_tmp" 2>/dev/null || true
  return "$status"
}

stop_owned_mutation_backend() {
  local owner_status=0 pid i=0
  [ -n "$MUTATION_RECEIPT_DIR" ] || return 0
  mutation_backend_owner_is_live "$MUTATION_RECEIPT_DIR" || owner_status=$?
  case "$owner_status" in
    1) return 0 ;;
    2) return 1 ;;
  esac
  pid=$(sed -n '1p' "$MUTATION_RECEIPT_DIR/backend-owner") || return 1
  mutation_backend_owner_is_live "$MUTATION_RECEIPT_DIR" || return 1
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt 40 ]; do
    owner_status=0
    mutation_backend_owner_is_live "$MUTATION_RECEIPT_DIR" || owner_status=$?
    [ "$owner_status" -eq 0 ] || break
    sleep 0.05
    i=$((i + 1))
  done
  owner_status=0
  mutation_backend_owner_is_live "$MUTATION_RECEIPT_DIR" || owner_status=$?
  if [ "$owner_status" -eq 0 ]; then
    mutation_backend_owner_is_live "$MUTATION_RECEIPT_DIR" || return 1
    kill -KILL "$pid" 2>/dev/null || true
  elif [ "$owner_status" -eq 2 ]; then
    return 1
  fi
  wait "$pid" 2>/dev/null || true
  owner_status=0
  mutation_backend_owner_is_live "$MUTATION_RECEIPT_DIR" || owner_status=$?
  [ "$owner_status" -eq 1 ]
}

release_backlog_lock() {
  if [ "$LOCKED" -eq 1 ]; then
    fm_lock_release "$BACKLOG_LOCK"
    LOCKED=0
  fi
}
cleanup_backlog_wrapper() {
  local status=$?
  trap - EXIT INT TERM
  if ! stop_owned_mutation_backend; then
    [ "$status" -ne 0 ] || status=1
    release_backlog_lock
    exit "$status"
  fi
  if [ -n "${CLAIM_DIR:-}" ] && ! completion_claim_settle; then
    [ "$status" -ne 0 ] || status=1
  fi
  if [ -n "${MUTATION_RECEIPT_DIR:-}" ] && ! settle_mutation_receipts; then
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
if ! recover_mutation_receipt_claims; then
  echo "error: interrupted backlog mutation receipts could not be reconciled safely" >&2
  exit 1
fi

if [ "$COMMAND" = "done" ] && [ "$HELP" -eq 0 ]; then
  COMPLETION_PROOF="$STATE/$ID.teardown-complete"
  FINALIZING_STAGE=0
  FINALIZING_OUTCOME=
  FINALIZING_RECORD_CKSUM=
  FINALIZING_DONE_ACK=
  if finalizing_stage_is_owned "$STATE/$ID.teardown-stage" "$ID"; then
    FINALIZING_STAGE=1
    FINALIZING_OUTCOME=$(sed -n 's/^outcome=//p' "$STATE/$ID.teardown-stage")
    FINALIZING_RECORD_CKSUM=$(sed -n 's/^record-cksum=//p' "$STATE/$ID.teardown-stage")
    FINALIZING_DONE_ACK=$(sed -n 's/^done-ack=//p' "$STATE/$ID.teardown-stage")
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
       && [ "$(printf '%s\n' "$FINALIZING_INFO" | sed -n 's/^[[:space:]]*state:[[:space:]]*//p' | head -1)" = done ] \
       && output_has_done_ack "$FINALIZING_INFO" "$FINALIZING_DONE_ACK"; then
      echo "Done for $ID was already recorded before teardown finalization completed."
      exit 0
    fi
    if [ "$FINALIZING_INFO_STATUS" -ne 0 ] \
       && printf '%s\n' "$FINALIZING_INFO" | grep -Fx 'code: NOT_FOUND' >/dev/null \
       && archive_has_done_ack "$ID" "$FINALIZING_DONE_ACK"; then
      echo "Done for $ID was already archived before teardown finalization completed."
      exit 0
    fi
  fi
  if [ -L "$COMPLETION_PROOF" ] || [ ! -f "$COMPLETION_PROOF" ]; then
    echo "REFUSED: task $ID has no durable successful-teardown proof." >&2
    echo "Run bin/fm-teardown.sh $ID successfully; never-dispatched work must be removed or cancelled instead of recorded Done." >&2
    exit 1
  fi
  PROOF_KIND=$(sed -n 's/^kind=//p' "$COMPLETION_PROOF" | tail -1)
  PROOF_OUTCOME=$(sed -n 's/^outcome=//p' "$COMPLETION_PROOF" | tail -1)
  PROOF_RECORD_CKSUM=$(sed -n 's/^record-cksum=//p' "$COMPLETION_PROOF" | tail -1)
  PROOF_DONE_ACK=$(proof_done_ack "$COMPLETION_PROOF" "$ID") || {
    echo "REFUSED: teardown proof is not bound to task $ID." >&2
    exit 1
  }
  if [ "$FINALIZING_STAGE" -eq 1 ] \
     && { [ "$PROOF_OUTCOME" != "$FINALIZING_OUTCOME" ] \
       || [ "$PROOF_RECORD_CKSUM" != "$FINALIZING_RECORD_CKSUM" ] \
       || [ "$PROOF_DONE_ACK" != "$FINALIZING_DONE_ACK" ]; }; then
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
  CLAIM_ACK="$CLAIM_DIR/done-ack"
  if ! printf '%s\n' "$PROOF_DONE_ACK" > "$CLAIM_ACK"; then
    rmdir "$CLAIM_DIR" 2>/dev/null || true
    echo "error: could not persist completion acknowledgement for $ID" >&2
    exit 1
  fi
  if ! mv "$COMPLETION_PROOF" "$CLAIMED_PROOF"; then
    rm -f "$CLAIM_ACK" 2>/dev/null || true
    rmdir "$CLAIM_DIR" 2>/dev/null || true
    echo "REFUSED: teardown proof for $ID could not be claimed for single use." >&2
    exit 1
  fi
  DONE_ARGS=()
  DONE_NOTE_ADDED=0
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --note ] && [ "$#" -gt 1 ]; then
      DONE_ARGS+=(--note "$2"$'\n'"$(done_ack_marker "$PROOF_DONE_ACK")")
      DONE_NOTE_ADDED=1
      shift 2
    elif [ "${1#--note=}" != "$1" ]; then
      DONE_ARGS+=(--note "${1#--note=}"$'\n'"$(done_ack_marker "$PROOF_DONE_ACK")")
      DONE_NOTE_ADDED=1
      shift
    else
      DONE_ARGS+=("$1")
      shift
    fi
  done
  if [ "$DONE_NOTE_ADDED" -eq 0 ]; then
    DONE_ARGS+=(--note "$(done_ack_marker "$PROOF_DONE_ACK")")
  fi
  set -- "${DONE_ARGS[@]}"
fi

if [ "$COMMAND_HELP" -eq 0 ]; then
  MUTATION_DURABLE=0
  MUTATION_SCOPE=
  MUTATION_ID=
  case "$COMMAND" in
    add)
      MUTATION_DURABLE=1
      MUTATION_ID=${2:-}
      ADD_MINTED=0
      for arg in "$@"; do
        [ "$arg" != --mint ] || ADD_MINTED=1
      done
      if [ "$ADD_MINTED" -eq 1 ] || ! fm_tasks_axi_valid_task_id "$MUTATION_ID"; then
        MUTATION_SCOPE=all
      else
        MUTATION_SCOPE=id
      fi
      ;;
    start|reopen|update|rm|block|unblock|hold|unhold)
      MUTATION_DURABLE=1
      MUTATION_ID=${2:-}
      if fm_tasks_axi_valid_task_id "$MUTATION_ID"; then
        MUTATION_SCOPE=id
      else
        MUTATION_SCOPE=all
      fi
      ;;
    done)
      MUTATION_DURABLE=1
      ;;
    prune|render|setup)
      MUTATION_DURABLE=1
      MUTATION_SCOPE=all
      ;;
  esac
  if [ "$MUTATION_DURABLE" -eq 1 ]; then
    MUTATION_SNAPSHOT_BEFORE=$(mutation_files_snapshot) || {
      echo "error: backlog state could not be captured before mutation" >&2
      exit 1
    }
    if [ -n "$MUTATION_SCOPE" ] \
       && ! claim_mutation_receipts "$MUTATION_SCOPE" "$MUTATION_ID"; then
      echo "error: completion receipts could not be invalidated safely before backlog mutation" >&2
      exit 1
    elif [ -z "$MUTATION_SCOPE" ] && ! prepare_mutation_transaction; then
      echo "error: durable backlog mutation ownership could not be prepared" >&2
      exit 1
    fi
  fi
fi

if [ "$MUTATION_DURABLE" -eq 1 ]; then
  run_mutation_tasks_axi "$@"
  STATUS=$?
else
  run_tasks_axi "$@"
  STATUS=$?
fi
if [ "$STATUS" -eq 0 ] && [ "$MUTATION_DURABLE" -eq 1 ]; then
  MUTATION_COMMAND_SUCCEEDED=1
fi
if [ "$COMMAND" = "done" ] && [ "${HELP:-0}" -eq 0 ]; then
  if [ "$STATUS" -eq 0 ]; then
    if ! rm -f "$CLAIMED_PROOF" || ! rm -f "$CLAIM_ACK" || ! rmdir "$CLAIM_DIR"; then
      echo "error: Done succeeded but teardown proof claim could not be consumed for $ID" >&2
      STATUS=1
    else
      CLAIMED_PROOF=
      CLAIM_ACK=
      CLAIM_DIR=
    fi
  else
    if mv "$CLAIMED_PROOF" "$COMPLETION_PROOF" \
       && rm -f "$CLAIM_ACK" && rmdir "$CLAIM_DIR"; then
      CLAIMED_PROOF=
      CLAIM_ACK=
      CLAIM_DIR=
    else
      echo "error: Done failed and teardown proof claim could not be restored for $ID" >&2
      STATUS=1
    fi
  fi
fi
if [ -n "$MUTATION_RECEIPT_DIR" ] && ! settle_mutation_receipts; then
  echo "error: backlog mutation receipt claim could not be settled safely" >&2
  STATUS=1
fi
release_backlog_lock
exit "$STATUS"
