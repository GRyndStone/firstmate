# shellcheck shell=bash
# Authoritative task-id -> repository identity validation for lifecycle reuse.
#
# fm_task_identity_validate <state-dir> <task-id> <proposed-project>
#
# A new id (no meta) is accepted.  An existing id is accepted only when the
# recorded project and proposed project resolve to the same physical directory
# or the same git common directory.  That supports normal same-repository
# recovery and delivery worktree changes while refusing silent migration to an
# unrelated repository.  An absent/unresolvable recorded identity fails closed.

fm_task_identity_real_dir() {  # <path>
  [ -d "$1" ] || return 1
  (cd "$1" && pwd -P)
}

fm_task_identity_git_common_dir() {  # <path>
  local path=$1 common parent
  [ -d "$path" ] || return 1
  common=$(git -C "$path" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) parent=$common ;;
    *) parent="$path/$common" ;;
  esac
  if [ -d "$parent" ]; then
    (cd "$parent" && pwd -P)
  else
    return 1
  fi
}

fm_task_identity_meta_value() {  # <meta> <key>
  local meta=$1 key=$2
  [ -f "$meta" ] || return 0
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_task_identity_validate() {  # <state-dir> <task-id> <proposed-project>
  local state=$1 id=$2 proposed=$3 meta recorded recorded_real proposed_real recorded_git proposed_git
  meta="$state/$id.meta"
  [ -f "$meta" ] || return 0
  recorded=$(fm_task_identity_meta_value "$meta" project)
  recorded_real=$(fm_task_identity_real_dir "$recorded" 2>/dev/null || true)
  proposed_real=$(fm_task_identity_real_dir "$proposed" 2>/dev/null || true)
  if [ -n "$recorded_real" ] && [ "$recorded_real" = "$proposed_real" ]; then
    return 0
  fi
  recorded_git=$(fm_task_identity_git_common_dir "$recorded" 2>/dev/null || true)
  proposed_git=$(fm_task_identity_git_common_dir "$proposed" 2>/dev/null || true)
  if [ -n "$recorded_git" ] && [ "$recorded_git" = "$proposed_git" ]; then
    return 0
  fi
  echo "error: task id '$id' is already bound to repository '${recorded:-<unrecorded>}' and cannot be reused for '$proposed'." >&2
  echo "Create a new task id for the cross-repository follow-up and link it from the original task/backlog record." >&2
  return 1
}
