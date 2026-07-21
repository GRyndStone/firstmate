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
# OpenCode, pi, and grok adapters use the same predicate and keep forcing
# bounded follow-ups because their turn-end events are passive.
# See docs/turnend-guard.md for the per-harness mechanics, validation evidence,
# and fail-open tradeoffs.
#
# Ships with TRACKED harness hook files at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, any
# crewmate/scout task worktree spawned to work on firstmate itself (the
# recursive "firstmate improving itself" case), and every secondmate home
# (treehouse-leased or git-cloned). It must therefore scope itself to the
# PRIMARY at runtime and stay a silent, fast no-op everywhere else.
#
# A blocked stop guarantees another continuation, but it is not permission for
# the retry to end blind. The retry stays blocked until queued wakes are drained
# and a turn-surviving owner holds the live watcher cycle.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

# Read the whole turn-end hook payload once. The payload is diagnostic only;
# malformed or missing input cannot bypass the primary-scoped predicate.
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
[ -d "$STATE" ] || exit 0

# --- the actual predicate ----------------------------------------------------
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_supervision_status "$STATE" "$GRACE"
[ "$FM_SUP_IN_FLIGHT" -gt 0 ] || exit 0

daemon_owner_is_active() {
  local owner_pid=$1 daemon_pid daemon_lock_pid
  case "$FM_WATCHER_OWNER_MODE" in
    away-inject) [ -e "$STATE/.afk" ] || return 1 ;;
    normal-inject) ;;
    *) return 1 ;;
  esac
  daemon_pid=$(cat "$STATE/.supervise-daemon.pid" 2>/dev/null || true)
  daemon_lock_pid=$(fm_identity_lock_live_pid "$STATE/.supervise-daemon.lock" 2>/dev/null) || return 1
  [ "$daemon_pid" = "$owner_pid" ] || return 1
  [ "$daemon_lock_pid" = "$owner_pid" ] || return 1
  return 0
}

WATCH_OWNER_DESC="no healthy watcher"
if [ "$FM_SUP_QUEUE_PENDING" = true ]; then
  WATCH_OWNER_DESC="queued wakes are not drained"
elif fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
  WATCH_OWNER_DESC="healthy watcher has no live owner provenance"
  if fm_watcher_live_owner "$STATE"; then
    case "$FM_WATCHER_OWNER_KIND" in
      arm) exit 0 ;;
      daemon)
        if daemon_owner_is_active "$FM_WATCHER_OWNER_PID"; then
          exit 0
        fi
        WATCH_OWNER_DESC="daemon owner is dead, identity-mismatched, or not active for its declared mode"
        ;;
      checkpoint) WATCH_OWNER_DESC="foreground checkpoint owner cannot survive turn yield" ;;
    esac
  fi
fi

afk=0
[ -e "$STATE/.afk" ] && afk=1
x_mode=0
[ -f "$CONFIG/x-mode.env" ] && x_mode=1
# Count a completed forced continuation for session-lifecycle rotate thresholds.
# Best-effort and model-free; never changes the guard's block/exit contract.
if [ "$STOP_HOOK_ACTIVE" = true ] && [ -x "$SCRIPT_DIR/fm-session-lifecycle.sh" ]; then
  FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-session-lifecycle.sh" \
    record-forced-continuation 1 >/dev/null 2>&1 || true
fi
REASON=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --afk "$afk" --x-mode "$x_mode" --repair-line 2>/dev/null \
  || printf '%s\n' 'tasks in flight, no live watcher - resume supervision according to the session-start operating block before ending the turn')
rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
{
  printf '●%s\n' "$rule"
  printf '●  TURN WOULD END BLIND - DURABLE SUPERVISION IS OFF\n'
  printf '●  %s task(s) in flight; %s (last beat: %s).\n' "$FM_SUP_IN_FLIGHT" "$WATCH_OWNER_DESC" "$FM_SUP_BEACON_DESC"
  if [ "$STOP_HOOK_ACTIVE" = true ]; then
    printf '●  The prior forced continuation did not drain wakes and establish durable ownership.\n'
  fi
  printf '●  %s\n' "$REASON"
  printf '●%s\n' "$rule"
} >&2
exit 2
