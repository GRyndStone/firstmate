#!/usr/bin/env bash
# Shared durable wake queue and portable lock helpers.

FM_WAKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WAKE_DEFAULT_ROOT="$(cd "$FM_WAKE_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_WAKE_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
FM_LOCK_STALE_AFTER="${FM_LOCK_STALE_AFTER:-2}"

FM_VALIDATED_STATE_PATH=
fm_validate_effective_state_path() {
  local path=$1 mode=${2:-allow-missing-final} component suffix cursor=/ parent
  FM_VALIDATED_STATE_PATH=
  case "$path" in /*) ;; *) path="$PWD/$path" ;; esac
  if [ "$(uname)" = Darwin ]; then
    case "$path" in
      /var/*|/tmp/*) path="/private$path" ;;
    esac
  fi
  suffix=${path#/}
  while [ -n "$suffix" ]; do
    component=${suffix%%/*}
    if [ "$suffix" = "$component" ]; then suffix=; else suffix=${suffix#*/}; fi
    [ -n "$component" ] || continue
    case "$component" in
      .|..)
        echo "error: unsafe effective state path component: $component" >&2
        return 1
        ;;
    esac
    cursor=${cursor%/}/$component
    if [ -L "$cursor" ]; then
      echo "error: symlinked effective state path component refused: $cursor" >&2
      return 1
    fi
    if [ -e "$cursor" ] && [ ! -d "$cursor" ]; then
      echo "error: non-directory effective state path component refused: $cursor" >&2
      return 1
    fi
    if [ ! -e "$cursor" ] && [ -n "$suffix" ]; then
      echo "error: missing effective state path parent: $cursor" >&2
      return 1
    fi
  done
  if [ ! -e "$path" ]; then
    [ "$mode" = allow-missing-final ] || {
      echo "error: effective state directory does not exist: $path" >&2
      return 1
    }
    parent=${path%/*}
    [ -n "$parent" ] || parent=/
    [ -d "$parent" ] && [ ! -L "$parent" ] || {
      echo "error: effective state parent is not a regular directory: $parent" >&2
      return 1
    }
  fi
  FM_VALIDATED_STATE_PATH=$path
}

# shellcheck disable=SC2034 # Result is read by sourcing callers.
FM_VALIDATED_HOME_FILE_PATH=
fm_validate_home_file_path() {
  local home=$1 path=$2 mode=${3:-allow-missing} saved_state home_path parent_path base
  FM_VALIDATED_HOME_FILE_PATH=
  saved_state=$FM_VALIDATED_STATE_PATH
  if ! fm_validate_effective_state_path "$home" require-existing; then
    FM_VALIDATED_STATE_PATH=$saved_state
    return 1
  fi
  home_path=$FM_VALIDATED_STATE_PATH
  parent_path=${path%/*}
  base=${path##*/}
  [ -n "$base" ] && [ "$base" != . ] && [ "$base" != .. ] || {
    FM_VALIDATED_STATE_PATH=$saved_state
    return 1
  }
  if ! fm_validate_effective_state_path "$parent_path" allow-missing-final; then
    FM_VALIDATED_STATE_PATH=$saved_state
    return 1
  fi
  parent_path=$FM_VALIDATED_STATE_PATH
  case "$parent_path" in
    "$home_path"|"$home_path"/*) ;;
    *)
      echo "error: home-scoped file parent escapes FM_HOME: $parent_path" >&2
      FM_VALIDATED_STATE_PATH=$saved_state
      return 1
      ;;
  esac
  path="$parent_path/$base"
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || {
      echo "error: home-scoped file is symlinked or non-regular: $path" >&2
      FM_VALIDATED_STATE_PATH=$saved_state
      return 1
    }
  elif [ "$mode" != allow-missing ]; then
    echo "error: home-scoped file does not exist: $path" >&2
    FM_VALIDATED_STATE_PATH=$saved_state
    return 1
  fi
  FM_VALIDATED_HOME_FILE_PATH=$path
  FM_VALIDATED_STATE_PATH=$saved_state
}

fm_publish_file_no_follow() {
  local source=$1 destination=$2 mode=${3:-replace} parent source_parent platform
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  parent=${destination%/*}
  source_parent=${source%/*}
  [ -n "$parent" ] || parent=.
  [ -n "$source_parent" ] || source_parent=.
  [ "$source_parent" = "$parent" ] || return 1
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
    echo "error: unsafe publication target refused: $destination" >&2
    return 1
  fi
  platform=$(uname)
  case "$mode:$platform" in
    exclusive:Linux)
      [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 1
      ln -T "$source" "$destination" || return 1
      ;;
    replace:Linux)
      mv -fT "$source" "$destination" || return 1
      ;;
    exclusive:Darwin)
      [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 1
      perl -e 'link($ARGV[0], $ARGV[1]) or exit 1' "$source" "$destination" || return 1
      ;;
    replace:Darwin)
      perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$source" "$destination" || return 1
      ;;
    *)
      echo "error: unsupported no-follow publication platform: $platform" >&2
      return 1
      ;;
  esac
  [ -f "$destination" ] && [ ! -L "$destination" ] || return 1
  [ ! -e "$source" ] || rm -f "$source" || return 1
}

fm_write_file_no_follow() {
  local destination=$1 parent tmp
  parent=${destination%/*}
  [ -n "$parent" ] || parent=.
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  tmp=$(mktemp "$parent/.fm-write.XXXXXX") || return 1
  if ! cat > "$tmp" || ! fm_publish_file_no_follow "$tmp" "$destination" replace; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

fm_touch_file_no_follow() {
  fm_write_file_no_follow "$1" </dev/null
}

fm_ensure_dir_no_follow() {
  local directory=$1 parent
  parent=${directory%/*}
  [ -n "$parent" ] || parent=.
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  if [ -e "$directory" ] || [ -L "$directory" ]; then
    [ -d "$directory" ] && [ ! -L "$directory" ]
    return
  fi
  mkdir "$directory" 2>/dev/null || return 1
  [ -d "$directory" ] && [ ! -L "$directory" ]
}

fm_validate_task_meta_file() {
  local meta=$1
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    echo "error: task metadata is symlinked or non-regular: $meta" >&2
    return 1
  }
}

fm_validate_task_meta_files() {
  local state=$1 meta
  [ -d "$state" ] || return 0
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    fm_validate_task_meta_file "$meta" || return 1
  done
}

fm_meta_lock_path() {
  local meta=$1 parent base
  parent=${meta%/*}
  base=${meta##*/}
  [ -n "$parent" ] && [ -n "$base" ] && [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  printf '%s/.%s.update.lock\n' "$parent" "$base"
}

