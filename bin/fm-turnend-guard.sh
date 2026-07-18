#!/usr/bin/env bash
# Primary turn-end guard for the firstmate PRIMARY session only.
#
# fm-guard.sh (bin/fm-guard.sh) is pull-based: it only warns when some other
# supervision script happens to run. A primary session that ends a turn without
# resuming its harness supervision protocol, and then never runs another
# fleet-touching command itself, can sit blind for hours.
# This script is push-based: verified harness turn-end hooks invoke it every time
# the primary is about to end a turn.
# Claude and codex can block directly by preserving exit status 2 and stderr.
# OpenCode, pi, and grok adapters use the same predicate and force one bounded
# follow-up because their turn-end events are passive.
# See docs/turnend-guard.md for the per-harness mechanics, validation evidence,
# and passive-adapter delivery boundaries.
#
# Ships with TRACKED harness hook files at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, any
# crewmate/scout task worktree spawned to work on firstmate itself (the
# recursive "firstmate improving itself" case), and every secondmate home
# (treehouse-leased or git-cloned). It must therefore scope itself to the
# PRIMARY at runtime and stay a silent, fast no-op everywhere else.
#
# A blocked stop is the state transition that guarantees another assistant
# continuation. A retry may end only after a turn-surviving watcher owner is
# confirmed; stop_hook_active is evidence of the earlier transition, not
# permission to end blind.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
TARGET_PROBE_TIMEOUT=${FM_TURNEND_TARGET_PROBE_TIMEOUT:-2}
case "$TARGET_PROBE_TIMEOUT" in ''|*[!0-9]*|0) TARGET_PROBE_TIMEOUT=2 ;; esac

# shellcheck source=bin/fm-wake-lib.sh
FM_WAKE_STATE_INIT=skip
. "$SCRIPT_DIR/fm-wake-lib.sh" || exit 1
unset FM_WAKE_STATE_INIT
STATE=$FM_VALIDATED_STATE_PATH

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

# Read and drain the whole turn-end hook payload once.
# The payload is diagnostic only: malformed or missing input can never bypass
# the primary-scoped ownership predicate.
PAYLOAD=$(cat 2>/dev/null || true)
PAYLOAD_COMPACT=$(printf '%s' "$PAYLOAD" | tr -d '[:space:]')
STOP_HOOK_ACTIVE=false
case "$PAYLOAD_COMPACT" in
  *'"stop_hook_active":true'*) STOP_HOOK_ACTIVE=true ;;
esac

# --- scope precisely to the PRIMARY checkout --------------------------------
# Excludes secondmate homes (the .fm-secondmate-home marker is written at seed
# time regardless of whether the home was treehouse-leased or git-cloned; see
# bin/fm-home-seed.sh) and ordinary crewmate/scout task worktrees of
# firstmate-on-itself (bin/fm-spawn.sh only ever hands those out as genuine
# linked `git worktree`s - it aborts the spawn otherwise - so a plain,
# non-worktree checkout is never one of those). A linked worktree's git-dir
# lives under the main repo's .git/worktrees/<name> and differs from the common
# (shared) git-dir; only the main, non-worktree checkout has the two equal.
[ -f "$FM_ROOT/.fm-secondmate-home" ] && exit 0
GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
[ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || exit 0
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$FM_ROOT/bin" ] || exit 0

# --- the actual predicate ----------------------------------------------------
[ -d "$STATE" ] || exit 0
[ "$(fm_session_lock_ownership "$STATE")" = owned ] || exit 0

CHECKPOINT_ORPHAN_UNRESOLVED=0
fm_reconcile_checkpoint_orphan "$STATE" || CHECKPOINT_ORPHAN_UNRESOLVED=1

fm_supervision_status "$STATE" "$GRACE"
[ "$FM_SUP_IN_FLIGHT" -gt 0 ] || exit 0

HARNESS=${FM_TURNEND_HARNESS:-}
[ -n "$HARNESS" ] || HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)

