# shellcheck shell=bash
# Authoritative task-id -> repository identity validation for lifecycle reuse.
#
# fm_task_identity_validate <state-dir> <task-id> <proposed-project>
# fm_task_identity_bind <state-dir> <task-id> <proposed-project>
# fm_task_identity_repository_key <path>
#
# The durable state/<id>.identity binding outlives volatile task metadata and
# accepts only the same physical directory or git common directory.  Existing
# metadata bootstraps the binding for pre-registry tasks.  That supports normal
# same-repository recovery and delivery worktree changes while refusing silent
# migration to an unrelated repository.

_FM_TASK_IDENTITY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_TASK_IDENTITY_LIB_DIR="."
# shellcheck source=bin/fm-wake-lib.sh
. "$_FM_TASK_IDENTITY_LIB_DIR/fm-wake-lib.sh"

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

fm_task_identity_repository_key() {  # <path>
  local path=$1 resolved
  resolved=$(fm_task_identity_git_common_dir "$path" 2>/dev/null || true)
  if [ -n "$resolved" ]; then
    printf 'git:%s\n' "$resolved"
    return 0
  fi
  resolved=$(fm_task_identity_real_dir "$path" 2>/dev/null || true)
  [ -n "$resolved" ] || return 1
  printf 'dir:%s\n' "$resolved"
}

fm_task_identity_meta_value() {  # <meta> <key>
  local meta=$1 key=$2
  [ -f "$meta" ] || return 0
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_task_identity_validate() {  # <state-dir> <task-id> <proposed-project>
  local state=$1 id=$2 proposed=$3 meta identity recorded recorded_key proposed_key
  meta="$state/$id.meta"
  identity="$state/$id.identity"
  proposed_key=$(fm_task_identity_repository_key "$proposed" 2>/dev/null || true)
  if [ -f "$identity" ]; then
    recorded=$(fm_task_identity_meta_value "$identity" project)
    recorded_key=$(fm_task_identity_meta_value "$identity" repository_identity)
  elif [ -f "$meta" ]; then
    recorded=$(fm_task_identity_meta_value "$meta" project)
    recorded_key=$(fm_task_identity_repository_key "$recorded" 2>/dev/null || true)
  else
    return 0
  fi
  if [ -n "$recorded_key" ] && [ "$recorded_key" = "$proposed_key" ]; then
    return 0
  fi
  echo "error: task id '$id' is already bound to repository '${recorded:-<unrecorded>}' and cannot be reused for '$proposed'." >&2
  echo "Create a new task id for the cross-repository follow-up and link it from the original task/backlog record." >&2
  return 1
}

fm_task_identity_bind() {  # <state-dir> <task-id> <proposed-project>
  local state=$1 id=$2 proposed=$3 identity lock proposed_key tmp bind_rc=0 clean_project
  case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid task id '$id' for repository binding." >&2; return 1 ;; esac
  proposed_key=$(fm_task_identity_repository_key "$proposed" 2>/dev/null || true)
  [ -n "$proposed_key" ] || {
    echo "error: cannot prove repository identity for task '$id' from '$proposed'." >&2
    return 1
  }
  identity="$state/$id.identity"
  lock="$state/.task-identity-$id.lock"
  fm_lock_acquire_wait "$lock"
  if fm_task_identity_validate "$state" "$id" "$proposed"; then
    if [ ! -f "$identity" ]; then
      tmp="$identity.tmp.${BASHPID:-$$}"
      clean_project=$(printf '%s' "$proposed" | LC_ALL=C tr '\t\r\n' '   ')
      {
        printf 'schema=fm-task-identity.v1\n'
        printf 'task=%s\n' "$id"
        printf 'repository_identity=%s\n' "$proposed_key"
        printf 'project=%s\n' "$clean_project"
      } > "$tmp" || bind_rc=$?
      if [ "$bind_rc" -eq 0 ]; then
        mv -f "$tmp" "$identity" || bind_rc=$?
        [ "$bind_rc" -eq 0 ] || rm -f "$tmp"
      else
        rm -f "$tmp"
      fi
    fi
  else
    bind_rc=$?
  fi
  fm_lock_release "$lock"
  return "$bind_rc"
}