fm_append_file_no_follow() {
  local destination=$1 parent tmp
  parent=${destination%/*}
  [ -n "$parent" ] || parent=.
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    [ -f "$destination" ] && [ ! -L "$destination" ] || return 1
  fi
  tmp=$(mktemp "$parent/.fm-append.XXXXXX") || return 1
  if { [ ! -e "$destination" ] || cat "$destination" > "$tmp"; } \
    && cat >> "$tmp" \
    && fm_publish_file_no_follow "$tmp" "$destination" replace; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

fm_remove_file_no_follow() {
  local destination=$1 parent
  parent=${destination%/*}
  [ -n "$parent" ] || parent=.
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
    return 0
  fi
  if [ ! -L "$destination" ] && [ ! -f "$destination" ]; then
    return 1
  fi
  rm -f -- "$destination" || return 1
  [ ! -e "$destination" ] && [ ! -L "$destination" ]
}

if ! fm_validate_effective_state_path "$STATE" allow-missing-final; then
  return 1 2>/dev/null || exit 1
fi
STATE=$FM_VALIDATED_STATE_PATH
FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
FM_WAKE_QUEUE_LOCK="${FM_WAKE_QUEUE_LOCK:-$STATE/.wake-queue.lock}"

fm_prepare_effective_state_path() {
  if [ ! -e "$STATE" ] && [ ! -L "$STATE" ]; then
    fm_ensure_dir_no_follow "$STATE" || return 1
  fi
  fm_validate_effective_state_path "$STATE" require-existing || return 1
  STATE=$FM_VALIDATED_STATE_PATH
}

if [ "${FM_WAKE_STATE_INIT:-create}" != skip ]; then
  fm_prepare_effective_state_path || { return 1 2>/dev/null || exit 1; }
fi

fm_current_pid() {
  printf '%s\n' "${BASHPID:-$$}"
}

fm_pid_alive() {
  [ "$(fm_pid_state "$1")" = alive ]
}

fm_pid_state() {
  local pid=$1 stat
  case "$pid" in
    ''|*[!0-9]*) printf '%s\n' dead; return ;;
  esac
  if ! kill -0 "$pid" 2>/dev/null; then
    printf '%s\n' dead
    return
  fi
  if ! stat=$(ps -p "$pid" -o stat= 2>/dev/null); then
    printf '%s\n' unknown
    return
  fi
  read -r stat _ <<< "$stat"
  case "$stat" in
    Z*) printf '%s\n' dead ;;
    '') printf '%s\n' unknown ;;
    *) printf '%s\n' alive ;;
  esac
}

fm_session_lock_ownership() {  # <state-dir> -> owned|other|unknown
  local state=$1 lock expected pid parent attempt=0
  lock="$state/.lock"
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    printf 'other\n'
    return 0
  fi
  [ -f "$lock" ] && [ ! -L "$lock" ] || { printf 'unknown\n'; return 0; }
  expected=$(cat "$lock" 2>/dev/null || true)
  case "$expected" in ''|*[!0-9]*) printf 'unknown\n'; return 0 ;; esac
  pid=${BASHPID:-$$}
  while [ "$attempt" -lt 12 ]; do
    [ "$pid" = "$expected" ] && { printf 'owned\n'; return 0; }
    [ "$pid" != 1 ] || { printf 'other\n'; return 0; }
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || {
      printf 'unknown\n'
      return 0
    }
    case "$parent" in ''|*[!0-9]*) printf 'unknown\n'; return 0 ;; esac
    pid=$parent
    attempt=$((attempt + 1))
  done
  printf 'other\n'
}

fm_pid_birth_identity() {
  local pid=$1 out
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  out=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  out=$(printf '%s\n' "$out" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

fm_checkpoint_orphan_path() {
  printf '%s/.watch-checkpoint-orphan\n' "$1"
}

FM_CHECKPOINT_ORPHAN_RECORD=
fm_create_checkpoint_orphan_record() {
  local state=$1 record=$2 path tmp
  path=$(fm_checkpoint_orphan_path "$state")
  [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
  tmp=$(mktemp "$state/.watch-checkpoint-orphan.tmp.XXXXXX") || return 1
  if ! printf '%s\n' "$record" > "$tmp" || ! ln "$tmp" "$path"; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  rm -f "$tmp" 2>/dev/null || true
}

fm_replace_checkpoint_orphan_record() {
  local state=$1 expected=$2 replacement=$3 path tmp
  path=$(fm_checkpoint_orphan_path "$state")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(cat "$path" 2>/dev/null || true)" = "$expected" ] || return 1
  tmp=$(mktemp "$state/.watch-checkpoint-orphan.tmp.XXXXXX") || return 1
  if ! printf '%s\n' "$replacement" > "$tmp" \
    || [ "$(cat "$path" 2>/dev/null || true)" != "$expected" ] \
    || ! fm_publish_file_no_follow "$tmp" "$path" replace; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

fm_clear_checkpoint_orphan() {
  local state=$1 record=$2 path
  fm_validate_effective_state_path "$state" existing || return 1
  state=$FM_VALIDATED_STATE_PATH
  path=$(fm_checkpoint_orphan_path "$state")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(cat "$path" 2>/dev/null || true)" = "$record" ] || return 1
  rm -f "$path" || return 1
  [ ! -e "$path" ] && [ ! -L "$path" ]
}

fm_reserve_checkpoint_orphan() {
  local state=$1 pid=$2 identity=$3 record
  FM_CHECKPOINT_ORPHAN_RECORD=
  [ -n "$identity" ] || return 1
  fm_validate_effective_state_path "$state" existing || return 1
  state=$FM_VALIDATED_STATE_PATH
  fm_reconcile_checkpoint_orphan "$state" || return 1
  record=$(printf 'reservation\n%s\n%s' "$pid" "$identity")
  fm_create_checkpoint_orphan_record "$state" "$record" || {
    echo "watcher: FAILED - checkpoint orphan authority could not be reserved at $(fm_checkpoint_orphan_path "$state")" >&2
    return 1
  }
  FM_CHECKPOINT_ORPHAN_RECORD=$record
}

fm_activate_checkpoint_orphan_reservation() {
  local state=$1 expected=$2 checkpoint_pid=$3 checkpoint_identity=$4 watch_pid=$5 watch_identity=$6 record
  [ -n "$checkpoint_identity" ] && [ -n "$watch_identity" ] || return 1
  fm_validate_effective_state_path "$state" existing || return 1
  state=$FM_VALIDATED_STATE_PATH
  record=$(printf 'active\n%s\n%s\n%s\n%s' \
    "$checkpoint_pid" "$checkpoint_identity" "$watch_pid" "$watch_identity")
  fm_replace_checkpoint_orphan_record "$state" "$expected" "$record" || return 1
  FM_CHECKPOINT_ORPHAN_RECORD=$record
}

fm_record_checkpoint_orphan() {
  local state=$1 expected=$2 pid=$3 identity=$4 record
  [ -n "$identity" ] || return 1
  fm_validate_effective_state_path "$state" existing || return 1
  state=$FM_VALIDATED_STATE_PATH
  record=$(printf 'orphan\n%s\n%s' "$pid" "$identity")
  fm_replace_checkpoint_orphan_record "$state" "$expected" "$record" || return 1
  FM_CHECKPOINT_ORPHAN_RECORD=$record
}

fm_reconcile_checkpoint_orphan() {
  local state=$1 path record kind owner_pid owner_identity pid identity pid_state current_identity i signal_sent=0
  fm_validate_effective_state_path "$state" existing || return 1
  state=$FM_VALIDATED_STATE_PATH
  path=$(fm_checkpoint_orphan_path "$state")
  [ -e "$path" ] || [ -L "$path" ] || return 0
  if [ ! -f "$path" ] || [ -L "$path" ]; then
    echo "watcher: FAILED - unsafe checkpoint orphan ownership record at $path" >&2
    return 1
  fi
  record=$(cat "$path" 2>/dev/null) || {
    echo "watcher: FAILED - unreadable checkpoint orphan ownership record at $path" >&2
    return 1
  }
  kind=$(printf '%s\n' "$record" | sed -n '1p')
  case "$kind" in
    reservation)
      owner_pid=$(printf '%s\n' "$record" | sed -n '2p')
      owner_identity=$(printf '%s\n' "$record" | sed '1,2d')
      pid=
      identity=
      ;;
    active)
      owner_pid=$(printf '%s\n' "$record" | sed -n '2p')
      owner_identity=$(printf '%s\n' "$record" | sed -n '3p')
      pid=$(printf '%s\n' "$record" | sed -n '4p')
      identity=$(printf '%s\n' "$record" | sed '1,4d')
      ;;
    orphan)
      owner_pid=
      owner_identity=
      pid=$(printf '%s\n' "$record" | sed -n '2p')
      identity=$(printf '%s\n' "$record" | sed '1,2d')
      ;;
    *)
      owner_pid=
      owner_identity=
      pid=$kind
      identity=$(printf '%s\n' "$record" | sed '1d')
      kind=orphan
      ;;
  esac
  if [ -n "$owner_pid" ]; then
    case "$owner_pid" in
      ''|*[!0-9]*)
        echo "watcher: FAILED - invalid checkpoint orphan ownership record at $path" >&2
        return 1
        ;;
    esac
    [ -n "$owner_identity" ] || {
      echo "watcher: FAILED - invalid checkpoint orphan ownership record at $path" >&2
      return 1
    }
    pid_state=$(fm_pid_state "$owner_pid")
    if [ "$pid_state" = unknown ]; then
      echo "watcher: FAILED - checkpoint reservation owner could not be verified at $path" >&2
      return 1
    fi
    if [ "$pid_state" = alive ]; then
      current_identity=$(fm_pid_birth_identity "$owner_pid" 2>/dev/null || true)
      if [ -z "$current_identity" ]; then
        echo "watcher: FAILED - checkpoint reservation owner identity could not be verified at $path" >&2
        return 1
      fi
      if [ "$current_identity" = "$owner_identity" ]; then
        echo "watcher: FAILED - another foreground checkpoint owns orphan authority at $path" >&2
        return 1
      fi
    fi
    if [ "$kind" = reservation ]; then
      fm_clear_checkpoint_orphan "$state" "$record" || {
        echo "watcher: FAILED - checkpoint reservation changed during cleanup at $path" >&2
        return 1
      }
      return 0
    fi
  fi
  case "$pid" in
    ''|*[!0-9]*)
      echo "watcher: FAILED - invalid checkpoint orphan ownership record at $path" >&2
      return 1
      ;;
  esac
  [ -n "$identity" ] || {
    echo "watcher: FAILED - invalid checkpoint orphan ownership record at $path" >&2
    return 1
  }
  i=0
  while [ "$i" -lt 40 ]; do
    pid_state=$(fm_pid_state "$pid")
    case "$pid_state" in
      dead)
        fm_clear_checkpoint_orphan "$state" "$record" || {
          echo "watcher: FAILED - checkpoint orphan ownership changed during cleanup at $path" >&2
          return 1
        }
        return 0
        ;;
      unknown)
        sleep 0.05
        i=$((i + 1))
        continue
        ;;
    esac
    current_identity=$(fm_pid_birth_identity "$pid" 2>/dev/null || true)
    if [ -z "$current_identity" ]; then
      sleep 0.05
      i=$((i + 1))
      continue
    fi
    if [ "$current_identity" != "$identity" ]; then
      fm_clear_checkpoint_orphan "$state" "$record" || {
        echo "watcher: FAILED - checkpoint orphan ownership changed during cleanup at $path" >&2
        return 1
      }
      return 0
    fi
    if [ "$signal_sent" -eq 0 ]; then
      current_identity=$(fm_pid_birth_identity "$pid" 2>/dev/null || true)
      [ "$current_identity" = "$identity" ] || continue
      if kill -TERM "$pid" 2>/dev/null; then
        signal_sent=1
      fi
    elif [ "$i" -ge 20 ]; then
      current_identity=$(fm_pid_birth_identity "$pid" 2>/dev/null || true)
      [ "$current_identity" = "$identity" ] || continue
      kill -KILL "$pid" 2>/dev/null || true
    fi
    sleep 0.05
    i=$((i + 1))
  done
  echo "watcher: FAILED - checkpoint orphan pid=$pid could not be reconciled by exact birth identity; ownership retained at $path" >&2
  return 1
}

fm_pid_identity() {
  local pid=$1 out
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  # Pin LC_ALL=C so lstart's date format is locale-invariant: the identity is
  # written under one locale but re-read under the machine's ambient locale, which
  # would otherwise mismatch on a non-C locale (e.g. ko_KR) and reject a live watcher.
  out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}

fm_path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_path_age() {
  local path=$1 m
  m=$(fm_path_mtime "$path") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

fm_watcher_lock_matches_pid() {
  local state=$1 watch_path=$2 pid=$3 home=${4:-$FM_HOME} lockdir lock_home lock_path lock_identity current_identity
  lockdir="$state/.watch.lock"
  lock_home=$(cat "$lockdir/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$lockdir/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$home" ] || return 1
  [ "$lock_path" = "$watch_path" ] || return 1
  [ -n "$lock_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid") || return 1
  [ "$current_identity" = "$lock_identity" ]
}

FM_WATCHER_HEALTHY_PID=
fm_watcher_healthy() {
  local state=$1 watch_path=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-$FM_HOME} lockdir beat pid age
  FM_WATCHER_HEALTHY_PID=
  lockdir="$state/.watch.lock"
  beat="$state/.last-watcher-beat"
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  fm_watcher_lock_matches_pid "$state" "$watch_path" "$pid" "$home" || return 1
  age=$(fm_path_age "$beat")
  [ "$age" -lt "$grace" ] || return 1
  # shellcheck disable=SC2034 # Read by callers after fm_watcher_healthy returns.
  FM_WATCHER_HEALTHY_PID=$pid
  return 0
}

FM_WATCHER_OWNER_KIND=
FM_WATCHER_OWNER_PID=
FM_WATCHER_OWNER_MODE=
fm_watcher_live_owner() {
  local state=$1 lockdir kind mode pid recorded_identity current_identity
  FM_WATCHER_OWNER_KIND=
  FM_WATCHER_OWNER_PID=
  FM_WATCHER_OWNER_MODE=
  lockdir="$state/.watch.lock"
  kind=$(cat "$lockdir/owner-kind" 2>/dev/null || true)
  mode=$(cat "$lockdir/owner-mode" 2>/dev/null || true)
  pid=$(cat "$lockdir/owner-pid" 2>/dev/null || true)
  recorded_identity=$(cat "$lockdir/owner-identity" 2>/dev/null || true)
  case "$kind" in
    arm|checkpoint|daemon) ;;
    *) return 1 ;;
  esac
  fm_pid_alive "$pid" || return 1
  [ -n "$recorded_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid") || return 1
  [ "$current_identity" = "$recorded_identity" ] || return 1
  FM_WATCHER_OWNER_KIND=$kind
  FM_WATCHER_OWNER_PID=$pid
  FM_WATCHER_OWNER_MODE=$mode
  return 0
}

fm_lock_clean_known_files() {
  local lockdir=$1
  rm -f \
    "$lockdir/pid" \
    "$lockdir/fm-home" \
    "$lockdir/owner-identity" \
    "$lockdir/owner-kind" \
    "$lockdir/owner-mode" \
    "$lockdir/owner-pid" \
    "$lockdir/pid-identity" \
    "$lockdir/supervisor-backend" \
    "$lockdir/supervisor-target" \
    "$lockdir/watcher-path" \
    2>/dev/null || true
}

fm_lock_abs_path() {
  local path=$1 dir base
  dir=$(dirname "$path")
  base=$(basename "$path")
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$base"
}

fm_lock_owner_dir() {
  local lockdir=$1 lock_abs
  lock_abs=$(fm_lock_abs_path "$lockdir") || return 1
  mktemp -d "${lock_abs}.owner.XXXXXX" 2>/dev/null
}

fm_lock_prepare_owner() {
  local ownerdir=$1 mypid back
  mypid=${BASHPID:-$$}
  printf '%s\n' "$mypid" > "$ownerdir/pid" 2>/dev/null || return 1
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  [ "$back" = "$mypid" ]
}

fm_lock_link_owner() {
  local lockdir=$1 owner lock_abs lock_parent lock_base owner_parent owner_base
  lock_abs=$(fm_lock_abs_path "$lockdir") || return 1
  owner=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ -n "$owner" ] || return 1
  case "$owner" in
    /*) ;;
    */*) return 1 ;;
    *) owner="$(dirname "$lock_abs")/$owner" ;;
  esac
  [ -d "$owner" ] && [ ! -L "$owner" ] || return 1
  owner=$(cd "$owner" 2>/dev/null && pwd -P) || return 1
  lock_parent=$(dirname "$lock_abs")
  lock_base=$(basename "$lock_abs")
  owner_parent=$(dirname "$owner")
  owner_base=$(basename "$owner")
  [ "$owner_parent" = "$lock_parent" ] || return 1
  case "$owner_base" in "$lock_base".owner.?*) ;; *) return 1 ;; esac
  printf '%s\n' "$owner"
}