supervisor_target_injectable() {
  local backend=$1 target=$2 probe="$SCRIPT_DIR/fm-backend.sh"
  [ -r "$probe" ] || return 1
  case "$backend" in tmux|herdr|zellij|orca|cmux) ;; *) return 1 ;; esac
  if [ "$backend" = tmux ]; then
    case "$target" in
      %*[!0-9]*|%|'') return 1 ;;
      %*) ;;
      *) return 1 ;;
    esac
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TARGET_PROBE_TIMEOUT" bash -c '. "$1"; fm_backend_target_exists "$2" "$3" || exit 1; [ "$(fm_backend_agent_alive "$2" "$3")" = alive ] || case "$(fm_backend_composer_state "$2" "$3")" in empty|pending) exit 0 ;; *) exit 1 ;; esac' _ "$probe" "$backend" "$target"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$TARGET_PROBE_TIMEOUT" bash -c '. "$1"; fm_backend_target_exists "$2" "$3" || exit 1; [ "$(fm_backend_agent_alive "$2" "$3")" = alive ] || case "$(fm_backend_composer_state "$2" "$3")" in empty|pending) exit 0 ;; *) exit 1 ;; esac' _ "$probe" "$backend" "$target"
  elif command -v perl >/dev/null 2>&1; then
    perl -e '$seconds=shift; alarm $seconds; exec @ARGV' "$TARGET_PROBE_TIMEOUT" \
      bash -c '. "$1"; fm_backend_target_exists "$2" "$3" || exit 1; [ "$(fm_backend_agent_alive "$2" "$3")" = alive ] || case "$(fm_backend_composer_state "$2" "$3")" in empty|pending) exit 0 ;; *) exit 1 ;; esac' _ "$probe" "$backend" "$target"
  else
    return 1
  fi
}

daemon_owner_active() {
  local pid=$1 identity=$2 daemon_pid daemon_lock daemon_lock_owner lock_pid lock_identity backend target
  [ "$FM_WATCHER_OWNER_MODE" = away-inject ] || return 1
  [ -f "$STATE/.afk" ] || return 1
  [ ! -L "$STATE/.afk" ] || return 1
  [ -f "$STATE/.supervise-daemon.pid" ] || return 1
  [ ! -L "$STATE/.supervise-daemon.pid" ] || return 1
  daemon_pid=$(cat "$STATE/.supervise-daemon.pid" 2>/dev/null || true)
  daemon_lock=$(fm_lock_abs_path "$STATE/.supervise-daemon.lock" 2>/dev/null || true)
  [ -n "$daemon_lock" ] || return 1
  daemon_lock_owner=$(fm_lock_link_owner "$STATE/.supervise-daemon.lock" 2>/dev/null || true)
  daemon_lock_owner=$(cd "$daemon_lock_owner" 2>/dev/null && pwd -P) || return 1
  case "$daemon_lock_owner" in
    "$daemon_lock".owner.*) ;;
    *) return 1 ;;
  esac
  [ -d "$daemon_lock_owner" ] || return 1
  [ ! -L "$daemon_lock_owner" ] || return 1
  lock_pid=$(cat "$daemon_lock_owner/pid" 2>/dev/null || true)
  lock_identity=$(cat "$daemon_lock_owner/pid-identity" 2>/dev/null || true)
  [ -f "$daemon_lock_owner/supervisor-backend" ] || return 1
  [ ! -L "$daemon_lock_owner/supervisor-backend" ] || return 1
  [ -f "$daemon_lock_owner/supervisor-target" ] || return 1
  [ ! -L "$daemon_lock_owner/supervisor-target" ] || return 1
  backend=$(cat "$daemon_lock_owner/supervisor-backend" 2>/dev/null || true)
  target=$(cat "$daemon_lock_owner/supervisor-target" 2>/dev/null || true)
  [ -n "$target" ] || return 1
  [ "$daemon_pid" = "$pid" ] || return 1
  [ "$lock_pid" = "$pid" ] || return 1
  [ "$lock_identity" = "$identity" ] || return 1
  fm_pid_alive "$pid" || return 1
  supervisor_target_injectable "$backend" "$target"
}

WATCH_OWNER_DESC="no healthy watcher"
if [ "$CHECKPOINT_ORPHAN_UNRESOLVED" -eq 1 ]; then
  WATCH_OWNER_DESC="unresolved foreground checkpoint ownership"
elif fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
  WATCH_OWNER_DESC="healthy watcher has no live owner provenance"
  if fm_watcher_live_owner "$STATE"; then
    WATCH_OWNER_DESC="$FM_WATCHER_OWNER_KIND owner pid=$FM_WATCHER_OWNER_PID"
    case "$FM_WATCHER_OWNER_KIND:$HARNESS" in
      daemon:*)
        if daemon_owner_active "$FM_WATCHER_OWNER_PID" "$(cat "$STATE/.watch.lock/owner-identity" 2>/dev/null || true)"; then
          exit 0
        fi
        WATCH_OWNER_DESC="daemon owner or its injection target is not active in declared away-inject mode"
        ;;
      arm:claude|arm:grok|arm:pi|arm:opencode) exit 0 ;;
      arm:codex) WATCH_OWNER_DESC="arm owner is not durable in Codex" ;;
      checkpoint:*) WATCH_OWNER_DESC="foreground checkpoint owner cannot survive turn yield" ;;
      *) WATCH_OWNER_DESC="$FM_WATCHER_OWNER_KIND owner is not verified for $HARNESS" ;;
    esac
  fi
