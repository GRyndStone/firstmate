#!/usr/bin/env bash
# Register or clear a task's model-free external-wait completion observer.
#
# Usage:
#   fm-external-wait.sh register-predicate <task-id> <executable> [description]
#   fm-external-wait.sh register-process   <task-id> <pid>        [description]
#   fm-external-wait.sh register-command   <task-id> <pid>        [description]
#   fm-external-wait.sh clear              <task-id>
#
# The validated registration is written atomically to state/<id>.wait using the
# schema owned by bin/fm-reconcile-lib.sh.  A predicate is executed directly with
# no shell evaluation on every durable watcher classification cycle: exit 0 means
# complete, exit 1 means pending, and any other exit or timeout is actionable
# failure.  A process registration captures the exact process identity, so exit
# or pid reuse becomes completion while the same live process remains pending.
# A command registration additionally verifies the process cwd belongs to the
# task's recorded worktree/tasktmp and treats exact-pid descendant CPU/lifecycle
# progress as positive working evidence for a bounded grace window.
#
# Register the observer BEFORE appending paused:/blocked:/parked wait state and
# parking the foreground agent.  The watcher fails loudly on an unobservable
# paused, blocked, or parked task.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-reconcile-lib.sh
. "$SCRIPT_DIR/fm-reconcile-lib.sh"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

command=${1:-}
case "$command" in
  -h|--help) usage; exit 0 ;;
esac
id=${2:-}
[ -n "$command" ] && [ -n "$id" ] || { usage >&2; exit 2; }
case "$id" in
  *[!A-Za-z0-9._-]*|'') echo "error: invalid task id '$id'" >&2; exit 2 ;;
esac
[ -f "$STATE/$id.meta" ] || { echo "error: no task metadata for $id in $STATE; register the wait against the live task id" >&2; exit 1; }

wait_file="$STATE/$id.wait"
wait_commit="$STATE/$id.wait-commit"
mkdir -p "$STATE"
meta="$STATE/$id.meta"
meta_signature=$(fm_reconcile_file_signature "$meta")
lifecycle_generation=$(fm_reconcile_meta_generation "$meta") \
  || { echo "error: cannot resolve task lifecycle generation for $id" >&2; exit 1; }
registration_pid=
registration_identity=
registration_predicate=

registration_still_valid() {
  local current_identity current_cwd
  if [ -n "$registration_predicate" ]; then
    [ -f "$registration_predicate" ] && [ -x "$registration_predicate" ] || return 1
  fi
  if [ -n "$registration_pid" ]; then
    fm_reconcile_pid_alive "$registration_pid" || return 1
    current_identity=$(fm_reconcile_process_identity "$registration_pid") || return 1
    [ "$current_identity" = "$registration_identity" ] || return 1
    if [ "$command" = register-command ]; then
      current_cwd=$(fm_reconcile_process_cwd "$registration_pid") || return 1
      fm_reconcile_path_is_within "$current_cwd" "$worktree" \
        || fm_reconcile_path_is_within "$current_cwd" "$tasktmp" \
        || return 1
    fi
  fi
}