fm_lock_points_to_owner() {
  local lockdir=$1 ownerdir=$2 actual
  actual=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ "$actual" = "$ownerdir" ]
}

fm_lock_discard_owner() {
  local ownerdir=$1
  [ -n "$ownerdir" ] || return 0
  fm_lock_clean_known_files "$ownerdir"
  rmdir "$ownerdir" 2>/dev/null || true
}

fm_lock_remove_stray_owner_link() {
  local lockdir=$1 ownerdir=$2 stray
  stray="$lockdir/$(basename "$ownerdir")"
  if [ -L "$stray" ] && [ "$(readlink "$stray" 2>/dev/null || true)" = "$ownerdir" ]; then
    rm -f "$stray" 2>/dev/null || true
  fi
}

fm_lock_claim_blocked_by_steal() {
  local lockdir=$1 allowed_steal_owner=${2:-} steal
  steal="$lockdir.steal"
  [ -e "$steal" ] || [ -L "$steal" ] || return 1
  if [ -n "$allowed_steal_owner" ] && fm_lock_points_to_owner "$steal" "$allowed_steal_owner"; then
    return 1
  fi
  return 0
}

fm_lock_claim() {
  local lockdir=$1 ownerdir=$2 allowed_steal_owner=${3:-} mypid back
  mypid=${BASHPID:-$$}
  if ! { printf '%s\n' "$mypid" > "$ownerdir/pid"; } 2>/dev/null; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  if [ "$back" != "$mypid" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if fm_lock_claim_blocked_by_steal "$lockdir" "$allowed_steal_owner"; then
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  return 0
}

fm_lock_try_create() {
  local lockdir=$1 allowed_steal_owner=${2:-} ownerdir
  FM_LOCK_OWNER_DIR=
  ownerdir=$(fm_lock_owner_dir "$lockdir") || return 1
  if [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_prepare_owner "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ln -s "$ownerdir" "$lockdir" 2>/dev/null && fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    if fm_lock_claim "$lockdir" "$ownerdir" "$allowed_steal_owner"; then
      FM_LOCK_OWNER_DIR=$ownerdir
      return 0
    fi
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
  else
    fm_lock_remove_stray_owner_link "$lockdir" "$ownerdir"
  fi
  fm_lock_discard_owner "$ownerdir"
  return 1
}

fm_lock_remove_path() {
  local lockdir=$1 ownerdir
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    rm -f "$lockdir" 2>/dev/null || return 1
    [ -n "$ownerdir" ] && fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null
}

fm_lock_mid_acquire_is_fresh() {
  local lockdir=$1 pid=$2 mid_acquire_stale
  case "$pid" in
    ''|*[!0-9]*)
      mid_acquire_stale=$FM_LOCK_STALE_AFTER
      [ "$mid_acquire_stale" -lt 2 ] && mid_acquire_stale=2
      [ "$(fm_path_age "$lockdir")" -lt "$mid_acquire_stale" ]
      return
      ;;
  esac
  return 1
}

fm_lock_recheck_stale_owner() {
  local lockdir=$1 expected_owner=$2 expected_pid=$3 actual_pid pid_state
  if [ -n "$expected_owner" ]; then
    fm_lock_points_to_owner "$lockdir" "$expected_owner" || return 1
  elif [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    [ -d "$lockdir" ] && [ ! -L "$lockdir" ] || return 1
  fi
  actual_pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$actual_pid" = "$expected_pid" ] || return 1
  pid_state=$(fm_pid_state "$actual_pid")
  [ "$pid_state" = dead ] || return 1
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$actual_pid"; then
    return 1
  fi
  return 0
}

fm_lock_try_acquire() {
  local lockdir=$1 pid steal cur rc steal_owner primary_owner pid_state
  FM_LOCK_HELD_PID=
  FM_LOCK_OWNER_DIR=

  if fm_lock_try_create "$lockdir"; then
    return 0
  fi

  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  pid_state=$(fm_pid_state "$pid")
  if [ "$pid_state" != dead ]; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi

  steal="$lockdir.steal"
  if ! fm_lock_try_acquire "$steal"; then
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  steal_owner=${FM_LOCK_OWNER_DIR:-}

  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  pid_state=$(fm_pid_state "$cur")
  if [ "$pid_state" != dead ]; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if ! fm_lock_points_to_owner "$steal" "$steal_owner"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  primary_owner=
  if [ -L "$lockdir" ]; then
    primary_owner=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
  fi
  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if ! fm_lock_recheck_stale_owner "$lockdir" "$primary_owner" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  fm_lock_remove_path "$lockdir" || true
  rc=1
  if fm_lock_try_create "$lockdir" "$steal_owner"; then
    rc=0
  fi
  if [ "$rc" -ne 0 ]; then
    # shellcheck disable=SC2034 # Read by callers after fm_lock_try_acquire returns.
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
  fi
  fm_lock_release "$steal"
  return "$rc"
}

fm_lock_acquire_wait() {
  local lockdir=$1
  while ! fm_lock_try_acquire "$lockdir"; do
    sleep 0.1
  done
}

fm_lock_release() {
  local lockdir=$1 pid current ownerdir
  current=${BASHPID:-$$}
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    [ -n "$ownerdir" ] || return 0
    pid=$(cat "$ownerdir/pid" 2>/dev/null || true)
    [ "$pid" = "$current" ] || return 0
    fm_lock_points_to_owner "$lockdir" "$ownerdir" || return 0
    rm -f "$lockdir" 2>/dev/null || return 0
    fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 0
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null || true
}

fm_wake_clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

fm_wake_append() {
  local kind=$1 key=$2 payload=$3 clean_key clean_payload epoch seq seq_file status
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_append: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac

  clean_key=$(printf '%s' "$key" | fm_wake_clean_field)
  clean_payload=$(printf '%s' "$payload" | fm_wake_clean_field)
  epoch=$(date +%s)
  seq_file="$STATE/.wake-queue.seq"
  status=0

  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  seq=$(cat "$seq_file" 2>/dev/null || echo 0)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  printf '%s\n' "$seq" | fm_write_file_no_follow "$seq_file" || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$clean_key" "$clean_payload" \
      | fm_append_file_no_follow "$FM_WAKE_QUEUE" || status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

fm_wake_restore_queue() {
  local drained=$1 restore
  restore="$STATE/.wake-queue.restore.$(fm_current_pid)"
  [ -f "$drained" ] && [ ! -L "$drained" ] || return 1
  if [ -e "$FM_WAKE_QUEUE" ]; then
    [ -f "$FM_WAKE_QUEUE" ] && [ ! -L "$FM_WAKE_QUEUE" ] || return 1
    cat "$drained" "$FM_WAKE_QUEUE" | fm_write_file_no_follow "$restore" \
      && fm_publish_file_no_follow "$restore" "$FM_WAKE_QUEUE" replace
  else
    fm_publish_file_no_follow "$drained" "$FM_WAKE_QUEUE" exclusive
  fi
}

fm_wake_print_deduped() {
  local file=$1
  awk -F '\t' '
    NF >= 5 {
      dedupe = $3 SUBSEP $4
      if ($3 == "heartbeat") {
        dedupe = "heartbeat"
      }
      if (!(dedupe in seen)) {
        order[++count] = dedupe
        seen[dedupe] = 1
      }
      line[dedupe] = $0
    }
    END {
      for (i = 1; i <= count; i++) {
        print line[order[i]]
      }
    }
  ' "$file"
}