fi

DETAIL_LIMIT=${FM_TURNEND_DETAIL_LIMIT:-5}
DETAIL_TIMEOUT=${FM_TURNEND_DETAIL_TIMEOUT:-1}
case "$DETAIL_LIMIT" in ''|*[!0-9]*|0) DETAIL_LIMIT=5 ;; esac
case "$DETAIL_TIMEOUT" in ''|*[!0-9]*|0) DETAIL_TIMEOUT=1 ;; esac
[ "$DETAIL_LIMIT" -le 10 ] || DETAIL_LIMIT=10

crew_state_bounded() {
  local id=$1 state_bin="$SCRIPT_DIR/fm-crew-state.sh"
  [ -x "$state_bin" ] || return 1
  if command -v timeout >/dev/null 2>&1; then
    timeout "$DETAIL_TIMEOUT" env FM_CREW_STATE_NM_TIMEOUT=1 "$state_bin" "$id" 2>/dev/null
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$DETAIL_TIMEOUT" env FM_CREW_STATE_NM_TIMEOUT=1 "$state_bin" "$id" 2>/dev/null
  elif command -v perl >/dev/null 2>&1; then
    perl -e '$seconds=shift; alarm $seconds; exec @ARGV' "$DETAIL_TIMEOUT" \
      env FM_CREW_STATE_NM_TIMEOUT=1 "$state_bin" "$id" 2>/dev/null
  else
    FM_CREW_STATE_NM_TIMEOUT=1 "$state_bin" "$id" 2>/dev/null
  fi
}

attention_detail() {
  local meta id line state scanned=0 shown=0 scan_limit detail="" total=0 unprobed omitted_nonworking=0
  scan_limit=$((DETAIL_LIMIT * 2))
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    total=$((total + 1))
  done
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    [ "$scanned" -lt "$scan_limit" ] || break
    scanned=$((scanned + 1))
    id=$(basename "$meta" .meta)
    if [ ! -f "$meta" ] || [ -L "$meta" ]; then
      if [ "$shown" -lt "$DETAIL_LIMIT" ]; then
        [ -z "$detail" ] || detail="$detail, "
        detail="$detail${id:0:48}=unsafe-metadata"
        shown=$((shown + 1))
      else
        omitted_nonworking=$((omitted_nonworking + 1))
      fi
      continue
    fi
    line=$(crew_state_bounded "$id" || true)
    read -r _ state _ <<< "$line"
    [ -n "$state" ] || state=unknown
    case "$state" in
      working) continue ;;
    esac
    if [ "$shown" -ge "$DETAIL_LIMIT" ]; then
      omitted_nonworking=$((omitted_nonworking + 1))
      continue
    fi
    [ -z "$detail" ] || detail="$detail, "
    detail="$detail${id:0:48}=$state"
    shown=$((shown + 1))
  done
  unprobed=$((total - scanned))
  if [ -z "$detail" ]; then
    detail="none among $scanned bounded probe(s)"
  fi
  detail="$detail; $omitted_nonworking additional non-working task(s) omitted; $unprobed task(s) unprobed"
  printf '%s\n' "$detail"
}

afk=0
[ -e "$STATE/.afk" ] && afk=1
x_mode=0
[ -f "$CONFIG/x-mode.env" ] && x_mode=1
REASON=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --afk "$afk" --x-mode "$x_mode" --repair-line 2>/dev/null \
  || printf '%s\n' 'tasks in flight, no live watcher - resume supervision according to the session-start operating block before ending the turn')
rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
{
  printf '●%s\n' "$rule"
  printf '●  TURN WOULD END BLIND - NO DURABLE SUPERVISION OWNER\n'
  printf '●  %s task(s) in flight; %s (last beat: %s).\n' "$FM_SUP_IN_FLIGHT" "$WATCH_OWNER_DESC" "$FM_SUP_BEACON_DESC"
  printf '●  Parked/idle task detail (bounded): %s.\n' "$(attention_detail)"
  if [ "$STOP_HOOK_ACTIVE" = true ]; then
    printf '●  The prior forced continuation did not establish durable ownership; this stop is blocked again.\n'
  fi
  printf '●  %s\n' "$REASON"
  printf '●%s\n' "$rule"
} >&2
exit 2