write_wait() {  # <kind> <description> [<extra-key> <extra-value>]...
  local kind=$1 description=$2 tmp key value registration_id write_rc=0 prior_kind
  shift 2
  [ $(( $# % 2 )) -eq 0 ] || return 2
  registration_id=$(fm_task_identity_new_token) || return 1
  tmp="$wait_file.tmp.${BASHPID:-$$}"
  {
    printf 'schema=fm-external-wait.v1\n'
    printf 'kind=%s\n' "$kind"
    printf 'description=%s\n' "$(fm_reconcile_clean_value "$description")"
    printf 'registration_id=%s\n' "$registration_id"
    printf 'lifecycle_generation=%s\n' "$lifecycle_generation"
    while [ "$#" -gt 0 ]; do
      key=$1
      value=$2
      shift 2
      printf '%s=%s\n' "$key" "$(fm_reconcile_clean_value "$value")"
    done
    printf 'registered_at=%s\n' "$(date +%s)"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  fm_reconcile_lock_acquire "$STATE" "$id"
  prior_kind=$(fm_reconcile_record_value "$wait_file" kind)
  if ! fm_reconcile_meta_matches "$STATE" "$id" "$meta_signature" "$lifecycle_generation"; then
    echo "error: task $id lifecycle changed while registering its external wait" >&2
    write_rc=1
  elif ! registration_still_valid; then
    echo "error: external-wait target changed before registration for task $id" >&2
    write_rc=1
  elif ! mv -f "$tmp" "$wait_file"; then
    write_rc=1
  elif [ "$prior_kind" = legacy-check ]; then
    rm -f "$STATE/$id.check.sh" "$wait_commit" || write_rc=$?
  else
    rm -f "$wait_commit" || write_rc=$?
  fi
  fm_reconcile_lock_release "$STATE" "$id"
  [ "$write_rc" -eq 0 ] || rm -f "$tmp"
  return "$write_rc"
}

case "$command" in
  register-predicate)
    predicate=${3:-}
    description=${4:-external completion predicate}
    [ -n "$predicate" ] || { usage >&2; exit 2; }
    [ -f "$predicate" ] && [ -x "$predicate" ] \
      || { echo "error: predicate must be an existing executable file: $predicate" >&2; exit 1; }
    predicate_dir=$(cd "$(dirname "$predicate")" && pwd -P)
    predicate="$predicate_dir/$(basename "$predicate")"
    registration_predicate=$predicate
    write_wait predicate "$description" predicate "$predicate"
    echo "registered external wait for $id: predicate $predicate"
    ;;
  register-process)
    pid=${3:-}
    description=${4:-tracked background process}
    case "$pid" in ''|*[!0-9]*) echo "error: process pid must be decimal" >&2; exit 2 ;; esac
    fm_reconcile_pid_alive "$pid" || { echo "error: process $pid is not alive; refusing an already-stale wait registration" >&2; exit 1; }
    identity=$(fm_reconcile_process_identity "$pid") \
      || { echo "error: could not capture a stable identity for process $pid" >&2; exit 1; }
    registration_pid=$pid
    registration_identity=$identity
    write_wait process "$description" pid "$pid" pid_identity "$identity"
    echo "registered external wait for $id: process $pid"
    ;;
  register-command)
    pid=${3:-}
    description=${4:-task-owned background command}
    case "$pid" in ''|*[!0-9]*) echo "error: command pid must be decimal" >&2; exit 2 ;; esac
    command -v pgrep >/dev/null 2>&1 \
      || { echo "error: pgrep is required to observe exact-pid descendant progress" >&2; exit 1; }
    fm_reconcile_pid_alive "$pid" \
      || { echo "error: command $pid is not alive; refusing an already-stale registration" >&2; exit 1; }
    identity=$(fm_reconcile_process_identity "$pid") \
      || { echo "error: could not capture a stable identity for command $pid" >&2; exit 1; }
    process_cwd=$(fm_reconcile_process_cwd "$pid") \
      || { echo "error: could not read cwd for command $pid; task ownership is not provable" >&2; exit 1; }
    worktree=$(fm_reconcile_meta_value "$meta" worktree)
    tasktmp=$(fm_reconcile_meta_value "$meta" tasktmp)
    if [ -n "$worktree" ] && [ -d "$worktree" ]; then worktree=$(cd "$worktree" && pwd -P); else worktree=''; fi
    if [ -n "$tasktmp" ] && [ -d "$tasktmp" ]; then tasktmp=$(cd "$tasktmp" && pwd -P); else tasktmp=''; fi
    if ! fm_reconcile_path_is_within "$process_cwd" "$worktree" \
      && ! fm_reconcile_path_is_within "$process_cwd" "$tasktmp"; then
      echo "error: command $pid cwd $process_cwd is outside task $id worktree/tasktmp; launch it inside the task workspace or create a linked task" >&2
      exit 1
    fi
    grace=${FM_OWNED_COMMAND_PROGRESS_GRACE:-300}
    case "$grace" in ''|*[!0-9]*|0) echo "error: FM_OWNED_COMMAND_PROGRESS_GRACE must be a positive integer" >&2; exit 2 ;; esac
    fm_reconcile_process_tree_signature "$pid" >/dev/null \
      || { echo "error: command $pid has no observable exact-pid process tree" >&2; exit 1; }
    registration_pid=$pid
    registration_identity=$identity
    write_wait process "$description" \
      pid "$pid" \
      pid_identity "$identity" \
      role working-command \
      progress_grace "$grace" \
      owner_worktree "$worktree" \
      owner_tasktmp "$tasktmp"
    echo "registered task-owned working command for $id: process $pid (progress grace ${grace}s)"
    ;;
  clear)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    wait_signature=$(fm_reconcile_file_signature "$wait_file")
    wait_registration_id=$(fm_reconcile_record_value "$wait_file" registration_id)
    fm_reconcile_lock_acquire "$STATE" "$id"
    clear_rc=0
    if ! fm_reconcile_meta_matches "$STATE" "$id" "$meta_signature" "$lifecycle_generation"; then
      echo "error: task $id lifecycle changed while clearing its external wait" >&2
      clear_rc=1
    elif [ "$(fm_reconcile_file_signature "$wait_file")" != "$wait_signature" ] \
      || [ "$(fm_reconcile_record_value "$wait_file" registration_id)" != "$wait_registration_id" ]; then
      echo "error: task $id external-wait registration changed while clear was pending" >&2
      clear_rc=1
    else
      if [ "$(fm_reconcile_record_value "$wait_file" kind)" = legacy-check ]; then
        rm -f "$wait_file" "$STATE/$id.check.sh" "$wait_commit" || clear_rc=$?
      else
        rm -f "$wait_file" "$wait_commit" || clear_rc=$?
      fi
    fi
    fm_reconcile_lock_release "$STATE" "$id"
    [ "$clear_rc" -eq 0 ] || exit "$clear_rc"
    echo "cleared external wait for $id"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
