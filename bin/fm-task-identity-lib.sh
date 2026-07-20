# shellcheck shell=bash
# Authoritative task-id -> repository identity validation for lifecycle reuse.
#
# fm_task_identity_validate <state-dir> <task-id> <proposed-project>
# fm_task_identity_bind <state-dir> <task-id> <proposed-project>
# fm_task_identity_repository_key <path>
# fm_task_identity_resolve <state-dir> <task-id> <proposed-project>
#
# The durable state/<id>.identity binding outlives volatile task metadata and
# accepts only the same persistent repository instance.  Existing metadata
# bootstraps the binding for pre-registry tasks.  That supports normal
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

fm_task_identity_directory_identity() {  # <path>
  local path=$1 identity
  if [ "$(uname)" = Darwin ]; then
    identity=$(stat -f '%d:%i' "$path" 2>/dev/null) || return 1
  else
    identity=$(stat -c '%d:%i' "$path" 2>/dev/null) || return 1
  fi
  case "$identity" in ''|*[!0-9:]*) return 1 ;; esac
  printf '%s\n' "$identity"
}

fm_task_identity_new_token() {
  local token
  token=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
  [ "${#token}" -eq 32 ] || return 1
  case "$token" in *[!0-9a-f]*) return 1 ;; esac
  printf '%s\n' "$token"
}

fm_task_identity_instance_token() {  # <identity-root> <marker-name>
  local root=$1 marker=$2 file tmp token line
  file="$root/$marker"
  [ ! -L "$file" ] || return 1
  if [ ! -f "$file" ]; then
    token=$(fm_task_identity_new_token) || return 1
    tmp="$file.tmp.${BASHPID:-$$}.$token"
    printf 'fm-repository-instance.v1:%s\n' "$token" > "$tmp" || { rm -f "$tmp"; return 1; }
    if ln "$tmp" "$file" 2>/dev/null; then
      :
    elif [ ! -f "$file" ]; then
      rm -f "$tmp"
      return 1
    fi
    rm -f "$tmp"
  fi
  IFS= read -r line < "$file" || return 1
  case "$line" in fm-repository-instance.v1:*) token=${line#fm-repository-instance.v1:} ;; *) return 1 ;; esac
  [ "${#token}" -eq 32 ] || return 1
  case "$token" in *[!0-9a-f]*) return 1 ;; esac
  printf '%s\n' "$token"
}

fm_task_identity_legacy_repository_key() {  # <path>
  local path=$1 resolved identity
  resolved=$(fm_task_identity_git_common_dir "$path" 2>/dev/null || true)
  if [ -n "$resolved" ]; then
    identity=$(fm_task_identity_directory_identity "$resolved" 2>/dev/null || true)
    [ -n "$identity" ] || return 1
    printf 'git:%s:%s\n' "$identity" "$resolved"
    return 0
  fi
  resolved=$(fm_task_identity_real_dir "$path" 2>/dev/null || true)
  [ -n "$resolved" ] || return 1
  identity=$(fm_task_identity_directory_identity "$resolved" 2>/dev/null || true)
  [ -n "$identity" ] || return 1
  printf 'dir:%s:%s\n' "$identity" "$resolved"
}

fm_task_identity_repository_key() {  # <path>
  local path=$1 resolved token
  resolved=$(fm_task_identity_git_common_dir "$path" 2>/dev/null || true)
  if [ -n "$resolved" ]; then
    token=$(fm_task_identity_instance_token "$resolved" firstmate-repository-id) || return 1
    printf 'git:v3:%s\n' "$token"
    return 0
  fi
  resolved=$(fm_task_identity_real_dir "$path" 2>/dev/null || true)
  [ -n "$resolved" ] || return 1
  token=$(fm_task_identity_instance_token "$resolved" .firstmate-repository-id) || return 1
  printf 'dir:v3:%s\n' "$token"
}

fm_task_identity_meta_value() {  # <meta> <key>
  local meta=$1 key=$2
  [ -f "$meta" ] || return 0
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_task_identity_validate() {  # <state-dir> <task-id> <proposed-project>
  local state=$1 id=$2 proposed=$3 meta identity schema='' recorded='' recorded_key='' proposed_key proposed_legacy_key
  meta="$state/$id.meta"
  identity="$state/$id.identity"
  proposed_key=$(fm_task_identity_repository_key "$proposed" 2>/dev/null || true)
  if [ -f "$identity" ]; then
    schema=$(fm_task_identity_meta_value "$identity" schema)
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
  if [ "$schema" = fm-task-identity.v2 ]; then
    proposed_legacy_key=$(fm_task_identity_legacy_repository_key "$proposed" 2>/dev/null || true)
    if [ -n "$recorded_key" ] && [ "$recorded_key" = "$proposed_legacy_key" ]; then
      return 0
    fi
  fi
  echo "error: task id '$id' is already bound to repository '${recorded:-<unrecorded>}' and cannot be reused for '$proposed'." >&2
  echo "Create a new task id for the cross-repository follow-up and link it from the original task/backlog record." >&2
  return 1
}

fm_task_identity_bind() {  # <state-dir> <task-id> <proposed-project>
  local state=$1 id=$2 proposed=$3 identity lock proposed_key recorded_key schema tmp bind_rc=0 clean_project
  case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid task id '$id' for repository binding." >&2; return 1 ;; esac
  if ! mkdir -p "$state"; then
    echo "error: cannot create task identity state directory '$state'." >&2
    return 1
  fi
  proposed_key=$(fm_task_identity_repository_key "$proposed" 2>/dev/null || true)
  [ -n "$proposed_key" ] || {
    echo "error: cannot prove repository identity for task '$id' from '$proposed'." >&2
    return 1
  }
  identity="$state/$id.identity"
  lock="$state/.task-identity-$id.lock"
  fm_lock_acquire_wait "$lock"
  if fm_task_identity_validate "$state" "$id" "$proposed"; then
    recorded_key=$(fm_task_identity_meta_value "$identity" repository_identity)
    schema=$(fm_task_identity_meta_value "$identity" schema)
    if [ ! -f "$identity" ] || [ "$recorded_key" != "$proposed_key" ] || [ "$schema" != fm-task-identity.v3 ]; then
      tmp="$identity.tmp.${BASHPID:-$$}"
      clean_project=$(printf '%s' "$proposed" | LC_ALL=C tr '\t\r\n' '   ')
      {
        printf 'schema=fm-task-identity.v3\n'
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

fm_task_identity_resolve() {  # <state-dir> <task-id> <proposed-project>
  local state=$1 id=$2 proposed=$3 identity recorded current
  fm_task_identity_bind "$state" "$id" "$proposed" >/dev/null || return 1
  identity="$state/$id.identity"
  recorded=$(fm_task_identity_meta_value "$identity" repository_identity)
  current=$(fm_task_identity_repository_key "$proposed") || return 1
  [ -n "$recorded" ] && [ "$recorded" = "$current" ] || return 1
  printf '%s\n' "$current"
}
